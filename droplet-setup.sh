#!/usr/bin/env bash
# droplet-setup.sh — provisions an Ubuntu 24.04+ droplet with
# nginx + PostgreSQL + Node.js + pnpm + pm2 + Let's Encrypt.
#
# Safe to re-run: every step checks current state before changing it.
# Run `sudo ./droplet-setup.sh --help` for usage.

set -Eeuo pipefail

readonly LOG_FILE="/var/log/droplet-setup.log"
readonly ALL_STEPS=(base hardening nginx postgres node pm2 ssl)
declare -A STEP_DESC=(
  [base]="apt upgrade, timezone, sudo user, SSH keys, SSH hardening, UFW, swap"
  [hardening]="fail2ban (sshd), unattended security upgrades, journald size cap"
  [nginx]="nginx, UFW rule, hardened defaults, default-deny vhost, reverse proxy to APP_PORT"
  [postgres]="PostgreSQL (+contrib), role + database named after NEW_USER, RAM-based tuning"
  [node]="Node.js via NodeSource, pnpm, build-essential"
  [pm2]="pm2, systemd startup unit for NEW_USER, pm2-logrotate"
  [ssl]="certbot, certificate, HTTP->HTTPS redirect, HSTS, renewal dry-run"
)
# Keys accepted by --set and the config file. Anything else is rejected.
readonly CONFIG_KEYS=(
  NEW_USER NEW_USER_PASSWORD SSH_PUBLIC_KEY TIMEZONE SWAP_SIZE
  DISABLE_ROOT_LOGIN DISABLE_PASSWORD_AUTH
  DOMAINS APP_PORT CLIENT_MAX_BODY_SIZE
  PG_VERSION PG_CREATE_DB PG_PASSWORD PG_TUNE PG_MAX_CONNECTIONS
  NODE_MAJOR
  LE_EMAIL LE_STAGING HSTS_MAX_AGE HSTS_INCLUDE_SUBDOMAINS
  STEPS ASSUME_YES
)

export DEBIAN_FRONTEND=noninteractive
# Ubuntu's needrestart otherwise opens an interactive dialog during upgrades.
export NEEDRESTART_MODE=a

# ---------------------------------------------------------------- helpers ---

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "command failed (line $LINENO): $BASH_COMMAND"' ERR

is_yes() { [[ ${1,,} =~ ^(y|yes|true|1)$ ]]; }
interactive() { [[ -t 0 ]] && ! is_yes "${ASSUME_YES:-no}"; }

# prompt_var NAME "Question" [secret]  — keeps the current value on empty input.
prompt_var() {
  local name=$1 question=$2 secret=${3:-} current=${!1:-} reply=""
  interactive || return 0
  if [[ $secret == secret ]]; then
    read -rsp "$question: " reply; echo
  else
    read -rp "$question${current:+ [$current]}: " reply
  fi
  [[ -n $reply ]] && printf -v "$name" '%s' "$reply"
  return 0
}

require_var() {
  [[ -n ${!1:-} ]] || die "$1 is required for step '$2' (config file, --set $1=..., or run interactively)"
}

confirm_or_die() {
  local reply
  interactive || die "$1 (non-interactive run, aborting)"
  read -rp "$1 Continue anyway? [y/N]: " reply
  is_yes "${reply:-n}" || die "aborted by user"
}

is_selected() { [[ -n ${SELECTED[$1]:-} ]]; }

user_home() { getent passwd "$NEW_USER" | cut -d: -f6; }

as_user() { (cd "$(user_home)" && sudo -u "$NEW_USER" -H "$@"); }

# Runs psql as the postgres superuser; SQL comes from stdin.
pg() { (cd / && sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 "$@"); }

APT_UPDATED=no
apt_update() {
  [[ $APT_UPDATED == yes && ${1:-} != force ]] && return 0
  apt-get update -q
  APT_UPDATED=yes
}
apt_install() {
  apt_update
  apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

primary_domain() { local d; read -r d _ <<<"$DOMAINS"; printf '%s' "$d"; }

public_ipv4() {
  # DigitalOcean metadata service first; public echo service as fallback.
  curl -fsS --max-time 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null \
    || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || true
}

# ------------------------------------------------------------------ usage ---

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Options:
  -c, --config FILE     Source KEY=value settings from FILE (see droplet.env.example)
  -s, --steps LIST      Comma-separated steps or 'all': ${ALL_STEPS[*]}
  -u, --user NAME       NEW_USER (Linux user, sudoer, Postgres role, pm2 owner)
  -d, --domains LIST    DOMAINS, first one is primary (e.g. "example.com,www.example.com")
  -p, --app-port PORT   APP_PORT nginx proxies to (default 3000)
  -e, --email EMAIL     LE_EMAIL for Let's Encrypt
      --set KEY=VALUE   Set any config key (repeatable)
  -y, --yes             Non-interactive: never prompt, fail on missing values
  -h, --help            Show this help

Precedence: CLI flags > config file > environment > built-in defaults.
Steps always run in this order regardless of how they are listed:
EOF
  local s
  for s in "${ALL_STEPS[@]}"; do printf '  %-10s %s\n' "$s" "${STEP_DESC[$s]}"; done
  printf '\nConfig keys: %s\n' "${CONFIG_KEYS[*]}"
}

# ----------------------------------------------------------------- config ---

CONFIG_FILE=""
CLI_OVERRIDES=()

parse_args() {
  while (($#)); do
    case $1 in
      -c|--config)   CONFIG_FILE=${2:?--config needs a file}; shift 2 ;;
      -s|--steps)    CLI_OVERRIDES+=("STEPS=${2:?}"); shift 2 ;;
      -u|--user)     CLI_OVERRIDES+=("NEW_USER=${2:?}"); shift 2 ;;
      -d|--domains)  CLI_OVERRIDES+=("DOMAINS=${2:?}"); shift 2 ;;
      -p|--app-port) CLI_OVERRIDES+=("APP_PORT=${2:?}"); shift 2 ;;
      -e|--email)    CLI_OVERRIDES+=("LE_EMAIL=${2:?}"); shift 2 ;;
      --set)         CLI_OVERRIDES+=("${2:?--set needs KEY=VALUE}"); shift 2 ;;
      -y|--yes)      CLI_OVERRIDES+=("ASSUME_YES=yes"); shift ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "unknown option: $1 (see --help)" ;;
    esac
  done
}

is_config_key() { local k; for k in "${CONFIG_KEYS[@]}"; do [[ $k == "$1" ]] && return 0; done; return 1; }

load_config() {
  if [[ -n $CONFIG_FILE ]]; then
    [[ -f $CONFIG_FILE ]] || die "config file not found: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
  local kv key
  for kv in "${CLI_OVERRIDES[@]}"; do
    key=${kv%%=*}
    is_config_key "$key" || die "unknown config key: $key"
    printf -v "$key" '%s' "${kv#*=}"
  done

  # Re-running as `sudo` from the created user defaults NEW_USER to that user.
  : "${NEW_USER:=${SUDO_USER:-}}"
  [[ $NEW_USER == root ]] && NEW_USER=""
  : "${NEW_USER_PASSWORD:=}"
  : "${SSH_PUBLIC_KEY:=}"
  : "${TIMEZONE:=UTC}"
  : "${SWAP_SIZE:=2G}"
  : "${DISABLE_ROOT_LOGIN:=yes}"
  : "${DISABLE_PASSWORD_AUTH:=yes}"
  : "${DOMAINS:=}"
  : "${APP_PORT:=3000}"
  : "${CLIENT_MAX_BODY_SIZE:=10m}"
  : "${PG_VERSION:=}"
  : "${PG_CREATE_DB:=yes}"
  : "${PG_PASSWORD:=}"
  : "${PG_TUNE:=yes}"
  : "${PG_MAX_CONNECTIONS:=50}"
  : "${NODE_MAJOR:=lts}"
  : "${LE_EMAIL:=}"
  : "${LE_STAGING:=no}"
  : "${HSTS_MAX_AGE:=31536000}"
  : "${HSTS_INCLUDE_SUBDOMAINS:=no}"
  : "${STEPS:=}"
  : "${ASSUME_YES:=no}"
}

declare -A SELECTED=()

select_steps() {
  if [[ -z $STEPS ]]; then
    interactive || die "no steps given; use --steps (e.g. --steps all)"
    echo "Available steps:"
    local i
    for i in "${!ALL_STEPS[@]}"; do
      printf '  %d) %-10s %s\n' $((i + 1)) "${ALL_STEPS[$i]}" "${STEP_DESC[${ALL_STEPS[$i]}]}"
    done
    read -rp "Steps to run (names or numbers, comma/space separated) [all]: " STEPS
    STEPS=${STEPS:-all}
  fi

  local token
  for token in ${STEPS//,/ }; do
    if [[ $token == all ]]; then
      for token in "${ALL_STEPS[@]}"; do SELECTED[$token]=1; done
      continue
    fi
    if [[ $token =~ ^[0-9]+$ ]] && ((token >= 1 && token <= ${#ALL_STEPS[@]})); then
      token=${ALL_STEPS[$((token - 1))]}
    fi
    [[ -n ${STEP_DESC[$token]:-} ]] || die "unknown step: $token"
    SELECTED[$token]=1
  done
  ((${#SELECTED[@]})) || die "no steps selected"
}

user_needs_password() {
  id "$NEW_USER" &>/dev/null || return 0
  [[ $(passwd -S "$NEW_USER" | awk '{print $2}') != P ]]
}

collect_inputs() {
  if is_selected base || is_selected postgres || is_selected pm2; then
    prompt_var NEW_USER "Linux user to create/use"
    require_var NEW_USER "base/postgres/pm2"
  fi
  if is_selected base; then
    prompt_var TIMEZONE "Timezone"
    prompt_var SWAP_SIZE "Swap size (e.g. 1G, 2G; 0 to skip)"
    if [[ -z $NEW_USER_PASSWORD ]] && user_needs_password && interactive; then
      local again
      prompt_var NEW_USER_PASSWORD "Password for $NEW_USER (needed for sudo)" secret
      read -rsp "Repeat password: " again; echo
      [[ $NEW_USER_PASSWORD == "$again" ]] || die "passwords do not match"
    fi
  fi
  if is_selected nginx || is_selected ssl; then
    prompt_var DOMAINS "Domains (comma/space separated, primary first; empty = no site)"
    DOMAINS=$(tr ',' ' ' <<<"$DOMAINS" | xargs)
  fi
  if is_selected nginx; then
    prompt_var APP_PORT "Local port nginx proxies to"
  fi
  if is_selected postgres; then
    prompt_var PG_VERSION "PostgreSQL major version (empty = Ubuntu default)"
    if [[ -z $PG_PASSWORD ]] && interactive; then
      prompt_var PG_PASSWORD "Password for Postgres role $NEW_USER (empty = peer auth only)" secret
    fi
  fi
  if is_selected node; then
    prompt_var NODE_MAJOR "Node.js major version ('lts' or e.g. 24)"
  fi
  if is_selected ssl; then
    require_var DOMAINS ssl
    prompt_var LE_EMAIL "Email for Let's Encrypt expiry notices"
    require_var LE_EMAIL ssl
  fi
}

validate() {
  if [[ -n $NEW_USER ]]; then
    [[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid NEW_USER: $NEW_USER"
  fi
  [[ $APP_PORT =~ ^[0-9]+$ ]] && ((APP_PORT >= 1 && APP_PORT <= 65535)) || die "invalid APP_PORT: $APP_PORT"
  [[ $SWAP_SIZE == 0 || $SWAP_SIZE =~ ^[0-9]+[MG]$ ]] || die "invalid SWAP_SIZE: $SWAP_SIZE (use e.g. 2G or 0)"
  [[ $NODE_MAJOR == lts || $NODE_MAJOR =~ ^[0-9]+$ ]] || die "invalid NODE_MAJOR: $NODE_MAJOR"
  [[ -z $PG_VERSION || $PG_VERSION =~ ^[0-9]+$ ]] || die "invalid PG_VERSION: $PG_VERSION"
  [[ $HSTS_MAX_AGE =~ ^[0-9]+$ ]] || die "invalid HSTS_MAX_AGE: $HSTS_MAX_AGE"
  [[ $PG_MAX_CONNECTIONS =~ ^[1-9][0-9]*$ ]] || die "invalid PG_MAX_CONNECTIONS: $PG_MAX_CONNECTIONS"
  [[ $CLIENT_MAX_BODY_SIZE =~ ^[0-9]+[kKmMgG]?$ ]] || die "invalid CLIENT_MAX_BODY_SIZE"
  [[ -e /usr/share/zoneinfo/$TIMEZONE ]] || die "unknown TIMEZONE: $TIMEZONE"
  local d
  for d in $DOMAINS; do
    [[ $d =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "invalid domain: $d (wildcards need a DNS challenge; not supported)"
  done
}

show_plan() {
  local s
  log "Plan"
  for s in "${ALL_STEPS[@]}"; do
    if is_selected "$s"; then info "[x] $s — ${STEP_DESC[$s]}"; fi
  done
  echo
  info "NEW_USER=$NEW_USER  TIMEZONE=$TIMEZONE  SWAP_SIZE=$SWAP_SIZE"
  info "DISABLE_ROOT_LOGIN=$DISABLE_ROOT_LOGIN  DISABLE_PASSWORD_AUTH=$DISABLE_PASSWORD_AUTH"
  info "DOMAINS=${DOMAINS:-<none>}  APP_PORT=$APP_PORT  CLIENT_MAX_BODY_SIZE=$CLIENT_MAX_BODY_SIZE"
  info "PG_VERSION=${PG_VERSION:-<ubuntu default>}  PG_CREATE_DB=$PG_CREATE_DB  PG_PASSWORD=${PG_PASSWORD:+<set>}"
  info "PG_TUNE=$PG_TUNE  PG_MAX_CONNECTIONS=$PG_MAX_CONNECTIONS"
  info "NODE_MAJOR=$NODE_MAJOR  LE_EMAIL=${LE_EMAIL:-<none>}  LE_STAGING=$LE_STAGING"
  info "HSTS_MAX_AGE=$HSTS_MAX_AGE  HSTS_INCLUDE_SUBDOMAINS=$HSTS_INCLUDE_SUBDOMAINS"
  if interactive; then
    local reply
    read -rp $'\nProceed? [y/N]: ' reply
    is_yes "${reply:-n}" || die "aborted by user"
  fi
}

preflight() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
  [[ -r /etc/os-release ]] || die "cannot detect OS"
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ ${ID:-} != ubuntu || ${VERSION_ID%%.*} -lt 24 ]]; then
    confirm_or_die "Tested on Ubuntu 24.04+ only; this is ${PRETTY_NAME:-unknown}."
  fi
}

# ------------------------------------------------------------------ steps ---

step_base() {
  log "base: system upgrade"
  apt_update
  apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt_install curl ca-certificates gnupg ufw

  log "base: timezone -> $TIMEZONE"
  timedatectl set-timezone "$TIMEZONE"

  log "base: user $NEW_USER"
  if id "$NEW_USER" &>/dev/null; then
    info "user exists"
  else
    adduser --disabled-password --gecos "" "$NEW_USER"
  fi
  usermod -aG sudo "$NEW_USER"
  if [[ -n $NEW_USER_PASSWORD ]]; then
    printf '%s:%s\n' "$NEW_USER" "$NEW_USER_PASSWORD" | chpasswd
    info "password set"
  elif user_needs_password; then
    warn "$NEW_USER has no password, so sudo will not work. Set one with: passwd $NEW_USER"
  fi

  log "base: SSH keys"
  local home ak
  home=$(user_home)
  ak="$home/.ssh/authorized_keys"
  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$home/.ssh"
  # Merge (not move) root's keys + SSH_PUBLIC_KEY into the user's, dropping duplicates.
  {
    [[ -f $ak ]] && cat "$ak"
    [[ -f /root/.ssh/authorized_keys ]] && cat /root/.ssh/authorized_keys
    [[ -n $SSH_PUBLIC_KEY ]] && printf '%s\n' "$SSH_PUBLIC_KEY"
    true
  } | awk 'NF && !seen[$0]++' >"$ak.tmp"
  mv "$ak.tmp" "$ak"
  chown "$NEW_USER:$NEW_USER" "$ak"
  chmod 600 "$ak"
  info "$(wc -l <"$ak") key(s) in $ak"

  log "base: firewall"
  ufw allow OpenSSH >/dev/null
  ufw --force enable >/dev/null
  ufw status | sed 's/^/    /'

  setup_swap
  harden_ssh
}

setup_swap() {
  log "base: swap"
  if [[ $SWAP_SIZE == 0 ]]; then
    info "SWAP_SIZE=0, skipping"
    return
  fi
  if swapon --show --noheadings | grep -q .; then
    info "swap already active: $(swapon --show --noheadings | awk '{print $1, $3}' | xargs)"
  else
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    info "created /swapfile ($SWAP_SIZE)"
  fi
  cat >/etc/sysctl.d/60-droplet-swap.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  sysctl -q -p /etc/sysctl.d/60-droplet-swap.conf
}

harden_ssh() {
  log "base: SSH hardening"
  local ak conf=/etc/ssh/sshd_config.d/00-droplet-setup.conf
  ak="$(user_home)/.ssh/authorized_keys"
  if [[ ! -s $ak ]]; then
    warn "no SSH keys for $NEW_USER — leaving root login and password auth untouched to avoid a lockout"
    return
  fi
  grep -qE '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config \
    || warn "sshd_config does not include sshd_config.d/*.conf; hardening below may not apply"
  # sshd uses the FIRST value it reads for each keyword, and cloud-init drops
  # files like 50-cloud-init.conf (PasswordAuthentication yes). 00- sorts first.
  {
    echo "# Managed by droplet-setup.sh"
    is_yes "$DISABLE_ROOT_LOGIN" && echo "PermitRootLogin no"
    if is_yes "$DISABLE_PASSWORD_AUTH"; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
    fi
    echo "PubkeyAuthentication yes"
    echo "X11Forwarding no"
    echo "MaxAuthTries 5"
  } >"$conf"
  if ! sshd -t; then
    rm -f "$conf"
    die "generated sshd config is invalid; removed $conf"
  fi
  systemctl try-reload-or-restart ssh
  sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) ' | sed 's/^/    effective: /'
  warn "BEFORE closing this session: open a new terminal, run 'ssh $NEW_USER@<ip>' and 'sudo -v'."
}

step_hardening() {
  log "hardening: unattended security upgrades"
  apt_install unattended-upgrades fail2ban python3-systemd
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  log "hardening: fail2ban (sshd jail)"
  cat >/etc/fail2ban/jail.d/00-droplet-sshd.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 2
  fail2ban-client status sshd | sed 's/^/    /' || warn "fail2ban sshd jail not reporting yet; check: fail2ban-client status sshd"

  log "hardening: journald size cap (500M)"
  install -d /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/00-droplet-size.conf <<'EOF'
[Journal]
SystemMaxUse=500M
EOF
  systemctl restart systemd-journald
}

step_nginx() {
  log "nginx: install"
  apt_install nginx
  if ufw status | grep -q 'Nginx Full'; then
    info "UFW already allows 'Nginx Full'"
  else
    ufw allow 'Nginx HTTP' >/dev/null
  fi

  log "nginx: hardened defaults"
  local hardening=/etc/nginx/conf.d/00-droplet-hardening.conf
  cat >"$hardening" <<'EOF'
# Managed by droplet-setup.sh. Only directives Ubuntu's nginx.conf leaves commented out.
server_tokens off;
server_names_hash_bucket_size 64;
client_body_timeout 15s;
client_header_timeout 15s;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css text/xml application/json application/javascript application/xml application/rss+xml image/svg+xml;
EOF
  if ! nginx -t -q; then
    rm -f "$hardening"
    warn "nginx rejected $hardening (a directive is probably already set in nginx.conf); removed it"
  fi

  cat >/etc/nginx/conf.d/01-websocket-upgrade.conf <<'EOF'
# Managed by droplet-setup.sh. Used by proxied vhosts for WebSocket upgrades.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

  cat >/etc/nginx/snippets/security-headers.conf <<'EOF'
# Managed by droplet-setup.sh. Note: a location-level add_header disables these.
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF

  if [[ -z $DOMAINS ]]; then
    warn "DOMAINS empty: keeping Ubuntu's default site, no reverse proxy created"
    nginx -t -q
    systemctl reload nginx
    return
  fi

  local primary site
  primary=$(primary_domain)
  site=/etc/nginx/sites-available/$primary

  log "nginx: default-deny catch-all"
  # Requests for unknown Host headers (IP scans) get dropped instead of hitting the app.
  cat >/etc/nginx/sites-available/00-default-deny <<'EOF'
# Managed by droplet-setup.sh
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_reject_handshake on;
    server_name _;
    return 444;
}
EOF
  ln -sfn /etc/nginx/sites-available/00-default-deny /etc/nginx/sites-enabled/00-default-deny
  rm -f /etc/nginx/sites-enabled/default

  log "nginx: site $primary -> 127.0.0.1:$APP_PORT"
  # Filled by the ssl step; empty until HTTPS exists (HSTS over HTTP is ignored anyway).
  [[ -f /etc/nginx/snippets/hsts-$primary.conf ]] \
    || echo "# HSTS for $primary — written by the ssl step" >"/etc/nginx/snippets/hsts-$primary.conf"

  if [[ -f $site ]] && grep -q 'managed by Certbot' "$site"; then
    info "$site already modified by certbot; not overwriting (edit by hand)"
  else
    [[ -f $site ]] && cp "$site" "$site.bak.$(date +%Y%m%d%H%M%S)"
    cat >"$site" <<EOF
# Generated by droplet-setup.sh
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAINS;

    include snippets/security-headers.conf;
    include snippets/hsts-$primary.conf;

    client_max_body_size $CLIENT_MAX_BODY_SIZE;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
  fi
  ln -sfn "$site" "/etc/nginx/sites-enabled/$primary"
  nginx -t -q
  systemctl reload nginx
  info "nginx $(nginx -v 2>&1 | cut -d/ -f2) reloaded"
}

step_postgres() {
  log "postgres: install"
  if [[ -z $PG_VERSION ]]; then
    apt_install postgresql postgresql-contrib
  else
    # PGDG repo (apt.postgresql.org). Since PG 10, contrib ships inside postgresql-N.
    . /etc/os-release
    local suite="${VERSION_CODENAME}-pgdg"
    curl -fsI "https://apt.postgresql.org/pub/repos/apt/dists/$suite/Release" >/dev/null \
      || die "PGDG has no repo for $suite yet; leave PG_VERSION empty to use Ubuntu's version"
    apt_install postgresql-common
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
    cat >/etc/apt/sources.list.d/pgdg.sources <<EOF
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: $suite
Components: main
Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
EOF
    apt_update force
    apt_install "postgresql-$PG_VERSION"
  fi
  systemctl enable --now postgresql >/dev/null 2>&1
  pg_lsclusters | sed 's/^/    /'

  log "postgres: role $NEW_USER"
  if [[ -n $(pg -tA -v u="$NEW_USER" <<<"SELECT 1 FROM pg_roles WHERE rolname = :'u'") ]]; then
    info "role exists"
  else
    pg -v u="$NEW_USER" <<<'CREATE ROLE :"u" WITH LOGIN CREATEDB;'
    info "role created (LOGIN CREATEDB, not superuser)"
  fi
  if [[ -n $PG_PASSWORD ]]; then
    # Password goes through stdin, not argv, so it never shows up in `ps`.
    printf "ALTER ROLE :\"u\" WITH PASSWORD '%s';\n" "${PG_PASSWORD//\'/\'\'}" | pg -v u="$NEW_USER"
    info "role password set (for TCP connections to localhost)"
  fi

  if is_yes "$PG_CREATE_DB"; then
    if [[ -n $(pg -tA -v u="$NEW_USER" <<<"SELECT 1 FROM pg_database WHERE datname = :'u'") ]]; then
      info "database $NEW_USER exists"
    else
      pg -v u="$NEW_USER" <<<'CREATE DATABASE :"u" OWNER :"u";'
      info "database $NEW_USER created"
    fi
  fi

  if is_yes "$PG_TUNE"; then tune_postgres; fi
}

# Sizes memory settings from the droplet's RAM (PGTune "web" profile, SSD disks).
tune_postgres() {
  log "postgres: tuning"
  local version confdir conf ram_mb shared_mb cache_mb maint_mb work_mb
  version=${PG_VERSION:-$(pg_lsclusters -h | awk '{print $1}' | sort -n | tail -1)}
  confdir=/etc/postgresql/$version/main/conf.d
  conf=$confdir/00-droplet-tuning.conf
  [[ -d /etc/postgresql/$version/main ]] || die "no cluster at /etc/postgresql/$version/main"
  grep -qE "^include_dir = 'conf.d'" "/etc/postgresql/$version/main/postgresql.conf" \
    || die "postgresql.conf for $version does not include conf.d; tune by hand"

  ram_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  shared_mb=$((ram_mb / 4))
  cache_mb=$((ram_mb * 3 / 4))
  maint_mb=$((ram_mb / 16))
  ((maint_mb > 1024)) && maint_mb=1024
  # Each query can use work_mem per sort/hash node, so divide by connections x 3.
  work_mb=$(((ram_mb - shared_mb) / (PG_MAX_CONNECTIONS * 3)))
  ((work_mb < 4)) && work_mb=4

  install -d -o postgres -g postgres "$confdir"
  cat >"$conf.tmp" <<EOF
# Managed by droplet-setup.sh — sized for ${ram_mb}MB RAM, $PG_MAX_CONNECTIONS connections, SSD.
# Re-run the postgres step after resizing the droplet. ALTER SYSTEM values override this file.
max_connections = $PG_MAX_CONNECTIONS
shared_buffers = ${shared_mb}MB
effective_cache_size = ${cache_mb}MB
maintenance_work_mem = ${maint_mb}MB
work_mem = ${work_mb}MB
random_page_cost = 1.1
effective_io_concurrency = 200
EOF
  if [[ -f $conf ]] && cmp -s "$conf" "$conf.tmp"; then
    rm -f "$conf.tmp"
    info "tuning unchanged; no restart"
    return
  fi
  mv "$conf.tmp" "$conf"
  chown postgres:postgres "$conf"
  # shared_buffers and max_connections only apply on restart (a few seconds of downtime).
  systemctl restart "postgresql@$version-main"
  pg -tA <<<"SELECT name || ' = ' || setting || COALESCE(unit, '') FROM pg_settings
    WHERE name IN ('max_connections','shared_buffers','effective_cache_size','maintenance_work_mem','work_mem')
    ORDER BY name" | sed 's/^/    /'
}

step_node() {
  log "node: NodeSource ($NODE_MAJOR)"
  apt_install curl ca-certificates gnupg build-essential
  local setup=/tmp/nodesource_setup.sh
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$setup"
  bash "$setup" >/dev/null
  rm -f "$setup"
  APT_UPDATED=yes # the NodeSource script runs apt-get update itself
  apt_install nodejs

  log "node: pnpm"
  npm install -g --no-fund --no-audit --silent pnpm@latest
  info "node $(node -v), npm $(npm -v), pnpm $(pnpm -v)"
}

step_pm2() {
  command -v npm >/dev/null || die "pm2 needs Node.js; run the node step first"
  id "$NEW_USER" &>/dev/null || die "user $NEW_USER does not exist; run the base step first"
  local home
  home=$(user_home)

  log "pm2: install"
  npm install -g --no-fund --no-audit --silent pm2@latest

  log "pm2: systemd unit pm2-$NEW_USER"
  env PATH="$PATH:/usr/bin" pm2 startup systemd -u "$NEW_USER" --hp "$home" >/dev/null
  systemctl enable --now "pm2-$NEW_USER" >/dev/null 2>&1
  systemctl is-active --quiet "pm2-$NEW_USER" && info "pm2-$NEW_USER is active"

  log "pm2: pm2-logrotate"
  if as_user pm2 jlist 2>/dev/null | grep -q '"name":"pm2-logrotate"'; then
    info "already installed"
  else
    as_user pm2 install pm2-logrotate >/dev/null
  fi
  as_user pm2 set pm2-logrotate:max_size 10M >/dev/null
  as_user pm2 set pm2-logrotate:retain 14 >/dev/null
  as_user pm2 set pm2-logrotate:compress true >/dev/null
  info "logrotate: 10M per file, 14 files kept, gzip"
}

step_ssl() {
  command -v nginx >/dev/null || die "ssl needs nginx; run the nginx step first"
  local primary site d resolved ip
  primary=$(primary_domain)
  site=/etc/nginx/sites-available/$primary

  log "ssl: DNS check"
  ip=$(public_ipv4)
  for d in $DOMAINS; do
    resolved=$(getent ahostsv4 "$d" | awk '{print $1; exit}' || true)
    if [[ -z $resolved ]]; then
      confirm_or_die "$d does not resolve; certbot will fail."
    elif [[ -n $ip && $resolved != "$ip" ]]; then
      confirm_or_die "$d resolves to $resolved but this droplet is $ip (proxied DNS such as Cloudflare also causes this)."
    else
      info "$d -> $resolved"
    fi
  done

  log "ssl: certbot"
  apt_install certbot python3-certbot-nginx
  ufw allow 'Nginx Full' >/dev/null
  ufw delete allow 'Nginx HTTP' >/dev/null 2>&1 || true

  local args=(--nginx --non-interactive --agree-tos -m "$LE_EMAIL" --redirect --keep-until-expiring --cert-name "$primary")
  for d in $DOMAINS; do args+=(-d "$d"); done
  is_yes "$LE_STAGING" && args+=(--staging)
  certbot "${args[@]}"

  log "ssl: HSTS"
  local hsts=/etc/nginx/snippets/hsts-$primary.conf
  if ((HSTS_MAX_AGE == 0)); then
    echo "# HSTS disabled (HSTS_MAX_AGE=0)" >"$hsts"
    info "disabled"
  else
    local value="max-age=$HSTS_MAX_AGE"
    is_yes "$HSTS_INCLUDE_SUBDOMAINS" && value+="; includeSubDomains"
    printf '# Managed by droplet-setup.sh\nadd_header Strict-Transport-Security "%s" always;\n' "$value" >"$hsts"
    info "Strict-Transport-Security: $value"
  fi
  [[ -f $site ]] && grep -q "snippets/hsts-$primary.conf" "$site" \
    || warn "$site does not include snippets/hsts-$primary.conf; add 'include snippets/hsts-$primary.conf;' to its 443 server block"
  nginx -t -q
  systemctl reload nginx

  log "ssl: verify"
  systemctl is-active --quiet certbot.timer && info "certbot.timer active (auto-renewal)" \
    || warn "certbot.timer not active; renewal will not run automatically"
  certbot renew --dry-run --cert-name "$primary" >/dev/null 2>&1 && info "renewal dry-run OK" \
    || warn "renewal dry-run failed; run: certbot renew --dry-run"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$primary/" || true)
  info "http://$primary  -> HTTP $code (expect 301)"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$primary/" || true)
  info "https://$primary -> HTTP $code (502 just means no app listens on $APP_PORT yet)"
  info "TLS protocols/ciphers come from /etc/letsencrypt/options-ssl-nginx.conf (certbot-managed; do not edit)"
}

# ------------------------------------------------------------------- main ---

next_steps() {
  log "Done"
  is_selected base && info "- Verify SSH as $NEW_USER in a NEW terminal before logging out of root."
  is_selected postgres && info "- DATABASE_URL=postgres://$NEW_USER:<password>@127.0.0.1:5432/$NEW_USER (or peer auth over the socket)"
  is_selected pm2 && info "- As $NEW_USER: pm2 start ecosystem.config.js && pm2 save   (save is what survives reboots)"
  [[ -f /var/run/reboot-required ]] && warn "a reboot is required (kernel/libc updates): sudo reboot"
  info "- Log: $LOG_FILE"
}

main() {
  parse_args "$@"
  load_config
  preflight
  select_steps
  collect_inputs
  validate
  show_plan

  # Log from here on (after prompts, so typed secrets never reach the log).
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "droplet-setup started $(date -Is)"

  local s
  for s in "${ALL_STEPS[@]}"; do
    if is_selected "$s"; then "step_$s"; fi
  done
  next_steps
}

main "$@"

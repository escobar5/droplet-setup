# droplet-setup

One script that turns a fresh Ubuntu droplet into a host for small Node.js apps: a sudo user with SSH keys, UFW, swap, nginx as a reverse proxy, PostgreSQL, Node.js + pnpm, pm2 under systemd, and Let's Encrypt HTTPS.

Every step checks the current state before changing anything, so the script is safe to re-run, and you can run any subset of steps.

## Requirements

- Ubuntu 24.04 or newer (it asks for confirmation on anything else, and the nginx config needs nginx 1.19.4+).
- Run as root, or with `sudo` once the base step has created your user.
- Your SSH public key on the droplet (add it when creating the droplet). Without it, root login and password login are left enabled to avoid locking you out.
- For the `ssl` step: DNS A records for every domain pointing at the droplet, unproxied (Cloudflare's orange cloud breaks the HTTP challenge).

## Quick start

On the droplet, as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/escobar5/droplet-setup/main/droplet-setup.sh
less droplet-setup.sh                # read what you are about to run as root
chmod +x droplet-setup.sh
./droplet-setup.sh
```

Download the file and then run it. Don't use `curl ... | bash`: the script reads its prompts from stdin, which would then be the script itself.

To get the same version on every droplet, replace `main` in the URL with a commit SHA or tag.

To run from a config file, copy it over from your machine (it may contain passwords, so it is not in the repo):

```bash
cp droplet.env.example droplet.env   # then edit it
scp droplet.env root@<ip>:~
ssh -t root@<ip> './droplet-setup.sh --config droplet.env'
```

Before closing the root session, open a **new** terminal and confirm you can log in as the new user and use sudo:

```bash
ssh <user>@<ip>
sudo -v
```

## Ways to run it

```bash
# Interactive: choose steps from a menu, answer prompts for missing values
./droplet-setup.sh

# Fully non-interactive from a config file (fails instead of prompting)
./droplet-setup.sh --config droplet.env --yes

# Only some steps, values from flags
./droplet-setup.sh --steps nginx,ssl --domains "app.com,www.app.com" --app-port 3000 --email me@app.com

# Any setting with --set (repeatable)
sudo ./droplet-setup.sh --steps postgres --set PG_VERSION=18 --set PG_MAX_CONNECTIONS=40
```

| Flag | Meaning |
| --- | --- |
| `-c, --config FILE` | Read `KEY="value"` settings from FILE |
| `-s, --steps LIST` | Comma-separated step names or numbers, or `all` |
| `-u, --user NAME` | Sets `NEW_USER` |
| `-d, --domains LIST` | Sets `DOMAINS`; the first one is the primary |
| `-p, --app-port PORT` | Sets `APP_PORT` |
| `-e, --email EMAIL` | Sets `LE_EMAIL` |
| `--set KEY=VALUE` | Sets any config key |
| `-y, --yes` | Never prompt |
| `-h, --help` | Show help |

Settings are resolved in this order, highest first: flags, config file, environment variables, built-in defaults. When run with `sudo` from a normal user, `NEW_USER` defaults to that user.

## Steps

Steps always run in this order, however you list them.

| # | Step | What it does |
| --- | --- | --- |
| 1 | `base` | apt upgrade, timezone, creates `NEW_USER` with sudo, merges root's SSH keys into the user's, UFW allowing OpenSSH, swap file, SSH hardening (no root login, no password login) |
| 2 | `hardening` | fail2ban jail for sshd, unattended security upgrades, 500 MB cap on the systemd journal |
| 3 | `nginx` | nginx, UFW rule, hardened defaults (no version header, gzip), security headers, a catch-all site that drops requests for unknown hosts, and a reverse-proxy site for `DOMAINS` → `127.0.0.1:APP_PORT` with WebSocket support |
| 4 | `postgres` | PostgreSQL + contrib, a role named `NEW_USER` (LOGIN, CREATEDB, not superuser), a database with the same name, and memory settings sized from the droplet's RAM |
| 5 | `node` | Node.js from NodeSource, pnpm, build-essential for native modules |
| 6 | `pm2` | pm2, a `pm2-<user>` systemd service so apps survive reboots, pm2-logrotate (10 MB files, 14 kept, gzipped) |
| 7 | `ssl` | Checks DNS, installs certbot, gets a certificate for all `DOMAINS`, redirects HTTP to HTTPS, adds HSTS, verifies renewal with a dry run |

`pm2` needs `node`, and `ssl` needs `nginx`; the script stops with a clear message if they're missing.

## Configuration

Copy `droplet.env.example` to `droplet.env`. `*.env` files are git-ignored because they can hold passwords.

| Key | Default | Notes |
| --- | --- | --- |
| `STEPS` | — | e.g. `all` or `base,nginx` |
| `ASSUME_YES` | `no` | `yes` = same as `--yes` |
| `NEW_USER` | — | Linux user, sudoer, Postgres role, pm2 owner |
| `NEW_USER_PASSWORD` | — | Needed for sudo; prompted if empty and interactive |
| `SSH_PUBLIC_KEY` | — | Extra key added alongside root's keys |
| `TIMEZONE` | `UTC` | Keep servers on UTC |
| `SWAP_SIZE` | `2G` | `0` skips swap |
| `DISABLE_ROOT_LOGIN` | `yes` | |
| `DISABLE_PASSWORD_AUTH` | `yes` | |
| `DOMAINS` | — | Space or comma separated; empty = keep nginx's default page |
| `APP_PORT` | `3000` | Where your app listens |
| `CLIENT_MAX_BODY_SIZE` | `10m` | Max upload size through nginx |
| `PG_VERSION` | Ubuntu's | A major version (e.g. `18`) installs from apt.postgresql.org |
| `PG_CREATE_DB` | `yes` | Database named after `NEW_USER` |
| `PG_PASSWORD` | — | Empty = socket (peer) login only, no TCP password |
| `PG_TUNE` | `yes` | RAM-based memory settings |
| `PG_MAX_CONNECTIONS` | `50` | Sum of your apps' pool sizes + ~5 |
| `NODE_MAJOR` | `lts` | Or a major version, e.g. `24` |
| `LE_EMAIL` | — | Let's Encrypt expiry notices |
| `LE_STAGING` | `no` | `yes` uses Let's Encrypt's test server (no rate limits, untrusted certs) |
| `HSTS_MAX_AGE` | `31536000` | Seconds; `0` disables HSTS |
| `HSTS_INCLUDE_SUBDOMAINS` | `no` | Only `yes` if every subdomain serves HTTPS |

## After setup

Start your app as the new user and save the process list, otherwise pm2 won't restore it after a reboot:

```bash
pm2 start ecosystem.config.js
pm2 save
```

Connect the app to Postgres over the socket (no password) or TCP (needs `PG_PASSWORD`):

```
DATABASE_URL=postgres://<user>:<password>@127.0.0.1:5432/<user>
```

To reach Postgres from your machine, tunnel over SSH instead of opening port 5432:

```bash
ssh -L 5433:localhost:5432 <user>@<ip>
```

If the script prints that a reboot is required, run `sudo reboot`.

## Re-running

- Re-running a step is safe. Existing users, roles, databases, swap and certificates are kept.
- After resizing the droplet, run `sudo ./droplet-setup.sh -s postgres -y` to resize the Postgres memory settings. It restarts Postgres only when the values change.
- Once certbot has edited a site file, the `nginx` step leaves that file alone; edit it by hand.
- Before a site file is overwritten, a timestamped `.bak` copy is saved next to it.
- Everything the script prints is also appended to `/var/log/droplet-setup.log` (passwords are never logged).

## Files the script manages

| Path | Purpose |
| --- | --- |
| `/etc/ssh/sshd_config.d/00-droplet-setup.conf` | SSH hardening (named `00-` so it wins over cloud-init's file) |
| `/etc/sysctl.d/60-droplet-swap.conf` | Swappiness settings |
| `/etc/fail2ban/jail.d/00-droplet-sshd.local` | fail2ban sshd jail |
| `/etc/systemd/journald.conf.d/00-droplet-size.conf` | Journal size cap |
| `/etc/nginx/conf.d/00-droplet-hardening.conf` | nginx hardening and gzip |
| `/etc/nginx/conf.d/01-websocket-upgrade.conf` | WebSocket upgrade map |
| `/etc/nginx/snippets/security-headers.conf` | Security headers |
| `/etc/nginx/snippets/hsts-<domain>.conf` | HSTS header, filled by the `ssl` step |
| `/etc/nginx/sites-available/00-default-deny` | Catch-all for unknown hosts |
| `/etc/nginx/sites-available/<domain>` | Reverse-proxy site |
| `/etc/postgresql/<ver>/main/conf.d/00-droplet-tuning.conf` | Postgres memory settings |

## Known limitations

- Not yet run end to end on a real droplet. Test on a throwaway droplet with `LE_STAGING=yes` first.
- certbot may add `ipv6only=on` to the HTTPS listener in a way nginx rejects next to the catch-all site. If so, certbot rolls back and shows the nginx error.
- If your app sets its own security headers (e.g. helmet), they will be duplicated with nginx's; remove them on one side.
- Wildcard certificates are not supported (they need a DNS challenge).
- The SSH port is not changed; restrict port 22 with a DigitalOcean Cloud Firewall instead.

## Also recommended (outside this script)

- A DigitalOcean Cloud Firewall allowing only 22, 80 and 443, ideally with 22 limited to your IP.
- Droplet backups, plus a daily `pg_dump` to Spaces or S3 (disk snapshots of a running database aren't reliable).
- Monitoring enabled at droplet creation, with disk, memory and CPU alerts, and an uptime check on your app.
- Rate limiting (`limit_req`) in nginx for login and auth routes.

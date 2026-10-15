# erpnext/ — ERPNext + HRMS on Railway

One container runs nginx, gunicorn, socketio, scheduler and a worker under supervisord.
Base image: `ghcr.io/frappe/hrms` (frappe + erpnext + hrms), pinned in the Dockerfile.

## Railway service settings
| Setting | Value |
|---|---|
| Source | this repo, branch `main`, root directory `erpnext` |
| Volume | mount at `/data` (only the site folder lives here) |
| Healthcheck | path `/api/method/ping`, timeout 1200 s (first boot creates the site) |
| Public domains | `erp.ecolattice.uk`, `adminerp.ecolattice.uk`, target port 8080 |

## Variables
| Variable | Value |
|---|---|
| `SITE_NAME` | `erp.ecolattice.uk` (permanent) |
| `ADMIN_PASSWORD` | Frappe Administrator password (used on first boot only) |
| `INSTALL_APPS` | `erpnext,hrms` |
| `DB_HOST` / `DB_PORT` | `mariadb.railway.internal` / `3306` |
| `DB_ROOT_PASSWORD` | `${{mariadb.MARIADB_ROOT_PASSWORD}}` |
| `REDIS_CACHE` | `redis://redis-cache.railway.internal:6379` |
| `REDIS_QUEUE` | `redis://redis-queue.railway.internal:6379` |
| `MCP_AGENT_API_KEY` / `MCP_AGENT_API_SECRET` | `openssl rand -hex 8` / `openssl rand -hex 16` |
| `RAILWAY_RUN_UID` | `0` |
| `PORT` | `8080` |
| `GUNICORN_WORKERS` (optional) | default `2` |

## Upgrade
Change the tag in `Dockerfile`, push, deploy. The entrypoint runs `bench migrate`
when `bench version` output changes. Take a backup first.

## Debug
`railway ssh` into the service, then `cd /home/frappe/frappe-bench && runuser -u frappe -- bench --site erp.ecolattice.uk console`.

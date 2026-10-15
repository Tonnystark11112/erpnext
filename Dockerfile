# ERPNext + HRMS wrapper for Railway (single container, supervisord)
# Base: official Frappe image that bundles frappe + erpnext + hrms.
# Bump the tag to upgrade; the entrypoint runs `bench migrate` when app versions change.
ARG BASE_IMAGE=ghcr.io/frappe/hrms:v16.20.1
FROM ${BASE_IMAGE}

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends supervisor nginx \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

COPY supervisord.conf        /etc/supervisor/frappe-supervisord.conf
COPY nginx.conf.template     /opt/railway/nginx.conf.template
COPY provision_mcp_agent.py  /opt/railway/provision_mcp_agent.py
COPY entrypoint.sh           /opt/railway/entrypoint.sh
RUN chmod +x /opt/railway/entrypoint.sh

ENV PORT=8080
EXPOSE 8080
WORKDIR /home/frappe/frappe-bench

# Starts as root (RAILWAY_RUN_UID=0) to fix volume ownership; all app processes run as `frappe`.
ENTRYPOINT ["/opt/railway/entrypoint.sh"]
CMD []

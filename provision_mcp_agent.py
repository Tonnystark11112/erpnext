"""Idempotently create the MCP Agent role and service user, and set its API key/secret.

Runs on every boot. Rotating the key = change the Railway variables and redeploy.
The role starts with NO DocType permissions; grant them in Role Permissions Manager.
"""
import os

import frappe
from frappe.utils.password import get_decrypted_password

SITE = os.environ["SITE_NAME"]
KEY = os.environ["MCP_AGENT_API_KEY"]
SECRET = os.environ["MCP_AGENT_API_SECRET"]
EMAIL = os.environ.get("MCP_AGENT_EMAIL") or f"mcp-agent@{SITE}"
ROLE = "MCP Agent"

frappe.init(site=SITE, sites_path="/home/frappe/frappe-bench/sites")
frappe.connect()
try:
    frappe.set_user("Administrator")

    if not frappe.db.exists("Role", ROLE):
        frappe.get_doc({"doctype": "Role", "role_name": ROLE, "desk_access": 1}).insert(
            ignore_permissions=True
        )

    if frappe.db.exists("User", EMAIL):
        user = frappe.get_doc("User", EMAIL)
    else:
        user = frappe.get_doc({
            "doctype": "User",
            "email": EMAIL,
            "first_name": "MCP",
            "last_name": "Agent",
            "send_welcome_email": 0,
            "enabled": 1,
        })
        user.insert(ignore_permissions=True)

    changed = False
    if not user.enabled:
        user.enabled = 1
        changed = True
    if ROLE not in [r.role for r in user.roles]:
        user.append("roles", {"role": ROLE})
        changed = True

    current_secret = None
    if user.api_key:
        current_secret = get_decrypted_password("User", EMAIL, "api_secret", raise_exception=False)
    if user.api_key != KEY or current_secret != SECRET:
        user.api_key = KEY
        user.api_secret = SECRET
        changed = True

    if changed:
        user.flags.ignore_permissions = True
        user.save()
    frappe.db.commit()
    print(f"[provision] MCP Agent user ready: {EMAIL} (updated={changed})")
finally:
    frappe.destroy()

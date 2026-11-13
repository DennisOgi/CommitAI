"""Create (or reset) two test accounts for trying Commit AI on two phones.

  manager@commitai.test  -> "Test Manager",  linked to the test company's EMP-1001 (manager)
  employee@commitai.test -> "Test Employee", linked to the test company's EMP-1043

The password is typed by you at the prompt (it is not stored in this file or passed on the
command line). Uses SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY from server/.env.

    .venv\\Scripts\\python.exe scripts\\create_test_accounts.py
"""
import getpass
import sys
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from commitai.config import settings  # noqa: E402

ACCOUNTS = [
    ("manager@commitai.test", "Test Manager", "EMP-1001"),
    ("employee@commitai.test", "Test Employee", "EMP-1043"),
]
COMPANY = "LUMEN"


def main() -> None:
    if not settings.use_supabase:
        sys.exit("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set in server/.env")
    pw = getpass.getpass("Password for both test accounts: ")
    if len(pw) < 6:
        sys.exit("Supabase needs at least 6 characters.")
    if getpass.getpass("Type it again: ") != pw:
        sys.exit("The two entries didn't match.")

    base = settings.supabase_url.rstrip("/")
    h = {"apikey": settings.supabase_service_key, "Authorization": f"Bearer {settings.supabase_service_key}"}
    with httpx.Client(timeout=20, headers=h) as http:
        org = http.get(f"{base}/rest/v1/organizations", params={"corp_code": f"eq.{COMPANY}", "select": "id,name"}).json()
        if not org:
            sys.exit(f"Test company {COMPANY} not found.")
        org_id = org[0]["id"]
        existing = {u["email"]: u["id"] for u in http.get(f"{base}/auth/v1/admin/users", params={"per_page": 1000}).json().get("users", [])}

        for email, name, emp in ACCOUNTS:
            if email in existing:
                uid = existing[email]
                r = http.put(f"{base}/auth/v1/admin/users/{uid}", json={"password": pw, "email_confirm": True})
                action = "password reset"
            else:
                r = http.post(f"{base}/auth/v1/admin/users", json={
                    "email": email, "password": pw, "email_confirm": True, "user_metadata": {"full_name": name}})
                action = "created"
            if r.status_code >= 400:
                sys.exit(f"{email}: {r.status_code} {r.text[:200]}")
            uid = r.json()["id"]
            # Profile row comes from the sign-up trigger; make sure the name is right.
            http.patch(f"{base}/rest/v1/profiles", params={"id": f"eq.{uid}"}, json={"full_name": name})
            # Link the corporate ID (only if it isn't already linked to someone else).
            m = http.get(f"{base}/rest/v1/memberships",
                         params={"org_id": f"eq.{org_id}", "employee_id": f"eq.{emp}", "select": "id,user_id"}).json()
            if not m:
                note = f"{emp} not found"
            elif m[0]["user_id"] not in (None, uid):
                note = f"{emp} already linked to another account; not changed"
            else:
                http.patch(f"{base}/rest/v1/memberships", params={"id": f"eq.{m[0]['id']}"}, json={"user_id": uid})
                note = f"linked to {emp}"
            print(f"  {email:24s} {action:15s} {note}")
    print(f"\nDone. Work mode on each phone: company {COMPANY}, the ID shown above, PIN 1234.")


if __name__ == "__main__":
    main()

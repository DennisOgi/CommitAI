from fastapi.testclient import TestClient

from commitai.api import app, db
from commitai.seed import CHIDI, KEMI, TUNDE


def H(uid):
    return {"Authorization": f"Bearer dev:{uid}"}


def test_register_company_add_staff_join_and_manage():
    with TestClient(app) as c:
        # Chidi registers a company and becomes its admin, already in Work mode.
        r = c.post("/v1/orgs", headers=H(CHIDI), json={"name": "Okafor Logistics", "pin": "2468"})
        assert r.status_code == 200, r.text
        org = r.json()["organization"]
        assert org["corp_code"].startswith("OKAFOR")
        assert r.json()["membership"]["role"] == "admin"
        assert c.get("/v1/me", headers=H(CHIDI)).json()["mode"] == "corporate"

        # Admin adds a manager and an employee reporting to them.
        mgr = c.post("/v1/org/members", headers=H(CHIDI), json={"full_name": "Kemi Lawal", "role": "manager",
                                                                "title": "Ops lead", "department": "Ops"}).json()
        assert mgr["temp_pin"].isdigit() and len(mgr["temp_pin"]) == 6 and mgr["corp_code"] == org["corp_code"]
        emp = c.post("/v1/org/members", headers=H(CHIDI), json={
            "full_name": "Tunde Bakare", "email": "Tunde@Example.com", "manager_id": mgr["member"]["id"]}).json()
        assert emp["member"]["manager_name"] == "Kemi Lawal" and emp["member"]["email"] == "tunde@example.com"
        assert c.post("/v1/org/members", headers=H(CHIDI), json={"full_name": "Dup", "email": "tunde@example.com"}).status_code == 409

        # Bulk add: one good row, one bad.
        bulk = c.post("/v1/org/members/bulk", headers=H(CHIDI), json={"members": [
            {"full_name": "Ada", "role": "employee"}, {"full_name": "Bad", "manager_id": "nope"}]}).json()
        assert [x["ok"] for x in bulk["results"]] == [True, False]

        # Kemi signs in with the one-time PIN and is told to change it.
        login = c.post("/v1/corporate/login", headers=H(KEMI), json={
            "corp_code": org["corp_code"], "employee_id": mgr["member"]["employee_id"], "pin": mgr["temp_pin"]}).json()
        assert login["must_change_pin"] is True
        assert c.post("/v1/corporate/pin", headers=H(KEMI), json={"current_pin": "000000", "new_pin": "1357"}).status_code == 401
        assert c.post("/v1/corporate/pin", headers=H(KEMI), json={"current_pin": mgr["temp_pin"], "new_pin": "1357"}).status_code == 200

        # Tunde has an email invite: join with his own PIN, no codes.
        prof = next(p for p in db.tables["profiles"] if p["id"] == TUNDE)
        prof["email"] = "tunde@example.com"
        inv = c.get("/v1/me/invites", headers=H(TUNDE)).json()
        assert inv and inv[0]["organization"] == "Okafor Logistics"
        j = c.post("/v1/org/join", headers=H(TUNDE), json={"membership_id": inv[0]["membership_id"], "pin": "9753"})
        assert j.status_code == 200 and j.json()["membership"]["user_id"] == TUNDE
        assert c.get("/v1/me/invites", headers=H(TUNDE)).json() == []

        # Kemi (manager) sees her line only; admin sees everyone; employees can't manage.
        names = {m["full_name"] for m in c.get("/v1/org/members", headers=H(KEMI)).json()}
        assert names == {"Kemi Lawal", "Tunde Bakare"}
        assert len(c.get("/v1/org/members", headers=H(CHIDI)).json()) == 4
        assert c.post("/v1/org/members", headers=H(TUNDE), json={"full_name": "X"}).status_code == 403

        # Promote, no reporting loops, can't remove the last admin, deactivate drops Work mode.
        admin_id = r.json()["membership"]["id"]
        assert c.patch(f"/v1/org/members/{mgr['member']['id']}", headers=H(CHIDI),
                       json={"manager_id": emp["member"]["id"]}).status_code == 422
        assert c.patch(f"/v1/org/members/{admin_id}", headers=H(CHIDI), json={"role": "employee"}).status_code == 422
        assert c.patch(f"/v1/org/members/{mgr['member']['id']}", headers=H(CHIDI), json={"role": "admin"}).json()["role"] == "admin"
        assert c.patch(f"/v1/org/members/{emp['member']['id']}", headers=H(CHIDI), json={"active": False}).json()["active"] is False
        assert c.get("/v1/me", headers=H(TUNDE)).json()["mode"] == "personal"

        # PIN reset gives a new one-time PIN.
        rp = c.post(f"/v1/org/members/{mgr['member']['id']}/reset-pin", headers=H(CHIDI), json={}).json()
        assert rp["member"]["must_change_pin"] is True and len(rp["temp_pin"]) == 6

        # Company settings.
        assert c.patch("/v1/org", headers=H(CHIDI), json={"off_duty_policy": "ring"}).json()["off_duty_policy"] == "ring"
        assert c.get("/v1/org", headers=H(CHIDI)).json()["counts"]["admins"] == 2

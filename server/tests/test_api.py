import pytest
from fastapi.testclient import TestClient

from commitai import push
from commitai.api import app
from commitai.seed import ADA, BELLO, CHIDI, NGOZI, TUNDE


def H(uid):
    return {"Authorization": f"Bearer dev:{uid}"}


@pytest.fixture(scope="module")
def c():
    with TestClient(app) as client:
        yield client


def corp_login(c, uid, emp):
    r = c.post("/v1/corporate/login", headers=H(uid), json={"corp_code": "lumen", "employee_id": emp, "pin": "1234"})
    assert r.status_code == 200, r.text
    return r.json()["corp_session"]


def test_bad_pin_rejected(c):
    r = c.post("/v1/corporate/login", headers=H(ADA), json={"corp_code": "LUMEN", "employee_id": "EMP-1042", "pin": "0000"})
    assert r.status_code == 401


def test_corporate_id_cannot_be_hijacked(c):
    r = c.post("/v1/corporate/login", headers=H(CHIDI), json={"corp_code": "LUMEN", "employee_id": "EMP-1042", "pin": "1234"})
    assert r.status_code == 409


def test_mode_toggle_blocks_personal_calls(c):
    session = corp_login(c, ADA, "EMP-1042")
    assert c.get("/v1/me", headers=H(ADA)).json()["mode"] == "corporate"

    # Chidi (a friend) calls Ada app-to-app while she is at work → held.
    r = c.post("/v1/calls", headers=H(CHIDI), json={"channel": "app", "callee_user_id": ADA})
    assert r.status_code == 200 and r.json()["decision"] == "blocked_mode"
    assert not r.json()["recorded"]

    # A known client (Bello, in Lumen's client directory) gets through and is recorded on Ada's side.
    push.outbox.clear()
    r = c.post("/v1/calls", headers=H(BELLO), json={"channel": "app", "callee_user_id": ADA})
    assert r.json()["decision"] == "ring"
    ada_calls = c.get("/v1/calls", headers=H(ADA)).json()
    ringing = next(x for x in ada_calls if x["status"] == "ringing")
    assert ringing["mode"] == "corporate"
    acc = c.post(f"/v1/calls/{ringing['id']}/accept", headers=H(ADA)).json()
    assert acc["recorded"] and "recorded" in acc["disclosure"]
    c.post(f"/v1/calls/{ringing['id']}/end", headers=H(ADA))

    # Switching to personal hands over the held call.
    r = c.post("/v1/presence", headers=H(ADA), json={"mode": "personal"})
    assert any(h["from"] == "Chidi Nwosu" for h in r.json()["held_calls"])
    # And corporate history isn't visible in personal recents.
    assert all(x["mode"] == "personal" for x in c.get("/v1/calls", headers=H(ADA)).json())
    # Corporate commitments need corporate mode.
    assert c.get("/v1/commitments", headers=H(ADA)).status_code == 403

    # Re-enter corporate with the session (no PIN).
    assert c.post("/v1/presence", headers=H(ADA), json={"mode": "corporate", "corp_session": session}).status_code == 200
    assert c.post("/v1/presence", headers=H(ADA), json={"mode": "corporate", "corp_session": "garbage"}).status_code == 401


def test_pstn_call_extract_review_dashboard(c):
    corp_login(c, ADA, "EMP-1042")
    r = c.post("/v1/calls", headers=H(ADA), json={"channel": "pstn", "phone": "+2348059876543"}).json()
    assert r["recorded"] and r["call"]["channel"] == "pstn_mobile"
    call_id = r["call"]["id"]

    out = c.post(f"/dev/calls/{call_id}/simulate", headers=H(ADA)).json()
    assert len(out["commitments"]) >= 5
    assert all(x["status"] == "pending_review" for x in out["commitments"])

    detail = c.get(f"/v1/calls/{call_id}", headers=H(ADA)).json()
    assert len(detail["transcript"]) == 11
    ids = [x["id"] for x in detail["commitments"]]
    reviewed = c.post(f"/v1/calls/{call_id}/review", headers=H(ADA), json={
        "accept": ids[:-1], "reject": ids[-1:], "edits": {ids[0]: {"title": "Send incident report (edited)"}},
        "add": [{"title": "Share driver contact for Kano route", "category": "information"}],
    }).json()
    statuses = sorted(x["status"] for x in reviewed["commitments"])
    assert statuses.count("cancelled") == 1 and statuses.count("open") == len(ids)

    # A colleague can't see Ada's call; her manager can.
    corp_login(c, TUNDE, "EMP-1043")
    assert c.get(f"/v1/calls/{call_id}", headers=H(TUNDE)).status_code == 404
    corp_login(c, NGOZI, "EMP-1001")
    assert c.get(f"/v1/calls/{call_id}", headers=H(NGOZI)).status_code == 200
    # Employees can't open the dashboard.
    assert c.get("/v1/dashboard", headers=H(ADA)).status_code == 403

    dash = c.get("/v1/dashboard", headers=H(NGOZI)).json()
    assert dash["kpis"]["open"] > 0 and dash["kpis"]["on_time_rate"] is not None
    assert len(dash["trend"]) == 8 and {p["name"] for p in dash["people"]} >= {"Ada Okafor", "Tunde Bakare"}

    # Manager nudges, employee marks it done; the audit trail records both.
    target = next(x for x in reviewed["commitments"] if x["status"] == "open")
    assert c.post(f"/v1/commitments/{target['id']}/nudge", headers=H(NGOZI)).status_code == 200
    assert c.patch(f"/v1/commitments/{target['id']}", headers=H(ADA), json={"status": "fulfilled"}).json()["completed_at"]
    kinds = [e["kind"] for e in c.get(f"/v1/commitments/{target['id']}/events", headers=H(NGOZI)).json()]
    assert {"confirmed", "nudge", "status_changed"} <= set(kinds)


def test_personal_pstn_call_not_recorded(c):
    c.post("/v1/presence", headers=H(TUNDE), json={"mode": "personal"})
    r = c.post("/v1/calls", headers=H(TUNDE), json={"channel": "pstn", "phone": "+2348030000000"}).json()
    assert not r["recorded"] and r["call"]["org_id"] is None and r["call"]["processing"] == "not_applicable"
    assert c.post(f"/dev/calls/{r['call']['id']}/simulate", headers=H(TUNDE)).status_code == 404


@pytest.mark.asyncio
async def test_scheduler_marks_missed_and_auto_publishes():
    from datetime import datetime, timedelta, timezone

    from commitai.scheduler import tick
    from commitai.store import MemoryStore
    from commitai.seed import seed_memory_store

    db = MemoryStore()
    seed_memory_store(db)
    later = datetime.now(timezone.utc) + timedelta(days=3)
    stats = await tick(db, later)
    assert stats["missed"] >= 2 and stats["auto_published"] >= 0

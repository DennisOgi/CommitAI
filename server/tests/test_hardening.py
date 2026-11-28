"""Production-hardening behaviour: brute-force limits, access checks, ringing, webhooks, config."""

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from commitai import api
from commitai.api import app
from commitai.seed import ADA, BELLO, CHIDI, KEMI, NGOZI


def H(uid):
    return {"Authorization": f"Bearer dev:{uid}"}


@pytest.fixture(scope="module")
def c():
    with TestClient(app) as client:
        yield client


def test_corporate_login_is_rate_limited(c):
    api.login_limiter.reset(f"user:{NGOZI}", "ip:testclient")
    body = {"corp_code": "LUMEN", "employee_id": "EMP-1001", "pin": "9999"}
    codes = [c.post("/v1/corporate/login", headers=H(NGOZI), json=body).status_code for _ in range(6)]
    assert codes[:5] == [401] * 5 and codes[5] == 429
    # Even the right PIN is refused while locked out.
    ok = {**body, "pin": "1234"}
    assert c.post("/v1/corporate/login", headers=H(NGOZI), json=ok).status_code == 429
    api.login_limiter.reset(f"user:{NGOZI}", "ip:testclient")
    assert c.post("/v1/corporate/login", headers=H(NGOZI), json=ok).status_code == 200


def test_cannot_dial_someone_elses_contact(c):
    c.post("/v1/presence", headers=H(CHIDI), json={"mode": "personal"})
    org_contact = next(x for x in api.db.tables["contacts"] if x.get("org_id"))
    r = c.post("/v1/calls", headers=H(CHIDI), json={"channel": "pstn", "contact_id": org_contact["id"]})
    assert r.status_code == 404


def test_invalid_phone_rejected(c):
    r = c.post("/v1/calls", headers=H(CHIDI), json={"channel": "pstn", "phone": "0803-not-a-number"})
    assert r.status_code == 422


def test_incoming_poll_and_decline(c):
    c.post("/v1/presence", headers=H(BELLO), json={"mode": "personal"})
    c.post("/v1/presence", headers=H(CHIDI), json={"mode": "personal"})
    r = c.post("/v1/calls", headers=H(BELLO), json={"channel": "app", "callee_user_id": CHIDI}).json()
    assert r["decision"] == "ring"
    ringing = c.get("/v1/calls/incoming", headers=H(CHIDI)).json()
    assert len(ringing) >= 1 and ringing[0]["caller_name"] == "Ibrahim Bello"
    c.post(f"/v1/calls/{ringing[0]['call_id']}/decline", headers=H(CHIDI))
    # The caller sees the decline (the app polls its own call while ringing).
    assert c.get(f"/v1/calls/{r['call']['id']}", headers=H(BELLO)).json()["call"]["status"] == "rejected"
    assert c.get("/v1/calls/incoming", headers=H(CHIDI)).json() == []


@pytest.mark.asyncio
async def test_unanswered_calls_expire():
    from commitai.scheduler import expire_unanswered
    from commitai.store import MemoryStore

    db = MemoryStore()
    old = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
    await db.insert("calls", {"user_id": "u", "status": "ringing", "started_at": old, "mode": "personal"})
    await db.insert("calls", {"user_id": "u", "status": "ringing", "mode": "personal",
                              "started_at": datetime.now(timezone.utc).isoformat()})
    assert await expire_unanswered(db, datetime.now(timezone.utc)) == 1
    assert sorted(x["status"] for x in await db.select("calls")) == ["missed", "ringing"]


@pytest.mark.asyncio
async def test_retention_purges_old_transcripts():
    from commitai.scheduler import apply_retention
    from commitai.store import MemoryStore

    db = MemoryStore()
    org = (await db.insert("organizations", {"name": "X", "retention_days": 30}))[0]
    old = (datetime.now(timezone.utc) - timedelta(days=40)).isoformat()
    call = (await db.insert("calls", {"org_id": org["id"], "mode": "corporate", "started_at": old,
                                      "recording_id": "rec"}))[0]
    await db.insert("transcript_segments", {"call_id": call["id"], "speaker": "client", "text": "hi", "offset_ms": 0})
    assert await apply_retention(db, datetime.now(timezone.utc)) == 1
    assert await db.select("transcript_segments") == []
    assert (await db.get("calls", id=call["id"]))["recording_id"] is None
    assert await apply_retention(db, datetime.now(timezone.utc)) == 0


def test_dialin_test_ping_and_unknown_number(c):
    assert c.post("/webhooks/daily/dialin", json={"Test": "test"}).status_code == 200
    r = c.post("/webhooks/daily/dialin", json={"To": "+10000000000", "From": "+2348000000000"})
    assert r.status_code == 404


def test_internal_endpoints_need_key(c):
    assert c.post("/internal/calls/x/events", json={"kind": "ended"}).status_code == 403


def test_extraction_is_idempotent(c):
    from commitai.seed import ADA as _ADA  # noqa: F401

    c.post("/v1/corporate/login", headers=H(ADA), json={"corp_code": "LUMEN", "employee_id": "EMP-1042", "pin": "1234"})
    call_id = c.post("/v1/calls", headers=H(ADA), json={"channel": "pstn", "phone": "+2348059876543"}).json()["call"]["id"]
    first = c.post(f"/dev/calls/{call_id}/simulate", headers=H(ADA)).json()["commitments"]
    second = c.post(f"/dev/calls/{call_id}/simulate", headers=H(ADA)).json()["commitments"]
    detail = c.get(f"/v1/calls/{call_id}", headers=H(ADA)).json()
    assert len(detail["commitments"]) == len(second) == len(first)


def test_bad_due_date_rejected(c):
    c.post("/v1/corporate/login", headers=H(ADA), json={"corp_code": "LUMEN", "employee_id": "EMP-1042", "pin": "1234"})
    cid = c.get("/v1/commitments", headers=H(ADA)).json()[0]["id"]
    assert c.patch(f"/v1/commitments/{cid}", headers=H(ADA), json={"due_at": "next tuesday"}).status_code == 422
    assert c.patch(f"/v1/commitments/{cid}", headers=H(ADA), json={"due_at": "2026-12-01T10:00:00"}).status_code == 422


def test_production_settings_are_enforced():
    from commitai.config import Settings

    bad = Settings(app_env="production", dev_auth=True, internal_api_key="short", public_url="http://x",
                   cors_origins=["*"])
    problems = " ".join(bad.problems())
    for needle in ("DEV_AUTH", "INTERNAL_API_KEY", "SUPABASE", "https", "CORS"):
        assert needle in problems
    good = Settings(app_env="production", dev_auth=False, internal_api_key="k" * 40,
                    public_url="https://api.example.com", cors_origins=[],
                    supabase_url="https://x.supabase.co", supabase_service_key="svc")
    assert good.problems() == []
    assert Settings(app_env="development").problems() == []


def test_add_contact_by_email_links_app_account(c):
    c.post("/v1/presence", headers=H(BELLO), json={"mode": "personal"})
    r = c.post("/v1/contacts", headers=H(BELLO), json={"name": "Chidi", "email": "Chidi@Example.com"})
    assert r.status_code == 200 and r.json()["app_user_id"] == CHIDI
    r = c.post("/v1/contacts", headers=H(BELLO), json={"name": "Nobody", "email": "nobody@example.com"})
    assert r.status_code == 422 and "No Commit Call account" in r.json()["detail"]
    r = c.post("/v1/contacts", headers=H(BELLO), json={"name": "Phone only", "phone_e164": "+2348031234567"})
    assert r.status_code == 200 and r.json()["app_user_id"] is None


@pytest.mark.asyncio
async def test_stale_processing_is_marked_failed():
    from commitai.scheduler import fail_stale_processing
    from commitai.store import MemoryStore

    db = MemoryStore()
    now = datetime.now(timezone.utc)
    old = (await db.insert("calls", {"processing": "pending", "ended_at": (now - timedelta(minutes=30)).isoformat()}))[0]
    fresh = (await db.insert("calls", {"processing": "pending", "ended_at": (now - timedelta(minutes=2)).isoformat()}))[0]
    assert await fail_stale_processing(db, now) == 1
    assert (await db.get("calls", id=old["id"]))["processing"] == "failed"
    assert (await db.get("calls", id=fresh["id"]))["processing"] == "pending"


@pytest.mark.asyncio
async def test_reminders_day_before_two_hours_before_and_personal(monkeypatch):
    from commitai import push, scheduler
    from commitai.store import MemoryStore

    sent = []

    async def fake_send(tokens, **kw):
        sent.append(kw["title"])

    monkeypatch.setattr(push.pusher, "send", fake_send)
    monkeypatch.setattr(scheduler.pusher, "send", fake_send)
    db = MemoryStore()
    now = datetime.now(timezone.utc)
    # A personal commitment (no org / membership) due in 20 hours.
    c = (await db.insert("commitments", {"title": "Send the quote", "status": "open", "owner": "employee",
                                         "user_id": "u1", "org_id": None, "membership_id": None,
                                         "due_at": (now + timedelta(hours=20)).isoformat()}))[0]
    await scheduler.tick(db, now)
    assert sent == ["Due soon"]
    await scheduler.tick(db, now + timedelta(hours=1))          # nothing new yet
    assert sent == ["Due soon"]
    await scheduler.tick(db, now + timedelta(hours=19))         # within 2 hours
    assert sent == ["Due soon", "Due in 2 hours"]
    await scheduler.tick(db, now + timedelta(hours=22))         # overdue: owner told too
    assert sent[-1] == "Deadline passed" and (await db.get("commitments", id=c["id"]))["status"] == "missed"


def test_import_phone_contacts(c):
    c.post("/v1/presence", headers=H(KEMI), json={"mode": "personal"})
    body = {"contacts": [
        {"name": "Mum", "phones": ["0803 123 4567"]},                          # local number -> +234
        {"name": "Mum again", "phones": ["+234 803 123 4567"]},                # duplicate number
        {"name": "Chidi", "phones": [], "emails": ["chidi@example.com"]},       # Commit Call user by email
        {"name": "Office", "phones": ["01 270 0000", "0809 999 0000"]},        # prefers the mobile
        {"name": "Junk", "phones": ["12"]},                                     # not dialable, no email
    ]}
    r = c.post("/v1/contacts/import", headers=H(KEMI), json=body).json()
    assert r["imported"] == 3 and r["skipped"] == 2 and r["on_app"] >= 1   # on_app: all contacts on Commit Call
    mine = {x["name"]: x for x in c.get("/v1/contacts", headers=H(KEMI)).json()}
    assert mine["Mum"]["phone_e164"] == "+2348031234567" and mine["Office"]["phone_e164"] == "+2348099990000"
    assert mine["Chidi"]["app_user_id"] == CHIDI and all(x["org_id"] is None for x in mine.values())
    # Importing again adds nothing.
    assert c.post("/v1/contacts/import", headers=H(KEMI), json=body).json()["imported"] == 0

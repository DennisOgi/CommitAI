"""Commit AI HTTP API.

Run:  uvicorn commitai.api:app --reload
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import logging
import secrets
import time
from collections import Counter, defaultdict, deque
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Literal

import phonenumbers
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from phonenumbers import PhoneNumberType
from pydantic import BaseModel, Field

from . import bot_runner
from .auth import CurrentUser, InternalOnly, check_pin, hash_pin, mint_corp_session, read_corp_session
from .config import settings
from .daily import daily
from .extractor import CATEGORIES, Segment, extract, merge_fragments
from .push import pusher
from .routing import Decision, InboundContext, Mode, RoutingResult, route_inbound, should_record_outbound
from .store import Store, make_store, now_iso

logging.basicConfig(level=settings.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("commitai")
# Per-request HTTP client lines (every DB query, every 3s poll) drown real errors.
logging.getLogger("httpx").setLevel(logging.WARNING)


class _QuietPolls(logging.Filter):
    """Drop access-log lines for the app's every-3-seconds incoming-call poll."""

    def filter(self, record: logging.LogRecord) -> bool:
        return "/v1/calls/incoming" not in record.getMessage()


logging.getLogger("uvicorn.access").addFilter(_QuietPolls())
db: Store = make_store()


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def parse_dt(s: str | None) -> datetime | None:
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def valid_iso(s: str | None) -> str | None:
    """Validate a client-supplied timestamp; it must carry a timezone."""
    if s is None:
        return None
    try:
        d = parse_dt(s)
    except (ValueError, AttributeError) as e:
        raise HTTPException(422, f"invalid date: {s!r}") from e
    if d is None or d.tzinfo is None:
        raise HTTPException(422, "dates must include a timezone offset")
    return d.isoformat()


@asynccontextmanager
async def lifespan(_: FastAPI):
    from .scheduler import run_scheduler

    problems = settings.problems()
    if problems:
        raise RuntimeError("Refusing to start in production:\n  - " + "\n  - ".join(problems))
    if settings.dev_auth:
        log.warning("DEV_AUTH is on: 'Bearer dev:<user_id>' tokens are accepted. Never use this in production.")
    log.info("Commit AI API starting (env=%s, store=%s, daily=%s, llm=%s, bots=%s)", settings.app_env,
             type(db).__name__, daily.enabled, settings.ai_provider or "off (rule-based)", settings.bots_enabled)
    task = asyncio.create_task(run_scheduler(db))
    yield
    task.cancel()


app = FastAPI(title="Commit AI", version="1.0.0", lifespan=lifespan,
              docs_url=None if settings.is_production else "/docs",
              redoc_url=None, openapi_url=None if settings.is_production else "/openapi.json")
if settings.cors_origins:
    app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_credentials=False,
                       allow_methods=["GET", "POST", "PATCH", "DELETE"], allow_headers=["Authorization", "Content-Type"])


@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception):
    log.exception("unhandled error on %s %s", request.method, request.url.path)
    return JSONResponse({"detail": "Something went wrong on our side. Please try again."}, status_code=500)


class RateLimiter:
    """Sliding-window limiter (per process). Use a shared store if you run several replicas."""

    def __init__(self, limit: int, window_s: int) -> None:
        self.limit, self.window = limit, window_s
        self._hits: dict[str, deque] = defaultdict(deque)

    def check(self, *keys: str) -> None:
        now = time.monotonic()
        for key in keys:
            q = self._hits[key]
            while q and q[0] < now - self.window:
                q.popleft()
            if len(q) >= self.limit:
                retry = int(self.window - (now - q[0])) + 1
                raise HTTPException(429, f"Too many attempts. Try again in {max(1, retry // 60)} min.",
                                    headers={"Retry-After": str(retry)})

    def hit(self, *keys: str) -> None:
        now = time.monotonic()
        for key in keys:
            self._hits[key].append(now)

    def reset(self, *keys: str) -> None:
        for key in keys:
            self._hits.pop(key, None)


login_limiter = RateLimiter(settings.login_max_attempts, settings.login_window_s)


def client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for")
    return (fwd.split(",")[0].strip() if fwd else None) or (request.client.host if request.client else "?")


# =============================================================== helpers ===
async def presence_of(user_id: str) -> dict:
    p = await db.get("presence", user_id=user_id)
    return p or {"user_id": user_id, "mode": "personal", "membership_id": None}


async def active_membership(user_id: str) -> dict | None:
    p = await presence_of(user_id)
    if p["mode"] != "corporate" or not p.get("membership_id"):
        return None
    return await db.get("memberships", id=p["membership_id"])


PERSONAL_DISCLOSURE = "This call is recorded so we can keep track of what we agree."


async def records_personal(user_id: str) -> bool:
    """Whether this user records their personal calls (for their own commitments). Default on."""
    prof = await db.get("profiles", id=user_id)
    return bool((prof or {}).get("record_personal_calls", True))


def is_recorded(call: dict) -> bool:
    return call.get("processing", "not_applicable") != "not_applicable"


async def require_membership(user_id: str) -> dict:
    m = await active_membership(user_id)
    if not m:
        raise HTTPException(403, "switch to corporate mode first")
    return m


async def visible_member_ids(viewer: dict) -> set[str]:
    """Membership ids whose work this viewer may see: self + reports (transitively); admins see the org."""
    members = await db.select("memberships", org_id=viewer["org_id"])
    if viewer["role"] == "admin":
        return {m["id"] for m in members}
    children = defaultdict(list)
    for m in members:
        if m.get("manager_id"):
            children[m["manager_id"]].append(m["id"])
    seen, stack = {viewer["id"]}, [viewer["id"]]
    while stack:
        for c in children[stack.pop()]:
            if c not in seen:
                seen.add(c)
                stack.append(c)
    return seen


async def device_tokens(user_id: str) -> list[str]:
    return [d["push_token"] for d in await db.select("devices", user_id=user_id) if d.get("push_token")]


async def name_of(user_id: str | None) -> str:
    if not user_id:
        return "Unknown"
    p = await db.get("profiles", id=user_id)
    return p["full_name"] if p else "Unknown"


async def org_of(membership: dict | None) -> dict | None:
    return await db.get("organizations", id=membership["org_id"]) if membership else None


async def can_view_call(user_id: str, call: dict) -> bool:
    if call["user_id"] == user_id:
        return True
    if call["mode"] != "corporate":
        return False
    m = await active_membership(user_id)
    return bool(m and m["org_id"] == call["org_id"] and call["membership_id"] in await visible_member_ids(m))


# ================================================================= me ======
@app.get("/health")
async def health():
    if settings.is_production:
        return {"ok": True}
    return {"ok": True, "env": settings.app_env, "store": type(db).__name__, "daily": daily.enabled,
            "llm": settings.ai_provider, "bots": settings.bots_enabled, "dev_auth": settings.dev_auth}


@app.get("/v1/me")
async def me(user_id: str = CurrentUser):
    profile = await db.get("profiles", id=user_id)
    if not profile:
        raise HTTPException(404, "profile not found")
    presence = await presence_of(user_id)
    membership = await active_membership(user_id)
    org = await org_of(membership)
    return {
        "profile": profile,
        "mode": presence["mode"],
        "membership": _public_member(membership) if membership else None,
        "organization": org,
    }


class SettingsBody(BaseModel):
    record_personal_calls: bool | None = None
    discoverable: bool | None = None          # "Let people find me" in search
    phone: str | None = Field(default=None, max_length=32)   # the user's own number ("" removes it)
    region: str = Field(default="NG", min_length=2, max_length=2)


@app.patch("/v1/me/settings")
async def update_settings(body: SettingsBody, user_id: str = CurrentUser):
    patch = body.model_dump(exclude_none=True, exclude={"phone", "region"})
    if body.phone is not None:
        await set_my_phone(user_id, body.phone, body.region)
    if patch:
        await db.update("profiles", patch, id=user_id)
    prof = await db.get("profiles", id=user_id) or {}
    return {"record_personal_calls": prof.get("record_personal_calls", True),
            "discoverable": prof.get("discoverable", True), "phone_e164": prof.get("phone_e164")}


async def set_my_phone(user_id: str, raw: str, region: str = "NG") -> str | None:
    """Save the user's own number. Everyone who has it in their imported contacts now sees them
    as "on Commit AI" (free app calls), the way Telegram shows contacts who joined."""
    prof = await db.get("profiles", id=user_id) or {}
    old = prof.get("phone_e164")
    phone = None
    if raw.strip():
        parsed = _e164(raw, region)
        if not parsed:
            raise HTTPException(422, "That phone number isn't valid. Include the area code, e.g. 0803 123 4567.")
        phone = parsed[0]
        other = await db.get("profiles", phone_e164=phone)
        if other and other["id"] != user_id:
            raise HTTPException(409, "That number is already used by another Commit AI account.")
    if phone == old:
        return phone
    await db.update("profiles", {"phone_e164": phone}, id=user_id)
    if old:                                     # the old number isn't theirs any more
        for c in await db.select("contacts", phone_e164=old, app_user_id=user_id):
            await db.update("contacts", {"app_user_id": None}, id=c["id"])
    if phone:
        for c in await db.select("contacts", phone_e164=phone):
            if not c.get("app_user_id") and c.get("owner_id") != user_id:
                await db.update("contacts", {"app_user_id": user_id}, id=c["id"])
    return phone


def _public_member(m: dict) -> dict:
    return {k: v for k, v in m.items() if k != "pin_hash"}


class CorporateLogin(BaseModel):
    corp_code: str = Field(min_length=1, max_length=32)
    employee_id: str = Field(min_length=1, max_length=64)
    pin: str = Field(min_length=1, max_length=12)


@app.post("/v1/corporate/login")
async def corporate_login(body: CorporateLogin, request: Request, user_id: str = CurrentUser):
    keys = (f"user:{user_id}", f"ip:{client_ip(request)}")
    login_limiter.check(*keys)
    org = await db.get("organizations", corp_code=body.corp_code.strip().upper())
    member = org and await db.get("memberships", org_id=org["id"], employee_id=body.employee_id.strip().upper())
    if not member or not member.get("active") or not check_pin(body.pin, member.get("pin_hash")):
        login_limiter.hit(*keys)
        log.warning("failed corporate login for user %s from %s", user_id, keys[1])
        raise HTTPException(401, "corporate code, employee ID or PIN is incorrect")
    login_limiter.reset(keys[0])
    if member.get("user_id") and member["user_id"] != user_id:
        raise HTTPException(409, "this corporate ID is already linked to another account — ask your admin")
    if not member.get("user_id"):
        member = (await db.update("memberships", {"user_id": user_id}, id=member["id"]))[0]
    await db.upsert("presence", {"user_id": user_id, "mode": "corporate", "membership_id": member["id"],
                                 "updated_at": now_iso()}, key="user_id")
    return {"corp_session": mint_corp_session(user_id, member["id"]),
            "membership": _public_member(member), "organization": org,
            "must_change_pin": bool(member.get("must_change_pin")),
            "held_calls": await _held_calls(user_id)}


class PresenceBody(BaseModel):
    mode: Mode
    corp_session: str | None = None


@app.post("/v1/presence")
async def set_presence(body: PresenceBody, user_id: str = CurrentUser):
    """The mode toggle. Corporate needs a valid corporate session (minted at login)."""
    if body.mode is Mode.corporate:
        if not body.corp_session:
            raise HTTPException(401, "corporate login required")
        mid = read_corp_session(body.corp_session, user_id)
        member = await db.get("memberships", id=mid)
        if not member or not member.get("active") or member.get("user_id") != user_id:
            raise HTTPException(401, "corporate access was revoked — sign in with your corporate ID again")
        await db.upsert("presence", {"user_id": user_id, "mode": "corporate", "membership_id": mid,
                                     "updated_at": now_iso()}, key="user_id")
        return {"mode": "corporate", "held_calls": []}
    await db.upsert("presence", {"user_id": user_id, "mode": "personal", "membership_id": None,
                                 "updated_at": now_iso()}, key="user_id")
    # Coming off duty: hand over the personal calls we held back.
    return {"mode": "personal", "held_calls": await _held_calls(user_id)}


async def _held_calls(user_id: str) -> list[dict]:
    rows = await db.select("calls", user_id=user_id, status="blocked_mode", order="started_at", desc=True, limit=20)
    return [{"id": r["id"], "from": r["counterpart_name"], "at": r["started_at"]} for r in rows]


# ====================================================== company onboarding ======
# Anyone can register a company (they become its admin). Admins add employees with a role,
# title, department and manager; each gets an employee ID and a one-time PIN, or joins from an
# email invite and picks their own PIN. First-time PINs must be changed after the first sign-in.

PIN_RE = r"^\d{4,8}$"
org_create_limiter = RateLimiter(5, 24 * 3600)


def _temp_pin() -> str:
    return f"{secrets.randbelow(10**6):06d}"


def _clean_email(e: str | None) -> str | None:
    e = (e or "").strip().lower()
    return e or None


async def _new_corp_code(name: str) -> str:
    letters = "".join(ch for ch in name.upper() if ch.isalnum())[:8] or "TEAM"
    if len(letters) < 3:
        letters = (letters + "TEAM")[:4]
    code = letters
    while await db.get("organizations", corp_code=code):
        code = f"{letters[:6]}{secrets.randbelow(90) + 10}"
    return code


async def _next_employee_id(org_id: str) -> str:
    taken = {m["employee_id"] for m in await db.select("memberships", org_id=org_id)}
    n = len(taken) + 1
    while f"EMP-{n:04d}" in taken:
        n += 1
    return f"EMP-{n:04d}"


async def require_admin(user_id: str) -> dict:
    m = await active_membership(user_id)
    if not m or not m.get("active"):
        raise HTTPException(403, "Switch to Work mode first.")
    if m["role"] != "admin":
        raise HTTPException(403, "Only your company's admins can do this.")
    return m


async def _member_view(m: dict, profiles: dict | None = None, by_id: dict | None = None) -> dict:
    prof = (profiles or {}).get(m.get("user_id")) if profiles is not None else (
        await db.get("profiles", id=m["user_id"]) if m.get("user_id") else None)
    mgr = (by_id or {}).get(m.get("manager_id")) if by_id is not None else (
        await db.get("memberships", id=m["manager_id"]) if m.get("manager_id") else None)
    return {
        "id": m["id"], "employee_id": m["employee_id"], "role": m["role"],
        "full_name": (prof or {}).get("full_name") or m.get("full_name") or m["employee_id"],
        "email": (prof or {}).get("email") or m.get("invite_email"),
        "title": m.get("title"), "department": m.get("department"),
        "manager_id": m.get("manager_id"),
        "manager_name": (mgr or {}).get("full_name") if mgr else None,
        "active": bool(m.get("active", True)), "joined": bool(m.get("user_id")),
        "must_change_pin": bool(m.get("must_change_pin")),
    }


class OrgCreate(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    pin: str = Field(pattern=PIN_RE)                       # the admin's own Work-mode PIN
    title: str | None = Field(default=None, max_length=80)
    timezone: str = Field(default="Africa/Lagos", max_length=64)


@app.post("/v1/orgs")
async def create_org(body: OrgCreate, user_id: str = CurrentUser):
    """Register a company. The creator becomes its first admin and is switched into Work mode."""
    org_create_limiter.check(f"org:{user_id}")
    org_create_limiter.hit(f"org:{user_id}")
    prof = await db.get("profiles", id=user_id) or {}
    org = (await db.insert("organizations", {
        "name": body.name.strip(), "corp_code": await _new_corp_code(body.name), "timezone": body.timezone,
    }))[0]
    member = (await db.insert("memberships", {
        "org_id": org["id"], "user_id": user_id, "employee_id": "EMP-0001", "pin_hash": hash_pin(body.pin),
        "role": "admin", "title": body.title or "Admin", "full_name": prof.get("full_name"),
        "invite_email": prof.get("email"), "active": True, "must_change_pin": False,
    }))[0]
    await db.upsert("presence", {"user_id": user_id, "mode": "corporate", "membership_id": member["id"],
                                 "updated_at": now_iso()}, key="user_id")
    log.info("company %s (%s) registered by %s", org["name"], org["corp_code"], user_id)
    return {"corp_session": mint_corp_session(user_id, member["id"]),
            "membership": _public_member(member), "organization": org, "held_calls": []}


class OrgPatch(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    timezone: str | None = Field(default=None, max_length=64)
    recording_disclosure: str | None = Field(default=None, min_length=10, max_length=300)
    announce_recording: bool | None = None
    off_duty_policy: Literal["ring", "voicemail"] | None = None


@app.get("/v1/org")
async def get_org(user_id: str = CurrentUser):
    m = await require_membership(user_id)
    org = await db.get("organizations", id=m["org_id"])
    members = await db.select("memberships", org_id=m["org_id"])
    return {"organization": org, "role": m["role"],
            "counts": {"members": sum(1 for x in members if x.get("active", True)),
                       "joined": sum(1 for x in members if x.get("user_id") and x.get("active", True)),
                       "admins": sum(1 for x in members if x["role"] == "admin" and x.get("active", True))}}


@app.patch("/v1/org")
async def update_org(body: OrgPatch, user_id: str = CurrentUser):
    m = await require_admin(user_id)
    patch = body.model_dump(exclude_none=True)
    if patch:
        await db.update("organizations", patch, id=m["org_id"])
    return await db.get("organizations", id=m["org_id"])


@app.get("/v1/org/members")
async def list_members(user_id: str = CurrentUser):
    """Admins see everyone; managers see their own reporting line."""
    m = await require_membership(user_id)
    rows = await db.select("memberships", org_id=m["org_id"])
    if m["role"] != "admin":
        visible = await visible_member_ids(m)
        rows = [r for r in rows if r["id"] in visible]
    uids = [r["user_id"] for r in rows if r.get("user_id")]
    profiles = {p["id"]: p for p in (await db.select("profiles", in_={"id": uids}) if uids else [])}
    by_id = {r["id"]: {**r, "full_name": (profiles.get(r.get("user_id")) or {}).get("full_name") or r.get("full_name")}
             for r in await db.select("memberships", org_id=m["org_id"])}
    out = [await _member_view(r, profiles, by_id) for r in rows]
    order = {"admin": 0, "manager": 1, "employee": 2}
    return sorted(out, key=lambda x: (not x["active"], order.get(x["role"], 3), x["full_name"].lower()))


class MemberIn(BaseModel):
    full_name: str = Field(min_length=1, max_length=120)
    email: str | None = Field(default=None, max_length=254)
    role: Literal["employee", "manager", "admin"] = "employee"
    title: str | None = Field(default=None, max_length=80)
    department: str | None = Field(default=None, max_length=80)
    manager_id: str | None = Field(default=None, max_length=64)
    employee_id: str | None = Field(default=None, max_length=64)


async def _add_member(admin: dict, body: MemberIn) -> dict:
    email = _clean_email(body.email)
    if email and "@" not in email:
        raise HTTPException(422, f"“{body.email}” isn't an email address.")
    existing = await db.select("memberships", org_id=admin["org_id"])
    if email and any((x.get("invite_email") or "").lower() == email for x in existing):
        raise HTTPException(409, f"{email} is already on your team.")
    emp = (body.employee_id or "").strip().upper() or await _next_employee_id(admin["org_id"])
    if any(x["employee_id"] == emp for x in existing):
        raise HTTPException(409, f"Employee ID {emp} is already used.")
    if body.manager_id and not any(x["id"] == body.manager_id for x in existing):
        raise HTTPException(422, "That manager isn't in your company.")
    pin = _temp_pin()
    row = (await db.insert("memberships", {
        "org_id": admin["org_id"], "employee_id": emp, "pin_hash": hash_pin(pin), "role": body.role,
        "full_name": body.full_name.strip(), "invite_email": email,
        "title": (body.title or "").strip() or None, "department": (body.department or "").strip() or None,
        "manager_id": body.manager_id, "active": True, "must_change_pin": True,
    }))[0]
    return {"member": await _member_view(row), "temp_pin": pin}


@app.post("/v1/org/members")
async def add_member(body: MemberIn, user_id: str = CurrentUser):
    admin = await require_admin(user_id)
    org = await db.get("organizations", id=admin["org_id"])
    return {**await _add_member(admin, body), "corp_code": org["corp_code"]}


class MembersBulk(BaseModel):
    members: list[MemberIn] = Field(min_length=1, max_length=500)


@app.post("/v1/org/members/bulk")
async def add_members_bulk(body: MembersBulk, user_id: str = CurrentUser):
    """Add a whole list at once (e.g. pasted from a spreadsheet). Each row succeeds or fails alone."""
    admin = await require_admin(user_id)
    org = await db.get("organizations", id=admin["org_id"])
    results = []
    for row in body.members:
        try:
            results.append({"ok": True, **await _add_member(admin, row)})
        except HTTPException as e:
            results.append({"ok": False, "full_name": row.full_name, "error": e.detail})
    return {"corp_code": org["corp_code"], "results": results}


class MemberPatch(BaseModel):
    full_name: str | None = Field(default=None, min_length=1, max_length=120)
    email: str | None = Field(default=None, max_length=254)
    role: Literal["employee", "manager", "admin"] | None = None
    title: str | None = Field(default=None, max_length=80)
    department: str | None = Field(default=None, max_length=80)
    manager_id: str | None = Field(default=None, max_length=64)   # "" clears it
    active: bool | None = None


@app.patch("/v1/org/members/{member_id}")
async def update_member(member_id: str, body: MemberPatch, user_id: str = CurrentUser):
    admin = await require_admin(user_id)
    target = await db.get("memberships", id=member_id)
    if not target or target["org_id"] != admin["org_id"]:
        raise HTTPException(404, "member not found")
    patch = body.model_dump(exclude_unset=True)
    if "email" in patch:
        patch["invite_email"] = _clean_email(patch.pop("email"))
    if "manager_id" in patch:
        mgr = patch["manager_id"] or None
        patch["manager_id"] = mgr
        if mgr:
            members = {m["id"]: m for m in await db.select("memberships", org_id=admin["org_id"])}
            if mgr not in members:
                raise HTTPException(422, "That manager isn't in your company.")
            seen, cur = set(), mgr                       # no reporting loops (A → B → A)
            while cur:
                if cur == member_id:
                    raise HTTPException(422, "That would make a reporting loop.")
                if cur in seen:
                    break
                seen.add(cur)
                cur = members.get(cur, {}).get("manager_id")
    losing_admin = target["role"] == "admin" and (
        patch.get("role") not in (None, "admin") or patch.get("active") is False)
    if losing_admin:
        admins = [m for m in await db.select("memberships", org_id=admin["org_id"], role="admin") if m.get("active", True)]
        if len(admins) <= 1:
            raise HTTPException(422, "A company needs at least one admin. Make someone else an admin first.")
    for k in ("title", "department"):
        if k in patch and patch[k] is not None:
            patch[k] = patch[k].strip() or None
    if patch:
        target = (await db.update("memberships", patch, id=member_id))[0]
    if patch.get("active") is False and target.get("user_id"):
        # Deactivated: drop them out of Work mode right away.
        p = await db.get("presence", user_id=target["user_id"])
        if p and p.get("membership_id") == member_id:
            await db.upsert("presence", {"user_id": target["user_id"], "mode": "personal", "membership_id": None,
                                         "updated_at": now_iso()}, key="user_id")
    return await _member_view(target)


class ResetPin(BaseModel):
    unlink_account: bool = False      # they're moving to a new account / phone


@app.post("/v1/org/members/{member_id}/reset-pin")
async def reset_member_pin(member_id: str, body: ResetPin, user_id: str = CurrentUser):
    admin = await require_admin(user_id)
    target = await db.get("memberships", id=member_id)
    if not target or target["org_id"] != admin["org_id"]:
        raise HTTPException(404, "member not found")
    pin = _temp_pin()
    patch = {"pin_hash": hash_pin(pin), "must_change_pin": True}
    if body.unlink_account:
        patch["user_id"] = None
    row = (await db.update("memberships", patch, id=member_id))[0]
    org = await db.get("organizations", id=admin["org_id"])
    return {"member": await _member_view(row), "temp_pin": pin, "corp_code": org["corp_code"]}


@app.get("/v1/me/invites")
async def my_invites(user_id: str = CurrentUser):
    """Companies that added this user's email and are waiting for them to join."""
    prof = await db.get("profiles", id=user_id) or {}
    email = _clean_email(prof.get("email"))
    if not email:
        return []
    out = []
    for m in await db.select("memberships", invite_email=email):
        if m.get("user_id") or not m.get("active", True):
            continue
        org = await db.get("organizations", id=m["org_id"])
        if org:
            out.append({"membership_id": m["id"], "organization": org["name"], "corp_code": org["corp_code"],
                        "employee_id": m["employee_id"], "role": m["role"], "title": m.get("title")})
    return out


class JoinBody(BaseModel):
    membership_id: str = Field(max_length=64)
    pin: str = Field(pattern=PIN_RE)


@app.post("/v1/org/join")
async def join_org(body: JoinBody, user_id: str = CurrentUser):
    """Accept an email invite: link the account and set your own PIN (no codes to type)."""
    prof = await db.get("profiles", id=user_id) or {}
    m = await db.get("memberships", id=body.membership_id)
    if (not m or m.get("user_id") or not m.get("active", True)
            or (m.get("invite_email") or "").lower() != (_clean_email(prof.get("email")) or "-")):
        raise HTTPException(404, "That invite isn't available any more. Ask your admin.")
    m = (await db.update("memberships", {"user_id": user_id, "pin_hash": hash_pin(body.pin),
                                         "must_change_pin": False}, id=m["id"]))[0]
    await db.upsert("presence", {"user_id": user_id, "mode": "corporate", "membership_id": m["id"],
                                 "updated_at": now_iso()}, key="user_id")
    org = await db.get("organizations", id=m["org_id"])
    return {"corp_session": mint_corp_session(user_id, m["id"]), "membership": _public_member(m),
            "organization": org, "held_calls": await _held_calls(user_id)}


class PinChange(BaseModel):
    current_pin: str = Field(min_length=1, max_length=12)
    new_pin: str = Field(pattern=PIN_RE)


@app.post("/v1/corporate/pin")
async def change_pin(body: PinChange, request: Request, user_id: str = CurrentUser):
    m = await require_membership(user_id)
    keys = (f"user:{user_id}", f"ip:{client_ip(request)}")
    login_limiter.check(*keys)
    if not check_pin(body.current_pin, m.get("pin_hash")):
        login_limiter.hit(*keys)
        raise HTTPException(401, "Your current PIN is incorrect.")
    if body.new_pin == body.current_pin:
        raise HTTPException(422, "Choose a PIN different from the current one.")
    await db.update("memberships", {"pin_hash": hash_pin(body.new_pin), "must_change_pin": False}, id=m["id"])
    return {"ok": True}


class DeviceBody(BaseModel):
    platform: Literal["android", "ios"]
    push_token: str | None = Field(default=None, max_length=4096)
    voip_token: str | None = Field(default=None, max_length=4096)


@app.post("/v1/devices")
async def register_device(body: DeviceBody, user_id: str = CurrentUser):
    existing = await db.get("devices", user_id=user_id, platform=body.platform)
    row = {"user_id": user_id, **body.model_dump(), "updated_at": now_iso()}
    if existing:
        await db.update("devices", row, id=existing["id"])
    else:
        await db.insert("devices", row)
    return {"ok": True}


# =========================================================== contacts ======
@app.get("/v1/contacts")
async def list_contacts(user_id: str = CurrentUser):
    m = await active_membership(user_id)
    if m:
        rows = await db.select("contacts", org_id=m["org_id"], order="name")
    else:
        rows = await db.select("contacts", org_id=None, owner_id=user_id, order="name")
    return rows


E164 = r"^\+[1-9]\d{6,14}$"


class ContactBody(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    company: str | None = Field(default=None, max_length=120)
    phone_e164: str | None = Field(default=None, pattern=E164)
    # Email of a Commit AI user: links the contact to their account so they can be app-called.
    email: str | None = Field(default=None, max_length=254, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    # Or the account id of someone found with /v1/users/search.
    app_user_id: str | None = Field(default=None, max_length=64)
    is_client: bool = True


@app.post("/v1/contacts")
async def add_contact(body: ContactBody, user_id: str = CurrentUser):
    m = await active_membership(user_id)
    app_user = None
    if body.app_user_id:
        app_user = await db.get("profiles", id=body.app_user_id)
        if not app_user:
            raise HTTPException(404, "That person no longer has a Commit AI account.")
    elif body.email:
        app_user = await db.get("profiles", email=body.email.strip().lower())
    if app_user and app_user["id"] == user_id:
        raise HTTPException(422, "That's you.")
    if not body.phone_e164 and not app_user:
        raise HTTPException(422, "No Commit AI account uses that email. Add a phone number instead, "
                                 "or ask them to sign up first." if body.email else "Add a phone number or an email.")
    row = {**body.model_dump(exclude={"email", "app_user_id"}), "owner_id": user_id, "org_id": m["org_id"] if m else None,
           "app_user_id": app_user["id"] if app_user else None}
    return (await db.insert("contacts", row))[0]


def _mask_email(email: str | None) -> str | None:
    if not email or "@" not in email:
        return None
    local, domain = email.split("@", 1)
    return local[:2] + "•" * max(1, len(local) - 2) + "@" + domain


@app.get("/v1/users/search")
async def search_users(q: str = "", user_id: str = CurrentUser):
    """Find people on Commit AI to call: by name (2+ characters) or by exact email.
    Anyone with an account can be found unless they turned "Let people find me" off;
    an exact email always matches. Emails are masked so the list can't be harvested."""
    q = " ".join(q.split())[:80]
    if len(q) < 2:
        return []
    found: dict[str, dict] = {}
    digits = "".join(ch for ch in q if ch.isdigit())
    if len(digits) >= 7 and not any(ch.isalpha() for ch in q):
        parsed = _e164(q, "NG")                   # a phone number: exact match only
        for p in (await db.select("profiles", phone_e164=parsed[0], limit=1) if parsed else []):
            found[p["id"]] = p
    elif "@" in q:
        for p in await db.select("profiles", email=q.lower(), limit=1):
            found[p["id"]] = p
    else:
        for p in await db.select("profiles", contains={"full_name": q}, order="full_name", limit=40):
            if p.get("discoverable", True) is not False:
                found[p["id"]] = p
    found.pop(user_id, None)
    saved = {c["app_user_id"]: c["id"] for c in await db.select("contacts", owner_id=user_id)
             if c.get("app_user_id")}
    return [{"user_id": p["id"], "full_name": p.get("full_name") or "Commit AI user",
             "email_hint": _mask_email(p.get("email")), "contact_id": saved.get(p["id"])}
            for p in list(found.values())[:20]]


class PhoneContact(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    phones: list[str] = Field(default_factory=list, max_length=10)
    emails: list[str] = Field(default_factory=list, max_length=10)


class ContactImport(BaseModel):
    contacts: list[PhoneContact] = Field(max_length=5000)
    default_region: str = Field(default="NG", min_length=2, max_length=2)   # for local numbers like 0803…


def _e164(raw: str, region: str) -> tuple[str, bool] | None:
    """(E.164, is_mobile) for a dialable number, else None."""
    try:
        n = phonenumbers.parse(raw, region.upper())
    except phonenumbers.NumberParseException:
        return None
    if not phonenumbers.is_possible_number(n):
        return None
    kind = phonenumbers.number_type(n)
    return (phonenumbers.format_number(n, phonenumbers.PhoneNumberFormat.E164),
            kind in (PhoneNumberType.MOBILE, PhoneNumberType.FIXED_LINE_OR_MOBILE))


_import_locks: dict[str, asyncio.Lock] = defaultdict(asyncio.Lock)


async def _profiles_by(column: str, values: list[str], exclude: str | None = None) -> dict[str, str]:
    """value → profile id, for profiles whose `column` is one of `values` (looked up in batches)."""
    found: dict[str, str] = {}
    vals = sorted(set(values))
    for i in range(0, len(vals), 80):            # small batches: the lookup goes in the URL
        for prof in await db.select("profiles", in_={column: vals[i:i + 80]}):
            if prof["id"] != exclude and prof.get(column):
                found[prof[column]] = prof["id"]
    return found


@app.post("/v1/contacts/import")
async def import_contacts(body: ContactImport, user_id: str = CurrentUser):
    """The user's phone address book, imported into their PERSONAL contacts (never the company's).
    Safe to repeat (the app re-syncs quietly): numbers are normalised to E.164 and anything already
    imported is skipped. Contacts who use Commit AI, matched by phone number or email, are linked so
    they can be app-called; that includes earlier imports of people who have joined since."""
    async with _import_locks[user_id]:           # one import at a time per user: no double inserts
        existing = await db.select("contacts", owner_id=user_id, org_id=None)
        have_phones = {c["phone_e164"] for c in existing if c.get("phone_e164")}
        have_users = {c["app_user_id"] for c in existing if c.get("app_user_id")}

        parsed = []
        for pc in body.contacts:
            numbers = [x for x in (_e164(p, body.default_region) for p in pc.phones) if x]
            numbers.sort(key=lambda x: not x[1])        # prefer a mobile number
            parsed.append((pc, [n for n, _ in numbers]))
        by_phone = await _profiles_by("phone_e164", [n for _, ns in parsed for n in ns]
                                      + [c["phone_e164"] for c in existing if c.get("phone_e164") and not c.get("app_user_id")],
                                      exclude=user_id)
        by_email = await _profiles_by("email", [e.strip().lower() for pc in body.contacts for e in pc.emails if "@" in e],
                                      exclude=user_id)

        rows, skipped = [], 0
        for pc, numbers in parsed:
            phone = numbers[0] if numbers else None
            app_user = (next((by_phone[n] for n in numbers if n in by_phone), None)
                        or next((by_email[e.strip().lower()] for e in pc.emails if e.strip().lower() in by_email), None))
            if (phone and phone in have_phones) or (not phone and not app_user) or (app_user and app_user in have_users):
                skipped += 1
                continue
            rows.append({"name": pc.name.strip()[:120], "company": None, "phone_e164": phone, "is_client": False,
                         "owner_id": user_id, "org_id": None, "app_user_id": app_user, "source": "phone"})
            if phone:
                have_phones.add(phone)
            if app_user:
                have_users.add(app_user)
        for i in range(0, len(rows), 500):
            await db.insert("contacts", rows[i:i + 500])

        # Contacts imported earlier whose owner has joined Commit AI since.
        linked = 0
        for c in existing:
            uid = by_phone.get(c.get("phone_e164") or "")
            if uid and not c.get("app_user_id") and uid not in have_users:
                await db.update("contacts", {"app_user_id": uid}, id=c["id"])
                have_users.add(uid)
                linked += 1
        return {"imported": len(rows), "skipped": skipped, "linked": linked,
                "on_app": len(have_users)}


# ============================================================== calls ======
def channel_for(phone: str) -> str:
    """GSM (mobile) or landline, for any country, from libphonenumber's numbering plans."""
    try:
        n = phonenumbers.parse(phone.replace(" ", ""), None)
    except phonenumbers.NumberParseException:
        return "pstn_mobile"
    kind = phonenumbers.number_type(n)
    if kind in (PhoneNumberType.FIXED_LINE, PhoneNumberType.TOLL_FREE, PhoneNumberType.SHARED_COST,
                PhoneNumberType.UAN, PhoneNumberType.PREMIUM_RATE):
        return "pstn_landline"
    return "pstn_mobile"   # MOBILE, FIXED_LINE_OR_MOBILE (e.g. US/CA), VOIP, unknown


def dialable(phone: str) -> str:
    """Normalise to E.164 and reject numbers that cannot exist."""
    try:
        n = phonenumbers.parse(phone.replace(" ", ""), None)
    except phonenumbers.NumberParseException as e:
        raise HTTPException(422, "That phone number isn't valid. Use the international format, e.g. +2348012345678.") from e
    if not phonenumbers.is_possible_number(n):
        raise HTTPException(422, "That phone number has the wrong number of digits for its country.")
    return phonenumbers.format_number(n, phonenumbers.PhoneNumberFormat.E164)


class OutboundCall(BaseModel):
    channel: Literal["app", "pstn"]
    callee_user_id: str | None = Field(default=None, max_length=64)
    phone: str | None = Field(default=None, pattern=E164)
    contact_id: str | None = Field(default=None, max_length=64)
    display_name: str | None = Field(default=None, max_length=120)


async def contact_visible(user_id: str, contact_id: str) -> dict:
    """A contact the caller may dial: their own personal contact, or their active org's directory."""
    contact = await db.get("contacts", id=contact_id)
    if contact:
        if contact.get("org_id") is None and contact.get("owner_id") == user_id:
            return contact
        m = await active_membership(user_id)
        if m and contact.get("org_id") == m["org_id"]:
            return contact
    raise HTTPException(404, "contact not found")


@app.post("/v1/calls")
async def start_call(body: OutboundCall, user_id: str = CurrentUser):
    presence = await presence_of(user_id)
    caller_mode = Mode(presence["mode"])
    member = await active_membership(user_id)
    org = await org_of(member)
    corp_record = should_record_outbound(caller_mode)
    # Personal calls are recorded too (unless the user switched it off); their commitments
    # stay private to the user and never reach the company.
    personal_record = not corp_record and await records_personal(user_id)
    record = corp_record or personal_record
    contact = await contact_visible(user_id, body.contact_id) if body.contact_id else None
    caller_name = await name_of(user_id)

    if body.channel == "pstn":
        phone = body.phone or (contact or {}).get("phone_e164")
        if not phone:
            raise HTTPException(422, "phone number required")
        phone = dialable(phone)
        # GSM / landline calls are dialled out of the Daily room by the call bot. Without it the
        # call could never connect, so say so instead of ringing forever.
        if daily.enabled and not settings.bots_enabled:
            raise HTTPException(503, "Calls to mobile and landline numbers are switched off on this server (BOTS_ENABLED=false).")
        if settings.is_production and not daily.enabled:
            raise HTTPException(503, "Calls to mobile and landline numbers aren't configured yet.")
        channel, counterpart = channel_for(phone), body.display_name or (contact or {}).get("name") or phone
    else:
        callee = body.callee_user_id or (contact or {}).get("app_user_id")
        if not callee:
            raise HTTPException(422, "This person isn't linked to a Commit AI account, so an app call isn't possible. Call their phone number instead.")
        if callee == user_id:
            raise HTTPException(422, "you can't call yourself")
        if not await db.get("profiles", id=callee):
            raise HTTPException(404, "That person no longer has a Commit AI account.")
        phone, channel, counterpart = None, "app", await name_of(callee)

    # App calls: the callee may record even if the caller doesn't, so allow recording in the room
    # (the bot only starts a recording when someone on the call records).
    room = await daily.create_room(dialout=body.channel == "pstn", record=record or body.channel == "app")
    base = {
        "mode": caller_mode.value, "org_id": org["id"] if corp_record else None,
        "membership_id": member["id"] if corp_record else None, "channel": channel,
        "daily_room": room.name, "daily_room_url": room.url, "started_at": now_iso(),
        "processing": "pending" if record else "not_applicable",
    }
    caller_call = (await db.insert("calls", {
        **base, "user_id": user_id, "direction": "outbound", "contact_id": body.contact_id,
        "counterpart_name": counterpart, "counterpart_number": phone,
        "counterpart_user_id": body.callee_user_id or (contact or {}).get("app_user_id"),
    }))[0]

    employees = [{"user_id": user_id, "call_id": caller_call["id"]}] if record else []
    # Audio is kept only for work calls (the company's record). Personal calls are transcribed
    # live for their commitments and never stored as audio; their transcript is deleted after.
    work_audio = corp_record
    result: dict = {"call": caller_call, "room_url": room.url,
                    "token": await daily.token(room.name, user_id=user_id, user_name=caller_name),
                    "recorded": record, "decision": "ring",
                    "disclosure": (org["recording_disclosure"] if corp_record and org
                                   else PERSONAL_DISCLOSURE if personal_record else None)}

    if body.channel == "app":
        callee_id = caller_call["counterpart_user_id"]
        decision, callee_call = await _ring_app_user(callee_id, caller_call, caller_name, user_id, member, room.url)
        result["decision"] = decision.value
        if decision is not Decision.ring:
            await db.update("calls", {"status": decision.value, "ended_at": now_iso(),
                                      "processing": "not_applicable"}, id=caller_call["id"])
            result["call"]["status"] = decision.value
            result["call"]["processing"] = "not_applicable"
            result["recorded"], result["disclosure"] = False, None   # no conversation happens
            result["message"] = (f"{counterpart} is at work right now. We'll let them know you called."
                                 if decision is Decision.blocked_mode else
                                 f"{counterpart} is off duty. Your call has been logged for their team.")
            return result
        if callee_call and is_recorded(callee_call):
            employees.append({"user_id": callee_id, "call_id": callee_call["id"]})
            work_audio = work_audio or callee_call["mode"] == "corporate"

    if settings.bots_enabled and daily.enabled and (employees or body.channel == "pstn"):
        org_for_bot = org
        if not org_for_bot and employees:
            org_for_bot = await org_of(await active_membership(employees[0]["user_id"]))
        await bot_runner.spawn({
            "call_id": caller_call["id"], "room_url": room.url,
            "token": await daily.token(room.name, user_id="commit-ai-bot", user_name="Commit AI", owner=True),
            "record": bool(employees), "employees": employees, "keep_audio": work_audio,
            "dialout": {"phoneNumber": phone, **({"callerId": settings.daily_caller_id} if settings.daily_caller_id else {})}
                       if body.channel == "pstn" else None,
            # Anyone recording means both sides hear the notice: the company's wording on work
            # calls, a neutral one on personal calls.
            "disclosure": (None if not employees
                           else (org_for_bot["recording_disclosure"] if org_for_bot.get("announce_recording", True) else None)
                           if org_for_bot else PERSONAL_DISCLOSURE),
            "timezone": (org_for_bot or {}).get("timezone", "Africa/Lagos"),
            "employee_name": caller_name, "client_name": counterpart,
        })
    return result


async def _ring_app_user(callee_id, caller_call, caller_name, caller_id, caller_member, room_url):
    callee_presence = await presence_of(callee_id)
    callee_member = await active_membership(callee_id)
    callee_org = await org_of(callee_member)
    caller_is_client = False
    if callee_member:
        caller_is_client = any(c.get("app_user_id") == caller_id and c.get("is_client")
                               for c in await db.select("contacts", org_id=callee_member["org_id"]))
    # If the callee belongs to an org but is off duty, policy comes from their org.
    off_duty_org = callee_org
    colleague, colleague_member = False, None
    if caller_member or caller_call["mode"] != "corporate":
        # Colleagues: the callee belongs to the caller's org (the caller's active one, or any org
        # the caller is a member of when they're calling from Personal mode).
        caller_orgs = ([caller_member["org_id"]] if caller_member else
                       [m["org_id"] for m in await db.select("memberships", user_id=caller_id)])
        mships = [m for m in await db.select("memberships", user_id=callee_id) if m["org_id"] in caller_orgs]
        colleague = bool(mships)
        colleague_member = callee_member if callee_member and callee_member["org_id"] in caller_orgs else (mships or [None])[0]
        if not off_duty_org and mships:
            off_duty_org = await org_of(mships[0])
    callee_mode = Mode(callee_presence["mode"])
    # A work call only counts as "corporate" for the callee when they're at work themselves
    # (B2B: any org) or they're the caller's colleague. A work-mode caller ringing someone
    # outside their company who is in personal mode is an ordinary call: it rings.
    corporate_for_callee = caller_call["mode"] == "corporate" and (callee_mode is Mode.corporate or colleague)
    ctx = InboundContext(
        callee_mode=callee_mode,
        callee_org_id=callee_member["org_id"] if callee_member else None,
        call_is_corporate=corporate_for_callee,
        caller_org_id=caller_member["org_id"] if caller_member else None,
        caller_is_org_client=caller_is_client,
        off_duty_policy=(off_duty_org or {}).get("off_duty_policy", "voicemail"),
    )
    routing = route_inbound(ctx)
    record_member = callee_member
    if colleague:
        # Colleagues always reach each other, whatever mode either is in. It's a work call
        # (recorded for the company) if either side is at work; otherwise an ordinary call.
        work = callee_mode is Mode.corporate or caller_call["mode"] == "corporate"
        routing = RoutingResult(Decision.ring, record=work, reason="colleague")
        record_member = colleague_member
    corp_record = routing.record and record_member is not None
    personal_record = (not corp_record and routing.decision is Decision.ring
                       and await records_personal(callee_id))
    callee_record = corp_record or personal_record
    callee_call = (await db.insert("calls", {
        "mode": "corporate" if corp_record else "personal",
        "org_id": record_member["org_id"] if corp_record else None,
        "membership_id": record_member["id"] if corp_record else None,
        "user_id": callee_id, "direction": "inbound", "channel": "app",
        "counterpart_name": caller_name, "counterpart_user_id": caller_id,
        "daily_room": caller_call["daily_room"], "daily_room_url": room_url, "started_at": now_iso(),
        "status": "ringing" if routing.decision is Decision.ring else routing.decision.value,
        "processing": "pending" if callee_record else "not_applicable",
    }))[0]
    if routing.decision is Decision.ring:
        await pusher.send(await device_tokens(callee_id), high_priority=True, data={
            "type": "incoming_call", "call_id": callee_call["id"], "caller_name": caller_name,
            "room_url": room_url, "mode": callee_call["mode"], "recorded": str(callee_record).lower(),
        })
    elif routing.decision is Decision.off_duty and off_duty_org:
        log.info("off-duty corporate call to %s logged", callee_id)
    return routing.decision, callee_call


@app.get("/v1/calls/incoming")
async def incoming_calls(user_id: str = CurrentUser):
    """Calls ringing for this user right now. The app polls this when push isn't configured."""
    cutoff = utcnow() - timedelta(seconds=settings.ring_timeout_s)
    rows = await db.select("calls", user_id=user_id, status="ringing", direction="inbound",
                           order="started_at", desc=True, limit=5)
    return [{"call_id": r["id"], "caller_name": r.get("counterpart_name") or "Caller", "mode": r["mode"],
             "recorded": is_recorded(r), "room_url": r.get("daily_room_url")}
            for r in rows if (parse_dt(r.get("started_at")) or utcnow()) >= cutoff]


@app.post("/v1/calls/{call_id}/accept")
async def accept_call(call_id: str, user_id: str = CurrentUser):
    call = await db.get("calls", id=call_id)
    if not call or call["user_id"] != user_id:
        raise HTTPException(404, "call not found")
    if call["status"] != "ringing":
        raise HTTPException(409, f"call is {call['status']}")
    now = now_iso()
    for c in await db.select("calls", daily_room=call["daily_room"]):
        if c["status"] == "ringing" or c["id"] == call_id:
            await db.update("calls", {"status": "active", "answered_at": now}, id=c["id"])
    org = await db.get("organizations", id=call["org_id"]) if call["mode"] == "corporate" and call.get("org_id") else None
    recorded = is_recorded(call)
    return {"room_url": call.get("daily_room_url") or f"https://demo.daily.co/{call['daily_room']}",
            "token": await daily.token(call["daily_room"], user_id=user_id, user_name=await name_of(user_id)),
            "recorded": recorded,
            "disclosure": (org["recording_disclosure"] if org else PERSONAL_DISCLOSURE) if recorded else None}


@app.post("/v1/calls/{call_id}/decline")
async def decline_call(call_id: str, user_id: str = CurrentUser):
    call = await db.get("calls", id=call_id)
    if not call or call["user_id"] != user_id:
        raise HTTPException(404, "call not found")
    for c in await db.select("calls", daily_room=call["daily_room"]):
        await db.update("calls", {"status": "rejected", "ended_at": now_iso(), "processing": "not_applicable"}, id=c["id"])
    return {"ok": True}


@app.post("/v1/calls/{call_id}/end")
async def end_call(call_id: str, user_id: str = CurrentUser):
    call = await db.get("calls", id=call_id)
    if not call or call["user_id"] != user_id:
        raise HTTPException(404, "call not found")
    for c in await db.select("calls", daily_room=call["daily_room"]):
        if c["status"] in ("ringing", "active"):
            patch = {"status": "completed" if c.get("answered_at") else "missed", "ended_at": now_iso()}
            if not c.get("answered_at"):
                patch["processing"] = "not_applicable"   # nobody talked: nothing to transcribe
            await db.update("calls", patch, id=c["id"])
    return {"ok": True}


@app.get("/v1/calls")
async def list_calls(user_id: str = CurrentUser, limit: int = Query(50, ge=1, le=200)):
    """Recents for the current mode only — personal and corporate histories never mix."""
    mode = (await presence_of(user_id))["mode"]
    rows = await db.select("calls", user_id=user_id, mode=mode, order="started_at", desc=True, limit=limit)
    if mode == "personal":
        rows += await db.select("calls", user_id=user_id, status="blocked_mode", mode="personal")
    seen, out = set(), []
    for r in sorted(rows, key=lambda r: r["started_at"], reverse=True):
        if r["id"] not in seen:
            seen.add(r["id"])
            out.append(r)
    for r in out:
        r["commitment_count"] = len(await db.select("commitments", call_id=r["id"])) if is_recorded(r) else 0
    return out


@app.get("/v1/calls/{call_id}")
async def call_detail(call_id: str, user_id: str = CurrentUser):
    call = await db.get("calls", id=call_id)
    if not call or not await can_view_call(user_id, call):
        raise HTTPException(404, "call not found")
    detail = {"call": call, "transcript": [], "commitments": []}
    if is_recorded(call):
        detail["transcript"] = await db.select("transcript_segments", call_id=call_id, order="offset_ms")
        detail["commitments"] = await db.select("commitments", call_id=call_id, order="created_at")
    return detail


@app.get("/v1/calls/{call_id}/recording")
async def call_recording(call_id: str, user_id: str = CurrentUser):
    call = await db.get("calls", id=call_id)
    if not call or not is_recorded(call) or not await can_view_call(user_id, call):
        raise HTTPException(404, "call not found")
    rid = await daily.recording_for_room(call.get("daily_room")) or call.get("recording_id")
    if rid and rid != call.get("recording_id"):
        await db.update("calls", {"recording_id": rid}, id=call_id)
    link = await daily.recording_link(rid)
    if not link:
        raise HTTPException(404, "recording not available yet")
    return {"url": link}


class NewCommitment(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    due_at: str | None = None
    category: Literal["deliverable", "follow_up", "pricing", "meeting", "information", "support", "other"] = "other"


class Diagnostic(BaseModel):
    where: str = Field(max_length=40)
    message: str = Field(max_length=2000)
    call_id: str | None = Field(default=None, max_length=64)


diag_limiter = RateLimiter(30, 600)


@app.post("/v1/diagnostics")
async def client_diagnostic(body: Diagnostic, user_id: str = CurrentUser):
    """A phone reports a failure it hit (e.g. couldn't join the call audio), so it shows up in the server log."""
    try:
        diag_limiter.check(f"diag:{user_id}")
    except HTTPException:
        return {"ok": False}
    diag_limiter.hit(f"diag:{user_id}")
    log.warning("APP PROBLEM [%s] user=%s call=%s: %s", body.where, user_id, body.call_id, body.message)
    return {"ok": True}


class FlagBody(BaseModel):
    offset_ms: int = Field(ge=0, le=6 * 3600 * 1000)


@app.post("/v1/calls/{call_id}/flags")
async def flag_moment(call_id: str, body: FlagBody, user_id: str = CurrentUser):
    """The employee tapped "Flag commitment" during a work call. Extraction looks hardest there."""
    call = await db.get("calls", id=call_id)
    if not call or call["user_id"] != user_id or not is_recorded(call):
        raise HTTPException(404, "call not found")
    flags = list(call.get("flags") or [])
    if len(flags) < 50:
        flags.append(body.offset_ms)
        await db.update("calls", {"flags": flags}, id=call_id)
    return {"flags": flags}


class ReviewBody(BaseModel):
    """Post-call review: the employee confirms, edits or rejects what the AI found."""
    accept: list[str] = Field(default_factory=list, max_length=100)
    reject: list[str] = Field(default_factory=list, max_length=100)
    edits: dict[str, dict] = Field(default_factory=dict)   # id → {title?, due_at?, category?, priority?}
    add: list[NewCommitment] = Field(default_factory=list, max_length=50)


@app.post("/v1/calls/{call_id}/review")
async def review_call(call_id: str, body: ReviewBody, user_id: str = CurrentUser):
    call = await db.get("calls", id=call_id)
    if not call or call["user_id"] != user_id or not is_recorded(call):
        raise HTTPException(404, "call not found")
    for cid in body.accept:
        patch = {"status": "open", "confirmed_by_employee": True}
        edit = body.edits.get(cid) or {}
        if isinstance(edit.get("title"), str) and edit["title"].strip():
            patch["title"] = edit["title"].strip()[:200]
        if "due_at" in edit:
            patch["due_at"] = valid_iso(edit["due_at"])
        if edit.get("category") in CATEGORIES:
            patch["category"] = edit["category"]
        if edit.get("priority") in ("low", "medium", "high"):
            patch["priority"] = edit["priority"]
        await db.update("commitments", patch, id=cid, call_id=call_id)
        await _event(cid, user_id, "confirmed", {})
    for cid in body.reject:
        await db.update("commitments", {"status": "cancelled"}, id=cid, call_id=call_id)
        await _event(cid, user_id, "status_changed", {"to": "cancelled", "reason": "rejected in review"})
    for item in body.add:
        row = await _new_commitment(call, title=item.title.strip(), due_at=valid_iso(item.due_at),
                                    category=item.category, status="open", confirmed=True)
        await _event(row["id"], user_id, "created", {"manual": True})
    return await call_detail(call_id, user_id)


# ===================================================== PSTN dial-in ========
@app.post("/webhooks/daily/dialin")
async def daily_dialin(request: Request):
    """Daily pinless dial-in (room_creation_api): a GSM/landline caller rang a corporate number."""
    raw = await request.body()
    if settings.daily_dialin_hmac:
        ts = request.headers.get("x-pinless-timestamp", "")
        sig = request.headers.get("x-pinless-signature", "")
        try:
            key = base64.b64decode(settings.daily_dialin_hmac, validate=True)
        except ValueError:
            key = settings.daily_dialin_hmac.encode()
        expected = base64.b64encode(hmac.new(key, f"{ts}.".encode() + raw, hashlib.sha256).digest()).decode()
        if not sig or not hmac.compare_digest(sig, expected):
            raise HTTPException(401, "bad signature")
    elif settings.is_production:
        raise HTTPException(503, "dial-in webhook signing (DAILY_DIALIN_HMAC) is not configured")
    try:
        payload = await request.json()
    except ValueError as e:
        raise HTTPException(400, "invalid JSON") from e
    if not isinstance(payload, dict) or "Test" in payload or not payload.get("To"):
        return {"ok": True}   # Daily sends a test ping when the webhook is configured
    to, frm = payload.get("To"), payload.get("From")
    call_id, call_domain = payload.get("callId"), payload.get("callDomain")
    member = await db.get("memberships", corporate_did=to)
    if not member or not member.get("user_id"):
        raise HTTPException(404, "number not assigned")
    org = await db.get("organizations", id=member["org_id"])
    employee = member["user_id"]
    presence = await presence_of(employee)
    contact = next((c for c in await db.select("contacts", org_id=org["id"]) if c.get("phone_e164") == frm), None)
    routing = route_inbound(InboundContext(
        callee_mode=Mode(presence["mode"]), callee_org_id=org["id"], call_is_corporate=True,
        caller_is_org_client=bool(contact), off_duty_policy=org["off_duty_policy"],
    ))
    on_duty = routing.decision is Decision.ring
    room = await daily.create_room(sip_dialin=True, record=True)
    row = (await db.insert("calls", {
        "mode": "corporate", "org_id": org["id"], "membership_id": member["id"], "user_id": employee,
        "direction": "inbound", "channel": channel_for(frm or "+0"), "contact_id": (contact or {}).get("id"),
        "counterpart_name": (contact or {}).get("name") or frm, "counterpart_number": frm,
        "daily_room": room.name, "daily_room_url": room.url, "started_at": now_iso(),
        "status": "ringing" if on_duty else "off_duty", "processing": "pending",
    }))[0]
    if settings.bots_enabled and daily.enabled:
        await bot_runner.spawn({
            "call_id": row["id"], "room_url": room.url,
            "token": await daily.token(room.name, user_id="commit-ai-bot", user_name="Commit AI", owner=True),
            "record": True, "employees": [{"user_id": employee, "call_id": row["id"]}],
            "dialin": {"call_id": call_id, "call_domain": call_domain},
            "voicemail": None if on_duty else
                f"Hi, you've reached {await name_of(employee)} at {org['name']}. They're away right now. "
                "Please leave a message after the tone and they'll get back to you.",
            "disclosure": org["recording_disclosure"] if org.get("announce_recording", True) else None,
            "timezone": org.get("timezone", "Africa/Lagos"),
            "employee_name": await name_of(employee), "client_name": row["counterpart_name"],
        })
    if on_duty:
        await pusher.send(await device_tokens(employee), high_priority=True, data={
            "type": "incoming_call", "call_id": row["id"], "caller_name": row["counterpart_name"],
            "room_url": room.url, "mode": "corporate", "recorded": "true",
        })
    return {"ok": True}


# ================================================ bot → API (internal) =====
class BotEvent(BaseModel):
    kind: Literal["answered", "consent_announced", "recording_started", "live_commitment", "unanswered", "ended"]
    data: dict = Field(default_factory=dict)


@app.post("/internal/calls/{call_id}/events", dependencies=[InternalOnly])
async def bot_event(call_id: str, ev: BotEvent):
    call = await db.get("calls", id=call_id)
    if not call:
        raise HTTPException(404)
    room_calls = await db.select("calls", daily_room=call["daily_room"])
    if ev.kind == "answered":
        for c in room_calls:
            await db.update("calls", {"status": "active", "answered_at": now_iso()}, id=c["id"])
    elif ev.kind == "consent_announced":
        for c in room_calls:
            await db.update("calls", {"consent_announced": True}, id=c["id"])
    elif ev.kind == "recording_started":
        # Resolve the real recording id from Daily (the bot only knows a stream id).
        rid = await daily.recording_for_room(call["daily_room"])
        if rid:
            for c in room_calls:
                if c["mode"] == "corporate":
                    await db.update("calls", {"recording_id": rid}, id=c["id"])
    elif ev.kind == "unanswered":
        # Nobody picked up an inbound GSM/landline call; the bot is now taking a voicemail.
        # Stop ringing the employee; the message is still transcribed into follow-ups.
        for c in room_calls:
            if c["status"] == "ringing":
                await db.update("calls", {"status": "missed"}, id=c["id"])
    elif ev.kind == "ended":
        for c in room_calls:
            if c["status"] in ("ringing", "active"):
                await db.update("calls", {"status": "completed" if c.get("answered_at") else "missed",
                                          "ended_at": now_iso()}, id=c["id"])
    return {"ok": True}


class SegmentIn(BaseModel):
    speaker: Literal["employee", "client", "unknown"]
    text: str
    offset_ms: int


class BotComplete(BaseModel):
    segments: list[SegmentIn]
    voicemail: bool = False


@app.post("/internal/calls/{call_id}/complete", dependencies=[InternalOnly])
async def bot_complete(call_id: str, body: BotComplete):
    """The bot posts the final transcript for one employee's view of the call; we extract and store."""
    return await process_transcript(call_id, [Segment(**s.model_dump()) for s in body.segments], body.voicemail)


async def process_transcript(call_id: str, segments: list[Segment], voicemail: bool = False) -> dict:
    call = await db.get("calls", id=call_id)
    if not call or not is_recorded(call):
        raise HTTPException(404, "recorded call not found")
    await db.update("calls", {"processing": "processing"}, id=call_id)
    org = (await db.get("organizations", id=call["org_id"]) if call.get("org_id") else None) or {}
    segments = merge_fragments(segments)   # re-join sentences split by live speech-to-text
    await db.delete("transcript_segments", call_id=call_id)
    if segments:
        await db.insert("transcript_segments", [{"call_id": call_id, "speaker": s.speaker, "text": s.text,
                                                 "offset_ms": s.offset_ms} for s in segments])
    try:
        result = await extract(segments, parse_dt(call.get("answered_at") or call["started_at"]),
                               tz=org.get("timezone", "Africa/Lagos"),
                               employee_name=await name_of(call["user_id"]),
                               client_name=call.get("counterpart_name") or "the client",
                               flags=[int(f) for f in (call.get("flags") or [])],
                               voicemail=voicemail)
    except Exception:
        await db.update("calls", {"processing": "failed"}, id=call_id)
        raise
    # Idempotent: a retried bot post replaces the AI findings nobody has reviewed yet.
    for old in await db.select("commitments", call_id=call_id, status="pending_review"):
        await db.delete("commitment_events", commitment_id=old["id"])
        await db.delete("commitments", id=old["id"])
    if call["mode"] == "personal":
        # Personal calls are only transcribed temporarily, to find the commitments.
        await db.delete("transcript_segments", call_id=call_id)
    created = []
    for c in result.commitments:
        due_at = c.due_at
        try:
            due_at = valid_iso(due_at)
        except HTTPException:
            due_at = None
        created.append(await _new_commitment(
            call, title=c.title[:200], detail=c.detail, quote=c.quote, quote_offset_ms=c.quote_offset_ms,
            due_at=due_at, due_text=c.due_text, category=c.category if c.category in CATEGORIES else "other",
            priority=c.priority, confidence=max(0.0, min(1.0, float(c.confidence))), owner=c.owner,
            # Low-confidence items wait for the employee; clear promises go live immediately.
            # Everything starts in review; the scheduler auto-publishes confident items the
            # employee hasn't reviewed within 24h so management is never left blind.
            status="pending_review",
        ))
        await _event(created[-1]["id"], None, "created", {"title": created[-1]["title"], "source": "ai"})
    summary = ("Voicemail: " if voicemail else "") + result.summary
    await db.update("calls", {"processing": "done", "summary": summary, "sentiment": result.sentiment,
                              "employee_talk_ratio": result.employee_talk_ratio}, id=call_id)
    # Nudge the employee to review on their phone.
    if created:
        await pusher.send(await device_tokens(call["user_id"]), data={"type": "review_call", "call_id": call_id},
                          title=f"{len(created)} commitment{'s' if len(created) != 1 else ''} from your call",
                          body=f"With {call.get('counterpart_name') or 'client'} — tap to confirm.")
    return {"call_id": call_id, "commitments": created, "summary": summary, "sentiment": result.sentiment}


async def _new_commitment(call: dict, *, title: str, status: str, confirmed: bool = False, **kw) -> dict:
    contact = await db.get("contacts", id=call["contact_id"]) if call.get("contact_id") else None
    row = {
        # Personal calls: no org / membership; the commitment belongs to the user alone.
        "org_id": call.get("org_id"), "call_id": call["id"], "membership_id": call.get("membership_id"),
        "user_id": call["user_id"],
        "contact_id": call.get("contact_id"), "client_name": (contact or {}).get("company") or call.get("counterpart_name"),
        "title": title, "status": status, "confirmed_by_employee": confirmed,
        "owner": kw.pop("owner", "employee"), **{k: v for k, v in kw.items() if v is not None},
    }
    return (await db.insert("commitments", row))[0]


async def _event(commitment_id: str, actor: str | None, kind: str, payload: dict) -> None:
    await db.insert("commitment_events", {"commitment_id": commitment_id, "actor_id": actor, "kind": kind,
                                          "payload": payload, "created_at": now_iso()})


# ========================================================= commitments =====
async def commitment_for(user_id: str, cid: str) -> tuple[dict, dict | None]:
    """The commitment if this user may see it: their own personal one, or a work one in their
    visible team (in Work mode). Returns (row, membership-or-None)."""
    row = await db.get("commitments", id=cid)
    if row and row.get("org_id") is None:
        if row.get("user_id") == user_id:
            return row, None
        raise HTTPException(404)
    m = await require_membership(user_id)
    if not row or row["membership_id"] not in await visible_member_ids(m):
        raise HTTPException(404)
    return row, m


@app.get("/v1/commitments")
async def list_commitments(user_id: str = CurrentUser, scope: Literal["mine", "team"] = "mine",
                           status: str | None = None, member_id: str | None = None):
    m = await active_membership(user_id)
    if m is None:
        # Personal mode: the user's own commitments from personal calls (never a team view).
        if scope == "team":
            raise HTTPException(403, "switch to corporate mode first")
        rows = [r for r in await db.select("commitments", user_id=user_id) if r.get("org_id") is None]
        if status:
            rows = [r for r in rows if r["status"] in set(status.split(","))]
        me_name = await name_of(user_id)
        for r in rows:
            r["employee_name"] = me_name
        far = utcnow() + timedelta(days=3650)
        rank = {"pending_review": 0, "missed": 1, "open": 2, "in_progress": 2, "disputed": 3, "fulfilled": 5, "cancelled": 6}
        rows.sort(key=lambda r: (rank.get(r["status"], 4), parse_dt(r.get("due_at")) or far))
        return rows
    if scope == "mine":
        ids = {m["id"]}
    else:
        ids = await visible_member_ids(m)
        if member_id:
            ids &= {member_id}
    rows = await db.select("commitments", org_id=m["org_id"], in_={"membership_id": list(ids)})
    if status:
        wanted = set(status.split(","))
        rows = [r for r in rows if r["status"] in wanted]
    names = {x["id"]: await name_of(x["user_id"]) for x in await db.select("memberships", org_id=m["org_id"])}
    for r in rows:
        r["employee_name"] = names.get(r["membership_id"])
    now = utcnow()
    rank = {"pending_review": 0, "missed": 1, "open": 2, "in_progress": 2, "disputed": 3, "fulfilled": 5, "cancelled": 6}
    rows.sort(key=lambda r: (rank.get(r["status"], 4), parse_dt(r.get("due_at")) or now + timedelta(days=3650)))
    return rows


class CommitmentPatch(BaseModel):
    status: Literal["open", "in_progress", "fulfilled", "missed", "disputed", "cancelled"] | None = None
    title: str | None = Field(default=None, min_length=1, max_length=200)
    due_at: str | None = None
    note: str | None = Field(default=None, max_length=2000)


@app.patch("/v1/commitments/{cid}")
async def update_commitment(cid: str, body: CommitmentPatch, user_id: str = CurrentUser):
    row, _m = await commitment_for(user_id, cid)
    patch = body.model_dump(exclude_none=True, exclude={"note"})
    if body.due_at:
        patch["due_at"] = valid_iso(body.due_at)
    if body.status == "fulfilled":
        patch["completed_at"] = now_iso()
    if body.status and body.status != row["status"]:
        await _event(cid, user_id, "status_changed", {"from": row["status"], "to": body.status, "note": body.note})
    if body.due_at and body.due_at != row.get("due_at"):
        await _event(cid, user_id, "due_changed", {"from": row.get("due_at"), "to": body.due_at})
    if patch:
        row = (await db.update("commitments", patch, id=cid))[0]
    return row


class CommentBody(BaseModel):
    text: str = Field(min_length=1, max_length=2000)


@app.post("/v1/commitments/{cid}/comments")
async def comment(cid: str, body: CommentBody, user_id: str = CurrentUser):
    await commitment_for(user_id, cid)
    await _event(cid, user_id, "comment", {"text": body.text, "author": await name_of(user_id)})
    return {"ok": True}


@app.post("/v1/commitments/{cid}/nudge")
async def nudge(cid: str, user_id: str = CurrentUser):
    """Manager taps 'Nudge' — the employee gets a push with the exact promise."""
    m = await require_membership(user_id)
    row = await db.get("commitments", id=cid)
    if not row or row["membership_id"] not in await visible_member_ids(m) or row["membership_id"] == m["id"]:
        raise HTTPException(404)
    owner = await db.get("memberships", id=row["membership_id"])
    await pusher.send(await device_tokens(owner["user_id"]), data={"type": "commitment", "commitment_id": cid},
                      title=f"{await name_of(user_id)} is following up",
                      body=f"“{row['title']}” for {row.get('client_name') or 'your client'}")
    await _event(cid, user_id, "nudge", {"by": await name_of(user_id)})
    return {"ok": True}


@app.get("/v1/commitments/{cid}/events")
async def commitment_events(cid: str, user_id: str = CurrentUser):
    await commitment_for(user_id, cid)
    events = await db.select("commitment_events", commitment_id=cid, order="created_at")
    for e in events:
        e["actor_name"] = await name_of(e.get("actor_id")) if e.get("actor_id") else "Commit AI"
    return events


# =========================================================== dashboard =====
@app.get("/v1/dashboard")
async def dashboard(user_id: str = CurrentUser, days: int = Query(30, ge=1, le=365)):
    m = await require_membership(user_id)
    if m["role"] == "employee":
        raise HTTPException(403, "managers only")
    ids = await visible_member_ids(m)
    members = [x for x in await db.select("memberships", org_id=m["org_id"]) if x["id"] in ids]
    rows = [c for c in await db.select("commitments", org_id=m["org_id"], in_={"membership_id": list(ids)})
            if c["owner"] == "employee"]
    calls = [c for c in await db.select("calls", org_id=m["org_id"]) if c.get("membership_id") in ids]
    now, since = utcnow(), utcnow() - timedelta(days=days)

    def due(c):
        return parse_dt(c.get("due_at"))

    def kept_on_time(c):
        done_at = parse_dt(c.get("completed_at"))
        return c["status"] == "fulfilled" and (not due(c) or not done_at or done_at <= due(c))

    live = [c for c in rows if c["status"] in ("open", "in_progress")]
    closed = [c for c in rows if c["status"] in ("fulfilled", "missed") and (due(c) or now) >= since]
    on_time = [c for c in closed if kept_on_time(c)]
    overdue = [c for c in live if due(c) and due(c) < now] + [c for c in rows if c["status"] == "missed" and (due(c) or now) >= since]
    recent_calls = [c for c in calls if c.get("started_at") and parse_dt(c["started_at"]) >= since]

    weeks = []
    for w in range(7, -1, -1):
        start = now - timedelta(days=7 * (w + 1))
        end = now - timedelta(days=7 * w)
        weeks.append({
            "week_start": start.date().isoformat(),
            "made": sum(1 for c in rows if start <= parse_dt(c["created_at"]) < end),
            "kept": sum(1 for c in rows if c["status"] == "fulfilled" and c.get("completed_at")
                        and start <= parse_dt(c["completed_at"]) < end),
            "missed": sum(1 for c in rows if c["status"] == "missed" and due(c) and start <= due(c) < end),
        })

    people = []
    for mem in members:
        mine = [c for c in rows if c["membership_id"] == mem["id"]]
        done = [c for c in mine if c["status"] in ("fulfilled", "missed")]
        kept = [c for c in done if kept_on_time(c)]
        people.append({
            "membership_id": mem["id"], "name": await name_of(mem["user_id"]), "title": mem.get("title"),
            "open": sum(1 for c in mine if c["status"] in ("open", "in_progress")),
            "overdue": sum(1 for c in mine if c["status"] == "missed" or
                           (c["status"] in ("open", "in_progress") and due(c) and due(c) < now)),
            "pending_review": sum(1 for c in mine if c["status"] == "pending_review"),
            "reliability": round(100 * len(kept) / len(done)) if done else None,
            "calls": sum(1 for c in recent_calls if c["membership_id"] == mem["id"]),
        })
    people.sort(key=lambda p: (-(p["overdue"]), p["reliability"] or 0))

    at_risk = sorted(
        [c for c in live if due(c) and due(c) < now + timedelta(hours=48)] +
        [c for c in rows if c["status"] == "missed" and (due(c) or now) >= now - timedelta(days=7)],
        key=lambda c: due(c) or now)
    names = {mem["id"]: next(p["name"] for p in people if p["membership_id"] == mem["id"]) for mem in members}
    for c in at_risk:
        c["employee_name"] = names.get(c["membership_id"])

    return {
        "range_days": days,
        "kpis": {
            "open": len(live),
            "due_this_week": sum(1 for c in live if due(c) and now <= due(c) < now + timedelta(days=7)),
            "overdue": len(overdue),
            "pending_review": sum(1 for c in rows if c["status"] == "pending_review"),
            "on_time_rate": round(100 * len(on_time) / len(closed)) if closed else None,
            "calls": len(recent_calls),
            "commitments_per_call": round(sum(1 for c in rows if c.get("call_id") and parse_dt(c["created_at"]) >= since)
                                          / max(1, len(recent_calls)), 1),
            "off_duty_attempts": sum(1 for c in recent_calls if c["status"] == "off_duty"),
        },
        "trend": weeks,
        "by_category": Counter(c["category"] for c in live),
        "people": people,
        "at_risk": at_risk[:15],
        "attention_calls": [c for c in sorted(recent_calls, key=lambda c: c["started_at"], reverse=True)
                            if c.get("sentiment") in ("negative", "mixed")][:5],
    }


# =============================================================== dev =======
@app.post("/dev/calls/{call_id}/simulate")
async def simulate(call_id: str, user_id: str = CurrentUser):
    """Feed the sample Bello Foods transcript through extraction (no Daily needed)."""
    if not settings.dev_auth:
        raise HTTPException(404)
    from .seed import DEMO_TRANSCRIPT

    call = await db.get("calls", id=call_id)
    if not call or call["user_id"] != user_id:
        raise HTTPException(404)
    if not call.get("answered_at"):
        await db.update("calls", {"answered_at": call["started_at"], "status": "completed", "ended_at": now_iso()}, id=call_id)
    segs = [Segment(sp, text, i * 21000) for i, (sp, text) in enumerate(DEMO_TRANSCRIPT)]
    return await process_transcript(call_id, segs)

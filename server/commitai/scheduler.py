"""Background accountability loop.

Every few minutes:
* remind employees of commitments due within REMINDER_LEAD_HOURS (once each),
* mark commitments missed when the deadline passes, and escalate to the manager,
* auto-publish confident AI findings an employee hasn't reviewed within 24h,
  so management is never left blind by a skipped review.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from .config import settings
from .push import pusher
from .store import Store, now_iso

log = logging.getLogger(__name__)


def _dt(s: str | None) -> datetime | None:
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


async def _tokens(db: Store, user_id: str) -> list[str]:
    return [d["push_token"] for d in await db.select("devices", user_id=user_id) if d.get("push_token")]


async def tick(db: Store, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    stats = {"reminded": 0, "missed": 0, "auto_published": 0}
    members = {m["id"]: m for m in await db.select("memberships")}

    for c in await db.select("commitments", in_={"status": ["open", "in_progress"]}):
        if c.get("owner") == "client":
            continue   # the client's promise: nothing for our user to be reminded to do
        due = _dt(c.get("due_at"))
        member = members.get(c.get("membership_id"))
        # Work commitments belong to the member's user; personal ones to their user directly.
        owner_user = (member or {}).get("user_id") or c.get("user_id")
        if not due or not owner_user:
            continue
        what = f"{c['title']}" + (f" — {c['client_name']}" if c.get("client_name") else "")
        if due < now - timedelta(hours=1):
            await db.update("commitments", {"status": "missed"}, id=c["id"])
            await db.insert("commitment_events", {"commitment_id": c["id"], "actor_id": None, "kind": "escalated",
                                                  "payload": {"reason": "deadline passed"}, "created_at": now_iso()})
            stats["missed"] += 1
            await pusher.send(await _tokens(db, owner_user), data={"type": "commitment", "commitment_id": c["id"]},
                              title="Deadline passed", body=what)
            manager = members.get((member or {}).get("manager_id"))
            if manager and manager.get("user_id"):
                await pusher.send(await _tokens(db, manager["user_id"]),
                                  data={"type": "commitment", "commitment_id": c["id"]},
                                  title="Commitment missed",
                                  body=f"“{c['title']}” for {c.get('client_name') or 'a client'} is overdue.")
            continue
        # Two reminders per deadline: a day before (REMINDER_LEAD_HOURS) and 2 hours before.
        sent = {(e.get("payload") or {}).get("stage", "day")
                for e in await db.select("commitment_events", commitment_id=c["id"], kind="reminder")}
        for stage, lead, title in (("soon", timedelta(hours=2), "Due in 2 hours"),
                                   ("day", timedelta(hours=settings.reminder_lead_hours), "Due soon")):
            if due < now + lead and stage not in sent:
                await pusher.send(await _tokens(db, owner_user), data={"type": "commitment", "commitment_id": c["id"]},
                                  title=title, body=what)
                await db.insert("commitment_events", {"commitment_id": c["id"], "actor_id": None, "kind": "reminder",
                                                      "payload": {"stage": stage}, "created_at": now_iso()})
                stats["reminded"] += 1
                break   # one reminder per tick; a commitment found inside 2 h skips the day-before one

    for c in await db.select("commitments", status="pending_review"):
        if float(c.get("confidence", 0)) >= 0.7 and _dt(c["created_at"]) < now - timedelta(hours=24):
            await db.update("commitments", {"status": "open"}, id=c["id"])
            await db.insert("commitment_events", {"commitment_id": c["id"], "actor_id": None, "kind": "confirmed",
                                                  "payload": {"auto": True}, "created_at": now_iso()})
            stats["auto_published"] += 1

    stats["expired_rings"] = await expire_unanswered(db, now)
    stats["stale_processing"] = await fail_stale_processing(db, now)
    stats["purged_transcripts"] = await apply_retention(db, now)
    return stats


STALE_PROCESSING = timedelta(minutes=15)


async def fail_stale_processing(db: Store, now: datetime) -> int:
    """A recorded call whose transcript never arrived (bot crashed, call never really connected)
    would otherwise show "processing" forever. 15 minutes after it ended, mark it failed."""
    n = 0
    for state in ("pending", "processing"):
        for c in await db.select("calls", processing=state):
            ended = _dt(c.get("ended_at"))
            if ended and ended < now - STALE_PROCESSING:
                await db.update("calls", {"processing": "failed",
                                          "summary": c.get("summary") or "No transcript was received for this call."},
                                id=c["id"])
                n += 1
    return n


async def expire_unanswered(db: Store, now: datetime) -> int:
    """Calls nobody picked up stop ringing after RING_TIMEOUT_S (both legs share the Daily room)."""
    cutoff = now - timedelta(seconds=settings.ring_timeout_s)
    expired = 0
    for c in await db.select("calls", status="ringing"):
        started = _dt(c.get("started_at"))
        if started and started < cutoff:
            await db.update("calls", {"status": "missed", "ended_at": now_iso(), "processing": "not_applicable"},
                            id=c["id"])
            expired += 1
    return expired


async def apply_retention(db: Store, now: datetime) -> int:
    """Delete transcripts of corporate calls older than the organisation's retention_days.

    Commitments (and their verbatim quote) are kept: they are the business record.
    Daily recordings have their own retention, configured on the Daily domain.
    """
    purged = 0
    for org in await db.select("organizations"):
        days = org.get("retention_days")
        if not days:
            continue
        cutoff = now - timedelta(days=int(days))
        for call in await db.select("calls", org_id=org["id"], mode="corporate"):
            started = _dt(call.get("started_at"))
            if started and started < cutoff and not call.get("transcript_purged"):
                await db.delete("transcript_segments", call_id=call["id"])
                await db.update("calls", {"transcript_purged": True, "recording_id": None}, id=call["id"])
                purged += 1
    return purged


RING_SWEEP_S = 15


async def run_scheduler(db: Store) -> None:
    last_full = 0.0
    loop = asyncio.get_running_loop()
    while True:
        try:
            if loop.time() - last_full >= settings.scheduler_interval_s:
                last_full = loop.time()
                stats = await tick(db)
            else:
                stats = {"expired_rings": await expire_unanswered(db, datetime.now(timezone.utc))}
            if any(stats.values()):
                log.info("scheduler: %s", stats)
        except Exception:  # noqa: BLE001
            log.exception("scheduler tick failed")
        await asyncio.sleep(RING_SWEEP_S)

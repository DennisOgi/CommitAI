"""Call-routing policy: who gets rung, and whether the call is recorded.

This is a pure function so it is easy to reason about and to test. The rules:

1. A user in CORPORATE mode only receives corporate traffic:
   - app calls placed in corporate mode (any org — B2B clients use the app too),
   - calls to their corporate number (GSM / landline dial-in),
   - app calls from a contact listed in their org's client directory.
   Everything else (friends, family, personal app calls) is held back as
   ``blocked_mode``: the caller hears "they're at work", the user gets a
   quiet digest of what they missed when they switch back to personal.

2. A user in PERSONAL mode receives personal calls normally. Corporate calls
   follow the organisation's ``off_duty_policy``: ``ring`` (rung, but still
   recorded as corporate) or ``voicemail`` (logged as ``off_duty`` so the
   manager dashboard shows the client tried to reach them).

3. Recording and AI extraction happen if and only if the *employee side*
   of the call is corporate. Personal calls are never recorded.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Mode(str, Enum):
    personal = "personal"
    corporate = "corporate"


class Decision(str, Enum):
    ring = "ring"
    blocked_mode = "blocked_mode"   # callee is at work; this is a personal call
    off_duty = "off_duty"           # corporate call; callee is in personal mode and policy says voicemail


@dataclass(frozen=True)
class InboundContext:
    callee_mode: Mode
    callee_org_id: str | None            # org of the callee's active corporate membership
    call_is_corporate: bool              # placed in corporate mode, or arrived on a corporate number
    caller_org_id: str | None = None
    caller_is_org_client: bool = False   # caller is in the callee org's client directory
    target_org_id: str | None = None     # org whose number/employee was dialled (for corporate calls)
    off_duty_policy: str = "voicemail"


@dataclass(frozen=True)
class RoutingResult:
    decision: Decision
    record: bool
    reason: str


def route_inbound(ctx: InboundContext) -> RoutingResult:
    if ctx.callee_mode is Mode.corporate:
        if ctx.call_is_corporate or ctx.caller_is_org_client:
            return RoutingResult(Decision.ring, record=True,
                                 reason="corporate traffic while on duty")
        return RoutingResult(Decision.blocked_mode, record=False,
                             reason="personal call held while user is in corporate mode")

    # Callee is in personal mode.
    if not ctx.call_is_corporate:
        return RoutingResult(Decision.ring, record=False, reason="personal call")
    if ctx.off_duty_policy == "ring":
        return RoutingResult(Decision.ring, record=True,
                             reason="corporate call; org policy rings off-duty staff")
    return RoutingResult(Decision.off_duty, record=False,
                         reason="corporate call while user is off duty")


def should_record_outbound(caller_mode: Mode) -> bool:
    return caller_mode is Mode.corporate

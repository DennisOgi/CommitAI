from datetime import datetime
from zoneinfo import ZoneInfo

from commitai.extractor import HeuristicExtractor, Segment, resolve_due
from commitai.seed import DEMO_TRANSCRIPT

LAGOS = ZoneInfo("Africa/Lagos")
TUESDAY = datetime(2026, 11, 3, 14, 30, tzinfo=LAGOS)


def test_resolve_due_phrases():
    assert resolve_due("by Friday", TUESDAY).date().isoformat() == "2026-11-06"
    assert resolve_due("tomorrow morning", TUESDAY).hour == 10
    assert resolve_due("next Tuesday", TUESDAY).date().isoformat() == "2026-11-10"
    assert resolve_due("end of the week", TUESDAY).date().isoformat() == "2026-11-06"
    assert resolve_due("in two days", TUESDAY).date().isoformat() == "2026-11-05"
    assert resolve_due("today", TUESDAY).hour == 17


def test_heuristic_finds_demo_commitments():
    segs = [Segment(sp, t, i * 1000) for i, (sp, t) in enumerate(DEMO_TRANSCRIPT)]
    out = HeuristicExtractor().extract(segs, TUESDAY)
    emp = [c for c in out.commitments if c.owner == "employee"]
    client = [c for c in out.commitments if c.owner == "client"]
    titles = " | ".join(c.title.lower() for c in emp)
    assert len(emp) >= 4, titles
    assert "incident report" in titles and "invoice" in titles
    assert client and "schedule" in client[0].title.lower()
    report = next(c for c in emp if "incident report" in c.title.lower())
    assert report.due_at.startswith("2026-11-06") and report.category == "deliverable"
    invoice = next(c for c in emp if "invoice" in c.title.lower())
    assert invoice.category == "pricing" and invoice.priority == "high"
    assert out.sentiment == "mixed"
    assert 0 < out.employee_talk_ratio < 1


def test_hedges_and_non_promises():
    h = HeuristicExtractor()
    assert not h.detect("I'll be honest with you, it was a bad week.", "employee", 0, TUESDAY)
    hedged = h.detect("Maybe I will send something next week.", "employee", 0, TUESDAY)
    assert hedged and hedged[0].confidence < 0.7


def test_next_weekday_means_following_calendar_week():
    thursday = datetime(2026, 11, 12, 14, 30, tzinfo=LAGOS)
    assert resolve_due("next Tuesday", thursday).date().isoformat() == "2026-11-17"
    assert resolve_due("by Friday", thursday).date().isoformat() == "2026-11-13"
    monday = datetime(2026, 11, 9, 9, 0, tzinfo=LAGOS)
    assert resolve_due("next Friday", monday).date().isoformat() == "2026-11-20"
    assert resolve_due("Friday", monday).date().isoformat() == "2026-11-13"

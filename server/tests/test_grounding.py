"""Extraction safeguards, voicemail handling, flags and phone-number classification."""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from commitai.api import app, channel_for
from commitai.extractor import ExtractedCommitment, Extraction, HeuristicExtractor, Segment, extract, ground
from commitai.seed import ADA

LAGOS = ZoneInfo("Africa/Lagos")
CALL = datetime(2026, 11, 3, 14, 30, tzinfo=LAGOS)
SEGS = [
    Segment("client", "The last delivery was late again and I'm not happy.", 0),
    Segment("employee", "I'll send you the incident report by Friday, you have my word.", 21000),
    Segment("employee", "And I will apply a ten percent credit on the next invoice.", 42000),
]


def C(**kw):
    base = dict(title="Send incident report", owner="employee", quote="I'll send you the incident report by Friday",
                quote_offset_ms=0, due_at=(CALL + timedelta(days=3)).isoformat(), confidence=0.9)
    return ExtractedCommitment(**{**base, **kw})


def test_exact_quote_gets_real_offset():
    out = ground(Extraction([C()]), SEGS, CALL, LAGOS)
    assert out.commitments[0].quote_offset_ms == 21000 and out.commitments[0].confidence == 0.9


def test_paraphrased_quote_replaced_with_what_was_said():
    out = ground(Extraction([C(quote="I will send the incident report by Friday, you have my word")]), SEGS, CALL, LAGOS)
    c = out.commitments[0]
    assert c.quote == SEGS[1].text and c.confidence < 0.9


def test_fabricated_quote_is_marked_low_confidence():
    out = ground(Extraction([C(quote="We will refund the full order and fly your manager to Dubai")]), SEGS, CALL, LAGOS)
    c = out.commitments[0]
    assert c.confidence <= 0.4 and "could not be matched" in c.detail


def test_deadline_before_the_call_is_dropped():
    out = ground(Extraction([C(due_at=(CALL - timedelta(days=2)).isoformat())]), SEGS, CALL, LAGOS)
    assert out.commitments[0].due_at is None


def test_naive_deadline_gets_org_timezone():
    out = ground(Extraction([C(due_at="2026-11-06T17:00:00")]), SEGS, CALL, LAGOS)
    assert out.commitments[0].due_at.endswith("+01:00")


def test_duplicates_are_merged_keeping_the_most_confident():
    out = ground(Extraction([C(confidence=0.6), C(title="Send the incident report", confidence=0.95)]), SEGS, CALL, LAGOS)
    assert len(out.commitments) == 1 and out.commitments[0].confidence == 0.95


def test_flagged_moment_raises_confidence():
    out = ground(Extraction([C(quote=SEGS[2].text, title="Apply credit", confidence=0.55)]), SEGS, CALL, LAGOS, flags=[45000])
    assert out.commitments[0].confidence >= 0.8


@pytest.mark.asyncio
async def test_empty_transcript_extracts_nothing():
    out = await extract([], CALL)
    assert out.commitments == [] and "No speech" in out.summary


def test_voicemail_becomes_a_callback_for_the_employee():
    vm = [Segment("client", "Hi, it's Ibrahim from Bello Foods. Please call me back about the delayed pallets.", 0)]
    out = HeuristicExtractor().extract(vm, CALL, voicemail=True)
    c = out.commitments[0]
    assert c.owner == "employee" and c.category == "follow_up" and "Bello Foods" in c.quote
    assert datetime.fromisoformat(c.due_at).date().isoformat() == "2026-11-04"


def test_channel_classification_any_country():
    assert channel_for("+2348059876543") == "pstn_mobile"     # Nigeria mobile
    assert channel_for("+442079460000") == "pstn_landline"    # London landline
    assert channel_for("+447911123456") == "pstn_mobile"      # UK mobile


def H(uid):
    return {"Authorization": f"Bearer dev:{uid}"}


def test_flags_and_bad_numbers_over_the_api():
    with TestClient(app) as c:
        c.post("/v1/corporate/login", headers=H(ADA), json={"corp_code": "LUMEN", "employee_id": "EMP-1042", "pin": "1234"})
        assert c.post("/v1/calls", headers=H(ADA), json={"channel": "pstn", "phone": "+2341"}).status_code == 422
        call_id = c.post("/v1/calls", headers=H(ADA), json={"channel": "pstn", "phone": "+442079460000"}).json()["call"]["id"]
        assert c.get(f"/v1/calls/{call_id}", headers=H(ADA)).json()["call"]["channel"] == "pstn_landline"
        assert c.post(f"/v1/calls/{call_id}/flags", headers=H(ADA), json={"offset_ms": 42000}).json()["flags"] == [42000]


def test_spoken_deadline_overrides_model_date_arithmetic():
    # Model said "by Friday" but put Saturday; our resolver puts it on Friday 17:00 local.
    wrong = C(due_text="by Friday", due_at="2026-11-07T17:00:00+01:00")
    out = ground(Extraction([wrong]), SEGS, CALL, LAGOS)
    assert out.commitments[0].due_at.startswith("2026-11-06T17:00")
    # Phrases we can't resolve keep the model's date.
    odd = C(due_text="before the board meeting", due_at="2026-11-20T10:00:00+01:00")
    assert ground(Extraction([odd]), SEGS, CALL, LAGOS).commitments[0].due_at.startswith("2026-11-20T10:00")


def test_split_sentences_are_rejoined():
    from commitai.extractor import merge_fragments

    segs = [Segment("employee", "And I'll make sure the next three Kano shipments go on our", 54000),
            Segment("employee", "priority lane at no extra cost.", 56000),
            Segment("client", "That would help.", 58000),
            Segment("client", "What about the invoice?", 60000)]
    out = merge_fragments(segs)
    assert [s.text for s in out] == ["And I'll make sure the next three Kano shipments go on our priority lane at no extra cost.",
                                     "That would help.", "What about the invoice?"]

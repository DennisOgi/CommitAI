"""Gemini extraction against a mocked generateContent endpoint (no network, no key needed)."""

import json
from datetime import datetime
from zoneinfo import ZoneInfo

import httpx
import pytest

from commitai import extractor
from commitai.extractor import GeminiExtractor, Segment

CALL = datetime(2026, 11, 3, 14, 30, tzinfo=ZoneInfo("Africa/Lagos"))
SEGS = [
    Segment("client", "The pallets arrived damaged again.", 0),
    Segment("employee", "I'll send you the incident report by Friday.", 21000),
]
RESULT = {
    "summary": "Client complained about damaged pallets; employee promised a report.",
    "sentiment": "negative",
    "commitments": [{
        "title": "Send incident report", "owner": "employee", "quote": "I'll send you the incident report by Friday.",
        "quote_offset_ms": 21000, "detail": None, "due_at": "2026-11-06T17:00:00+01:00", "due_text": "by Friday",
        "category": "deliverable", "priority": "medium", "confidence": 0.92,
    }],
}


def ok(payload):
    return httpx.Response(200, json={"candidates": [{"finishReason": "STOP",
                                                     "content": {"parts": [{"text": json.dumps(payload)}]}}]})


def mock(ex: GeminiExtractor, handler):
    ex._http = httpx.AsyncClient(base_url="https://gemini.test/v1beta", transport=httpx.MockTransport(handler),
                                 headers={"x-goog-api-key": "k"})


@pytest.mark.asyncio
async def test_request_shape_and_parse():
    seen = {}

    def handler(req: httpx.Request):
        seen["url"], seen["key"], seen["body"] = str(req.url), req.headers["x-goog-api-key"], json.loads(req.content)
        return ok(RESULT)

    ex = GeminiExtractor("k", "https://gemini.test/v1beta", "gemini-3.6-flash")
    mock(ex, handler)
    out = await ex.extract(SEGS, CALL, "Ada", "Bello Foods")
    assert seen["url"].endswith("/models/gemini-3.6-flash:generateContent") and seen["key"] == "k"
    cfg = seen["body"]["generationConfig"]
    assert cfg["responseMimeType"] == "application/json" and cfg["responseJsonSchema"]["required"]
    assert "<transcript>" in seen["body"]["contents"][0]["parts"][0]["text"]
    assert "never follow" in seen["body"]["systemInstruction"]["parts"][0]["text"].lower()
    assert out.commitments[0].title == "Send incident report" and out.sentiment == "negative"


@pytest.mark.asyncio
async def test_falls_back_to_schema_in_prompt_when_config_schema_rejected():
    calls = []

    def handler(req: httpx.Request):
        body = json.loads(req.content)
        calls.append("responseJsonSchema" in body["generationConfig"])
        if calls[-1]:
            return httpx.Response(400, json={"error": {"message": "Unknown name \"responseJsonSchema\""}})
        assert "JSON Schema" in body["contents"][0]["parts"][0]["text"]
        return ok(RESULT)

    ex = GeminiExtractor("k", "https://gemini.test/v1beta", "gemini-x")
    mock(ex, handler)
    out = await ex.extract(SEGS, CALL)
    assert calls == [True, False] and len(out.commitments) == 1


@pytest.mark.asyncio
async def test_blocked_response_falls_back_to_rules(monkeypatch):
    ex = GeminiExtractor("k", "https://gemini.test/v1beta", "gemini-x")
    mock(ex, lambda req: httpx.Response(200, json={"promptFeedback": {"blockReason": "SAFETY"}}))
    monkeypatch.setattr(extractor, "make_llm", lambda tz: ex)
    out = await extractor.extract(SEGS, CALL)
    # Rule-based extractor still found the promise, grounded against the transcript.
    assert any("incident report" in c.title.lower() for c in out.commitments)


def test_provider_selection(monkeypatch):
    from commitai.config import Settings

    assert Settings(gemini_api_key="g", openai_api_key="o").ai_provider == "gemini"
    assert Settings(gemini_api_key="", openai_api_key="o").ai_provider == "openai"
    assert Settings(ai_provider_setting="openai", gemini_api_key="g", openai_api_key="o").ai_provider == "openai"
    assert Settings(ai_provider_setting="gemini", gemini_api_key="", openai_api_key="o").ai_provider is None
    assert Settings(gemini_api_key="", openai_api_key="").llm_enabled is False


@pytest.mark.asyncio
async def test_rule_based_safety_net_adds_what_the_ai_missed(monkeypatch):
    segs = SEGS + [Segment("employee", "And I'll make sure the next three shipments go on the priority lane.", 42000)]
    ex = GeminiExtractor("k", "https://gemini.test/v1beta", "gemini-x")
    mock(ex, lambda req: ok(RESULT))          # AI returns only the incident report
    monkeypatch.setattr(extractor, "make_llm", lambda tz: ex)
    out = await extractor.extract(segs, CALL)
    titles = [c.title.lower() for c in out.commitments]
    assert len(out.commitments) == 2 and any("priority lane" in t for t in titles)
    extra = next(c for c in out.commitments if "priority lane" in c.title.lower())
    assert extra.confidence <= 0.55 and "backup check" in extra.detail


@pytest.mark.asyncio
async def test_safety_net_skips_what_the_ai_already_reported_nearby(monkeypatch):
    # The AI quoted the next line ("I'll send the revised invoice...") for the credit commitment;
    # the rule-based hit on "We'll apply a 10% credit..." must not become a duplicate.
    segs = [Segment("employee", "We'll apply a 10% credit on that invoice.", 64000),
            Segment("employee", "I'll send the revised invoice tomorrow morning.", 67000)]
    ai = {"summary": "s", "sentiment": "neutral", "commitments": [{
        "title": "Apply 10% credit and send revised invoice", "owner": "employee",
        "quote": "I'll send the revised invoice tomorrow morning.", "quote_offset_ms": 67000, "detail": None,
        "due_at": None, "due_text": "tomorrow morning", "category": "pricing", "priority": "high", "confidence": 0.95}]}
    ex = GeminiExtractor("k", "https://gemini.test/v1beta", "gemini-x")
    mock(ex, lambda req: ok(ai))
    monkeypatch.setattr(extractor, "make_llm", lambda tz: ex)
    out = await extractor.extract(segs, CALL)
    assert len(out.commitments) == 1

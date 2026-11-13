"""The bot's spoken phrases: synthesised once, then served from cache; failures never break a call."""

import pytest

from commitai import voice


@pytest.mark.asyncio
async def test_synthesis_is_cached_and_failures_are_silent(monkeypatch, tmp_path):
    from commitai.config import settings

    monkeypatch.setattr(voice, "_disk", tmp_path)
    monkeypatch.setattr(voice, "_memory", {})
    monkeypatch.setattr(type(settings), "ai_provider", property(lambda self: "gemini"))
    calls = []

    async def fake(text):
        calls.append(text)
        return b"\x00\x01" * 100

    monkeypatch.setattr(voice, "_gemini", fake)
    assert await voice.synthesize("This call is recorded.") == b"\x00\x01" * 100
    assert await voice.synthesize("This call is recorded.") == b"\x00\x01" * 100
    assert calls == ["This call is recorded."]           # second time from cache
    assert list(tmp_path.glob("*.pcm"))                  # and kept on disk for the next bot process

    async def broken(text):
        raise RuntimeError("API down")

    monkeypatch.setattr(voice, "_gemini", broken)
    assert await voice.synthesize("Something new") is None
    assert await voice.synthesize("   ") is None

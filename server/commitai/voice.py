"""Speech for the call bot's few fixed phrases: the recording disclosure, the "connecting you"
hold message and the voicemail greeting.

These are short, known sentences, so instead of a streaming TTS plugin we synthesise each one
once (cached per process and on disk), then play the PCM straight into the Daily call. This
uses Gemini's Interactions API, which is the only Gemini endpoint serving the current TTS models
(gemini-3.8-*-tts); OpenAI's /audio/speech is supported as the alternative provider.

All functions return 16-bit little-endian mono PCM at SAMPLE_RATE.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import io
import logging
import tempfile
import wave
from pathlib import Path

import httpx

from .config import settings

log = logging.getLogger(__name__)

SAMPLE_RATE = 24000
_memory: dict[str, bytes] = {}
_disk = Path(tempfile.gettempdir()) / "commitai-voice-cache"


def _key(text: str) -> str:
    who = (f"gemini:{settings.gemini_tts_model}:{settings.gemini_tts_voice}" if settings.ai_provider == "gemini"
           else f"openai:{settings.tts_voice}")
    return hashlib.sha256(f"{who}|{SAMPLE_RATE}|{text}".encode()).hexdigest()[:32]


def _pcm_from_wav(data: bytes) -> bytes:
    with wave.open(io.BytesIO(data)) as w:
        if w.getsampwidth() != 2 or w.getnchannels() != 1:
            raise ValueError(f"unexpected WAV format: {w.getnchannels()}ch {8 * w.getsampwidth()}-bit")
        if w.getframerate() != SAMPLE_RATE:
            raise ValueError(f"unexpected sample rate {w.getframerate()}")
        return w.readframes(w.getnframes())


async def _gemini(text: str) -> bytes:
    async with httpx.AsyncClient(timeout=60) as http:
        for attempt in range(3):
            r = await http.post(
                f"{settings.gemini_base_url.rstrip('/')}/interactions",
                headers={"x-goog-api-key": settings.gemini_api_key, "Api-Revision": "2026-05-20"},
                json={
                    "model": settings.gemini_tts_model,
                    "input": text,
                    "response_format": {"type": "audio", "mime_type": "audio/wav", "sample_rate": SAMPLE_RATE},
                    "generation_config": {"speech_config": [{"voice": settings.gemini_tts_voice}]},
                },
            )
            if r.status_code != 429 or attempt == 2:
                break
            # Rate-limited (low quotas on free Gemini keys): wait as told, but never long
            # enough to leave a caller in silence for more than a few seconds.
            await asyncio.sleep(min(8.0, float(r.headers.get("retry-after") or 3)))
        r.raise_for_status()
        body = r.json()
    for step in body.get("steps", []):
        for item in step.get("content", []):
            if item.get("data"):
                raw = base64.b64decode(item["data"])
                return _pcm_from_wav(raw) if raw[:4] == b"RIFF" else raw
    raise RuntimeError(f"Gemini returned no audio (status {body.get('status')})")


async def _openai(text: str) -> bytes:
    async with httpx.AsyncClient(timeout=60, headers={"Authorization": f"Bearer {settings.openai_api_key}"}) as http:
        r = await http.post(f"{settings.openai_base_url.rstrip('/')}/audio/speech", json={
            "model": "gpt-4o-mini-tts", "voice": settings.tts_voice, "input": text, "response_format": "pcm"})
        r.raise_for_status()
        return r.content   # 24 kHz 16-bit mono PCM


async def synthesize(text: str) -> bytes | None:
    """PCM for `text`, or None if no AI provider is configured or synthesis failed (the call carries on silently)."""
    text = text.strip()
    if not text or not settings.ai_provider:
        return None
    key = _key(text)
    if key in _memory:
        return _memory[key]
    path = _disk / f"{key}.pcm"
    try:
        if path.exists():
            _memory[key] = path.read_bytes()
            return _memory[key]
        pcm = await (_gemini(text) if settings.ai_provider == "gemini" else _openai(text))
        _memory[key] = pcm
        _disk.mkdir(parents=True, exist_ok=True)
        path.write_bytes(pcm)
        return pcm
    except Exception:  # noqa: BLE001 — a missing announcement must never break the call
        log.exception("speech synthesis failed for %r", text[:60])
        return None

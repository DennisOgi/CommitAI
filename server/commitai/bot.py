"""The Commit AI call bot (Pipecat + Daily).

One bot joins every call that needs it, as a silent, invisible participant:

* PSTN calls — it dials the GSM/landline number out of the Daily room
  (``start_dialout``), or receives a dial-in to a corporate number.
* Corporate calls — it starts the cloud recording, announces the recording
  disclosure once both sides are connected, and enables Daily's per-participant
  transcription so every line is attributed to the right speaker.
* While the call runs it watches the employee's lines and pushes a
  "commitment detected" app-message to the employee's phone in real time.
* Off-duty corporate dial-ins get a voicemail greeting and the message is
  transcribed and turned into a follow-up.
* When the call ends it posts each employee's speaker-labelled transcript to
  the API, which runs the full LLM extraction.

Personal app-to-GSM calls also use the bot, but only as a dialer: no
recording, no transcription, nothing stored.

Run by the API as ``python -m commitai.bot`` with BOT_CONFIG (JSON) in the env.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from datetime import datetime, timezone

import httpx
from loguru import logger
from pipecat.frames.frames import EndFrame, OutputAudioRawFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineTask
from pipecat.transports.daily.transport import (
    DailyDialinSettings,
    DailyOutputTransportMessageUrgentFrame,
    DailyParams,
    DailyTranscriptionSettings,
    DailyTransport,
)

from .config import settings
from . import voice
from .extractor import HeuristicExtractor

BOT_USER_ID = "commit-ai-bot"
VOICEMAIL_MAX_S = 90
DIALIN_RING_S = 30          # on-duty dial-in rings this long before going to voicemail
CONNECT_TIMEOUT_S = 90      # if the two sides never connect within this, the bot leaves


class CallBot:
    def __init__(self, cfg: dict) -> None:
        self.cfg = cfg
        self.call_id: str = cfg["call_id"]
        self.record: bool = cfg.get("record", False)
        self.voicemail_greeting: str | None = cfg.get("voicemail")
        self.employees: dict[str, str] = {e["user_id"]: e["call_id"] for e in cfg.get("employees", [])}
        self.participants: dict[str, str | None] = {}     # present now: participant id → app user id (None for PSTN legs)
        self.ever: dict[str, str | None] = {}             # everyone seen, so speaker labels survive hang-ups
        self.segments: list[tuple[str, str, int]] = []    # (participant id, text, offset ms)
        self.t0: float | None = None
        self.answered = False
        self.announced = False
        self.finished = False
        self.live = HeuristicExtractor(cfg.get("timezone", "Africa/Lagos"))
        self.api = httpx.AsyncClient(base_url=settings.public_url, timeout=30,
                                     headers={"X-Internal-Key": settings.internal_api_key})

        transcribe = self.transcribe = self.record or bool(self.voicemail_greeting)
        speaks = bool(settings.ai_provider and (cfg.get("disclosure") or self.voicemail_greeting or cfg.get("dialin")))
        dialin = cfg.get("dialin")
        self.transport = DailyTransport(
            cfg["room_url"], cfg["token"], "Commit AI",
            DailyParams(
                api_key=settings.daily_api_key,
                api_url=settings.daily_api_url,
                audio_in_enabled=False,          # Daily transcribes server-side; we don't pull raw audio
                audio_out_enabled=speaks,
                audio_out_sample_rate=voice.SAMPLE_RATE,
                camera_out_enabled=False,
                transcription_enabled=transcribe,
                transcription_settings=DailyTranscriptionSettings(
                    model=settings.transcription_model, language="en", profanity_filter=False,
                    extra={"interim_results": False, "smart_format": True}),
                dialin_settings=DailyDialinSettings(**dialin) if dialin else None,
            ),
        )
        # No TTS stage: the bot only says a few fixed phrases, synthesised up front (commitai/voice.py)
        # and played as raw audio.
        processors = [self.transport.input(), self.transport.output()]
        self.task = PipelineTask(Pipeline(processors), idle_timeout_secs=None)
        self.speaks = speaks
        self._wire()

    # ------------------------------------------------------------ events --
    def _wire(self) -> None:
        t = self.transport

        @t.event_handler("on_joined")
        async def on_joined(transport, _data):
            # Never linger: if the call never connects (no answer, a phone that failed to join),
            # leave instead of recording an empty room until it expires.
            asyncio.get_running_loop().call_later(CONNECT_TIMEOUT_S, lambda: asyncio.ensure_future(self._connect_timeout()))
            if self.record and self.cfg.get("keep_audio", True):   # personal calls: no audio kept
                stream_id, err = await transport.start_recording()
                if not err:
                    await self._post_event("recording_started", {"stream_id": stream_id})   # server resolves the real recording id
            dialout = self.cfg.get("dialout")
            if dialout:
                _, err = await transport.start_dialout(dialout)
                if err:
                    logger.error(f"dial-out failed: {err}")
                    await self.finish()

        @t.event_handler("on_participant_joined")
        async def on_participant_joined(transport, participant):
            info = participant.get("info", {})
            self.participants[participant["id"]] = info.get("userId")
            self.ever[participant["id"]] = info.get("userId")
            # Daily (via Pipecat) transcribes only participants on an explicit allow-list;
            # without this, recorded calls produce no transcript at all.
            if self.transcribe and info.get("userId") != BOT_USER_ID:
                await transport.capture_participant_transcription(participant["id"])
            await self._maybe_connected()

        @t.event_handler("on_participant_left")
        async def on_participant_left(_transport, participant, _reason):
            self.participants.pop(participant["id"], None)
            humans_left = [uid for uid in self.participants.values() if uid != BOT_USER_ID]
            if self.answered or self.voicemail_greeting or not humans_left:
                # A 1:1 call is over when either side hangs up; and a room nobody is in any more
                # (e.g. the other side never connected) must not keep a bot recording it.
                await self.finish()

        @t.event_handler("on_dialout_answered")
        async def on_dialout_answered(_transport, _data):
            await self._maybe_connected(force=True)

        @t.event_handler("on_dialout_error")
        async def on_dialout_error(_transport, data):
            logger.warning(f"dial-out error: {data}")
            await self.finish()

        @t.event_handler("on_dialout_stopped")
        async def on_dialout_stopped(_transport, _data):
            await self.finish()

        @t.event_handler("on_dialin_ready")
        async def on_dialin_ready(_transport, _cdr):
            logger.info("dial-in ready; PSTN caller is being connected")

        @t.event_handler("on_dialin_connected")
        async def on_dialin_connected(_transport, _data):
            if self.voicemail_greeting:
                await self._start_voicemail()
                return
            # On duty: the employee's phone is ringing. Don't leave the caller in silence,
            # and if nobody picks up, take a message instead of ringing forever.
            await self._say(self._hold_message())
            asyncio.get_running_loop().call_later(DIALIN_RING_S, lambda: asyncio.ensure_future(self._unanswered()))

        @t.event_handler("on_transcription_message")
        async def on_transcription_message(_transport, message):
            await self._on_transcript(message)

    async def _connect_timeout(self) -> None:
        if not self.answered and not self.voicemail_greeting and not self.finished:
            logger.info(f"call {self.call_id}: sides never connected within {CONNECT_TIMEOUT_S}s; leaving")
            await self.finish()

    async def _start_voicemail(self) -> None:
        self.t0 = time.monotonic()
        await self._say(self.voicemail_greeting + " " + (self.cfg.get("disclosure") or ""))
        asyncio.get_running_loop().call_later(VOICEMAIL_MAX_S, lambda: asyncio.ensure_future(self.finish()))

    async def _unanswered(self) -> None:
        """An on-duty dial-in nobody answered: switch to voicemail so the client can leave a message."""
        if self.answered or self.finished:
            return
        name = self.cfg.get("employee_name") or "your contact"
        self.voicemail_greeting = (f"Sorry, {name} can't take your call right now. "
                                   "Please leave a message after the tone and they'll get back to you.")
        self.record = True
        logger.info(f"dial-in for call {self.call_id} unanswered after {DIALIN_RING_S}s; taking a voicemail")
        await self._post_event("unanswered")
        await self._start_voicemail()

    async def _maybe_connected(self, force: bool = False) -> None:
        humans = [pid for pid, uid in self.participants.items() if uid != BOT_USER_ID]
        if self.answered or not (force or len(humans) >= 2):
            return
        self.answered = True
        self.t0 = time.monotonic()
        await self._post_event("answered")
        disclosure = self.cfg.get("disclosure")
        if disclosure and not self.announced:
            self.announced = True
            await self._say(disclosure)
            await self._post_event("consent_announced")

    async def _on_transcript(self, message: dict) -> None:
        pid = message.get("participantId")
        text = (message.get("text") or "").strip()
        if not pid or not text or self.ever.get(pid) == BOT_USER_ID:
            return
        raw = message.get("rawResponse") or {}
        if raw and not raw.get("is_final", True):
            return
        offset = int((time.monotonic() - (self.t0 or time.monotonic())) * 1000)
        self.segments.append((pid, text, offset))

        # Live captions for every employee on the call, labelled from their point of view.
        speaker_uid = self.ever.get(pid)
        for emp_pid, emp_uid in list(self.participants.items()):
            if emp_uid in self.employees:
                await self.task.queue_frame(DailyOutputTransportMessageUrgentFrame(
                    message={"type": "caption", "speaker": "employee" if speaker_uid == emp_uid else "client",
                             "text": text, "offset_ms": offset},
                    participant_id=emp_pid))

        # Live hint to the employee who just spoke.
        if speaker_uid in self.employees:
            for c in self.live.detect(text, "employee", offset, datetime.now(timezone.utc)):
                if c.confidence < 0.6:
                    continue
                await self.task.queue_frame(DailyOutputTransportMessageUrgentFrame(
                    message={"type": "commitment_detected", "title": c.title, "due_text": c.due_text,
                             "category": c.category, "quote": c.quote, "offset_ms": offset},
                    participant_id=pid))

    async def _say(self, text: str) -> None:
        if not (self.speaks and text and text.strip()):
            return
        pcm = await voice.synthesize(text)
        if pcm:
            await self.task.queue_frame(OutputAudioRawFrame(audio=pcm, sample_rate=voice.SAMPLE_RATE, num_channels=1))

    def _hold_message(self) -> str:
        return f"Thanks for calling. Connecting you to {self.cfg.get('employee_name') or 'your contact'} now."

    def _prefetch_speech(self) -> None:
        """Synthesise this call's phrases while it is still ringing, so they play without delay."""
        if not self.speaks:
            return
        phrases = [self.cfg.get("disclosure"), self.voicemail_greeting]
        if self.cfg.get("dialin"):
            phrases.append(self._hold_message())
        for text in filter(None, phrases):
            asyncio.ensure_future(voice.synthesize(text))

    # ------------------------------------------------------------ finish --
    async def finish(self) -> None:
        if self.finished:
            return
        self.finished = True
        logger.info(f"call {self.call_id} finished; {len(self.segments)} segments")
        try:
            if self.record and self.cfg.get("keep_audio", True):
                await self.transport.stop_recording()
            await self._post_event("ended")
            if self.record or self.voicemail_greeting:
                for employee_uid, call_id in self.employees.items():
                    segments = [{"speaker": "employee" if self.ever.get(pid) == employee_uid else "client",
                                 "text": text, "offset_ms": off} for pid, text, off in self.segments]
                    r = await self.api.post(f"/internal/calls/{call_id}/complete",
                                            json={"segments": segments, "voicemail": bool(self.voicemail_greeting)})
                    logger.info(f"posted transcript for {call_id}: {r.status_code}")
        except Exception:  # noqa: BLE001
            logger.exception("failed to post call results")
        finally:
            await self.task.queue_frame(EndFrame())

    async def _post_event(self, kind: str, data: dict | None = None) -> None:
        try:
            await self.api.post(f"/internal/calls/{self.call_id}/events", json={"kind": kind, "data": data or {}})
        except httpx.HTTPError as e:
            logger.warning(f"event {kind} not delivered: {e}")

    async def run(self) -> None:
        self._prefetch_speech()
        await PipelineRunner(handle_sigint=False).run(self.task)


async def main() -> None:
    cfg = json.loads(os.environ["BOT_CONFIG"])
    logger.remove()
    logger.add(sys.stderr, level=os.getenv("BOT_LOG_LEVEL", "INFO"))
    bot = CallBot(cfg)
    await bot.run()


if __name__ == "__main__":
    asyncio.run(main())

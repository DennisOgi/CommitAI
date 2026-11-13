"""Starts one bot process per call.

Locally this is a subprocess. In production point ``spawn`` at Pipecat Cloud
(or any worker pool) instead — the bot only needs BOT_CONFIG and the env.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys

log = logging.getLogger(__name__)
_running: dict[str, asyncio.subprocess.Process] = {}


async def spawn(cfg: dict) -> None:
    env = {**os.environ, "BOT_CONFIG": json.dumps(cfg)}
    proc = await asyncio.create_subprocess_exec(sys.executable, "-m", "commitai.bot", env=env)
    _running[cfg["call_id"]] = proc
    log.info("bot pid=%s started for call %s", proc.pid, cfg["call_id"])

    async def reap() -> None:
        code = await proc.wait()
        _running.pop(cfg["call_id"], None)
        log.info("bot for call %s exited (%s)", cfg["call_id"], code)

    asyncio.create_task(reap())


def running() -> list[str]:
    return list(_running)

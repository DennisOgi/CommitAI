"""Thin Daily REST client: rooms, meeting tokens, recordings.

Without DAILY_API_KEY it returns fake rooms so the rest of the stack (and the
app's demo mode) still works end to end.
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass

import httpx

from .config import settings


@dataclass
class Room:
    name: str
    url: str


class DailyClient:
    def __init__(self, api_key: str = settings.daily_api_key, api_url: str = settings.daily_api_url) -> None:
        self.enabled = bool(api_key)
        self._http = httpx.AsyncClient(base_url=api_url, timeout=15,
                                       headers={"Authorization": f"Bearer {api_key}"})

    async def create_room(self, *, dialout: bool = False, record: bool = False,
                          sip_dialin: bool = False, ttl_s: int = 3 * 3600) -> Room:
        name = f"commit-{uuid.uuid4().hex[:12]}"
        if not self.enabled:
            return Room(name, f"https://demo.daily.co/{name}")
        props: dict = {
            "exp": int(time.time()) + ttl_s,
            "eject_at_room_exp": True,
            "max_participants": 6,
            "start_video_off": True,          # voice-first product
            "enable_prejoin_ui": False,
            "enable_chat": False,
            "enable_dialout": dialout,
        }
        if record:
            props["enable_recording"] = settings.daily_recording_type
        if sip_dialin:
            # Pinless dial-in: Daily holds the PSTN leg until our bot joins and forwards it in.
            props["sip"] = {"display_name": "client", "sip_mode": "dial-in", "num_endpoints": 1}
        r = await self._http.post("/rooms", json={"name": name, "privacy": "private", "properties": props})
        r.raise_for_status()
        data = r.json()
        return Room(data["name"], data["url"])

    async def token(self, room: str, *, user_id: str, user_name: str, owner: bool = False,
                    ttl_s: int = 3 * 3600) -> str:
        if not self.enabled:
            return f"demo-token-{user_id}"
        r = await self._http.post("/meeting-tokens", json={"properties": {
            "room_name": room,
            "user_id": user_id,
            "user_name": user_name,
            "is_owner": owner,
            "exp": int(time.time()) + ttl_s,
            "start_video_off": True,
        }})
        r.raise_for_status()
        return r.json()["token"]

    async def recording_for_room(self, room: str) -> str | None:
        """The real Daily recording id for a room (newest). The id a bot gets back when it starts a
        recording is a stream id, not the recording id, so we always resolve it here."""
        if not self.enabled or not room:
            return None
        r = await self._http.get("/recordings", params={"room_name": room, "limit": 5})
        if r.status_code != 200:
            return None
        rows = sorted(r.json().get("data", []), key=lambda x: x.get("start_ts") or 0, reverse=True)
        return rows[0]["id"] if rows else None

    async def recording_link(self, recording_id: str) -> str | None:
        if not self.enabled or not recording_id:
            return None
        r = await self._http.get(f"/recordings/{recording_id}/access-link")
        if r.status_code != 200:
            return None
        return r.json().get("download_link")

    async def delete_room(self, room: str) -> None:
        if self.enabled:
            await self._http.delete(f"/rooms/{room}")


daily = DailyClient()

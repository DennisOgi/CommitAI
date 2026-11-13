"""Push delivery (FCM HTTP v1). Ring payloads are data-only so the app's
background handler can show the native incoming-call UI (CallKit / Android
full-screen intent) through flutter_callkit_incoming.

If FCM isn't configured, pushes are logged and kept in ``outbox`` so the demo
and tests can see what would have been sent.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import httpx

from .config import settings

log = logging.getLogger(__name__)
outbox: list[dict[str, Any]] = []


class Pusher:
    def __init__(self) -> None:
        self._creds = None
        if settings.fcm_project_id and settings.fcm_service_account_file:
            try:
                from google.oauth2 import service_account

                self._creds = service_account.Credentials.from_service_account_file(
                    settings.fcm_service_account_file,
                    scopes=["https://www.googleapis.com/auth/firebase.messaging"],
                )
            except Exception:  # noqa: BLE001
                log.exception("FCM credentials could not be loaded; pushes will only be logged")

    async def _access_token(self) -> str | None:
        if not self._creds:
            return None
        from google.auth.transport.requests import Request

        if not self._creds.valid:
            self._creds.refresh(Request())
        return self._creds.token

    async def send(self, tokens: list[str], *, data: dict[str, str], title: str | None = None,
                   body: str | None = None, high_priority: bool = False) -> None:
        outbox.append({"tokens": tokens, "data": data, "title": title, "body": body})
        access = await self._access_token()
        if not access:
            log.info("push (not sent, FCM off) → %s %s", title or data.get("type"), json.dumps(data)[:200])
            return
        url = f"https://fcm.googleapis.com/v1/projects/{settings.fcm_project_id}/messages:send"
        async with httpx.AsyncClient(timeout=10) as http:
            for token in tokens:
                message: dict[str, Any] = {"token": token, "data": data,
                                           "android": {"priority": "high" if high_priority else "normal"},
                                           "apns": {"headers": {"apns-priority": "10" if high_priority else "5"}}}
                if title:
                    message["notification"] = {"title": title, "body": body or ""}
                r = await http.post(url, json={"message": message},
                                    headers={"Authorization": f"Bearer {access}"})
                if r.status_code >= 400:
                    log.warning("FCM send failed (%s): %s", r.status_code, r.text[:300])


pusher = Pusher()

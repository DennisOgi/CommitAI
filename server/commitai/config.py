"""Runtime configuration, read once from the environment (.env supported)."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path


def _load_dotenv() -> None:
    env = Path(__file__).resolve().parent.parent / ".env"
    if not env.exists():
        return
    for line in env.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if value[:1] in ("'", '"') and value[0] in value[1:]:
            value = value[1:value.index(value[0], 1)]      # quoted: keep everything inside
        else:
            value = "" if value.startswith("#") else re.split(r"\s+#", value, maxsplit=1)[0].strip()
        os.environ.setdefault(key.strip(), value)


_load_dotenv()


def _bool(name: str, default: bool) -> bool:
    return os.getenv(name, str(default)).lower() in {"1", "true", "yes", "on"}


_DEFAULT_INTERNAL_KEY = "dev-internal-key-change-me-in-production"
APP_ENV = os.getenv("APP_ENV", "development").lower()
IS_PRODUCTION = APP_ENV in {"prod", "production"}


def _list(name: str, default: str = "") -> list[str]:
    return [x.strip() for x in os.getenv(name, default).split(",") if x.strip()]


@dataclass(frozen=True)
class Settings:
    app_env: str = APP_ENV
    log_level: str = os.getenv("LOG_LEVEL", "INFO").upper()
    # Browser origins allowed to call the API (mobile apps don't need CORS). "*" only in development.
    cors_origins: list = field(default_factory=lambda: _list("CORS_ORIGINS", "" if IS_PRODUCTION else "*"))

    # Public base URL of this API (used for webhooks the bot calls back into).
    public_url: str = os.getenv("PUBLIC_URL", "http://localhost:8000")
    # Shared secret for Daily pinless dial-in webhook signatures (base64, from Daily's pinless_dialin "hmac").
    daily_dialin_hmac: str = os.getenv("DAILY_DIALIN_HMAC", "")

    # Daily
    daily_api_key: str = os.getenv("DAILY_API_KEY", "")
    daily_api_url: str = os.getenv("DAILY_API_URL", "https://api.daily.co/v1")
    # Purchased Daily number used as caller ID for dial-out (Daily "phone number id" or E.164).
    daily_caller_id: str = os.getenv("DAILY_CALLER_ID", "")
    # "cloud" | "cloud-audio-only" | "raw-tracks" depending on your Daily plan.
    daily_recording_type: str = os.getenv("DAILY_RECORDING_TYPE", "cloud")
    transcription_model: str = os.getenv("DAILY_TRANSCRIPTION_MODEL", "nova-3-general")

    # AI provider for commitment extraction and the bot's spoken announcements.
    # "gemini" (default) or "openai". Empty = whichever has a key, Gemini first.
    ai_provider_setting: str = os.getenv("AI_PROVIDER", "").lower()

    # Google Gemini (https://aistudio.google.com/apikey).
    gemini_api_key: str = os.getenv("GEMINI_API_KEY", "")
    gemini_base_url: str = os.getenv("GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta")
    gemini_model: str = os.getenv("GEMINI_MODEL", "gemini-3.5-flash-lite")
    gemini_tts_model: str = os.getenv("GEMINI_TTS_MODEL", "gemini-3.8-flash-lite-tts")
    gemini_tts_voice: str = os.getenv("GEMINI_TTS_VOICE", "Kore")

    # OpenAI (or any OpenAI-compatible endpoint) — optional alternative.
    openai_api_key: str = os.getenv("OPENAI_API_KEY", "")
    openai_base_url: str = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
    extraction_model: str = os.getenv("EXTRACTION_MODEL", "gpt-4.1")
    tts_voice: str = os.getenv("TTS_VOICE", "alloy")

    # Supabase (service role — server side only). Empty = in-memory demo store.
    supabase_url: str = os.getenv("SUPABASE_URL", "")
    supabase_service_key: str = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
    supabase_jwt_secret: str = os.getenv("SUPABASE_JWT_SECRET", "")

    # Shared secret the bot uses to post results back to the API.
    internal_api_key: str = os.getenv("INTERNAL_API_KEY", _DEFAULT_INTERNAL_KEY)
    # Accept "Bearer dev:<user_id>" tokens. Never enable in production.
    dev_auth: bool = _bool("DEV_AUTH", not IS_PRODUCTION)
    # Spawn the Pipecat bot for each call. Off = calls work but nothing is extracted.
    bots_enabled: bool = _bool("BOTS_ENABLED", True)

    # Firebase Cloud Messaging (HTTP v1) for ringing devices.
    fcm_project_id: str = os.getenv("FCM_PROJECT_ID", "")
    fcm_service_account_file: str = os.getenv("FCM_SERVICE_ACCOUNT_FILE", "")

    reminder_lead_hours: int = int(os.getenv("REMINDER_LEAD_HOURS", "24"))
    scheduler_interval_s: int = int(os.getenv("SCHEDULER_INTERVAL_S", "300"))

    extra: dict = field(default_factory=dict)

    @property
    def use_supabase(self) -> bool:
        return bool(self.supabase_url and self.supabase_service_key)

    # Corporate login brute-force protection: attempts per window, per user and per IP.
    login_max_attempts: int = int(os.getenv("LOGIN_MAX_ATTEMPTS", "5"))
    login_window_s: int = int(os.getenv("LOGIN_WINDOW_S", "900"))
    # App calls nobody answers are marked missed after this many seconds.
    ring_timeout_s: int = int(os.getenv("RING_TIMEOUT_S", "60"))

    @property
    def is_production(self) -> bool:
        return self.app_env in {"prod", "production"}

    @property
    def ai_provider(self) -> str | None:
        """The provider in use: the one AI_PROVIDER names (if it has a key), else Gemini, else OpenAI."""
        keys = {"gemini": self.gemini_api_key, "openai": self.openai_api_key}
        if self.ai_provider_setting in keys:
            return self.ai_provider_setting if keys[self.ai_provider_setting] else None
        return next((p for p in ("gemini", "openai") if keys[p]), None)

    @property
    def llm_enabled(self) -> bool:
        return self.ai_provider is not None

    def problems(self) -> list[str]:
        """Settings that make a production deployment unsafe."""
        out = []
        if not self.is_production:
            return out
        if self.dev_auth:
            out.append("DEV_AUTH must be false in production")
        if self.internal_api_key == _DEFAULT_INTERNAL_KEY or len(self.internal_api_key) < 32:
            out.append("INTERNAL_API_KEY must be set to a random string of 32+ characters")
        if not self.use_supabase:
            out.append("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required (the in-memory store loses data)")
        if not self.public_url.startswith("https://"):
            out.append("PUBLIC_URL must be an https:// URL")
        if "*" in self.cors_origins:
            out.append("CORS_ORIGINS must not be '*'")
        return out


settings = Settings()

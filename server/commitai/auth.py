"""Request authentication.

* App users send their Supabase access token (``Authorization: Bearer <jwt>``).
  HS256 projects verify with SUPABASE_JWT_SECRET; projects on asymmetric
  signing keys verify against the project's JWKS.
* In dev (DEV_AUTH=true) ``Bearer dev:<user_id>`` is accepted.
* Corporate sessions are short-lived signed tokens minted at corporate login.
  Switching back to corporate mode within the window needs no re-login
  (the app gates it behind device biometrics instead).
"""

from __future__ import annotations

import hmac
import time
from functools import lru_cache

import bcrypt
import jwt
from fastapi import Depends, Header, HTTPException

from .config import settings

CORP_SESSION_TTL_S = 12 * 3600


@lru_cache(maxsize=1)
def _jwks() -> jwt.PyJWKClient:
    return jwt.PyJWKClient(f"{settings.supabase_url.rstrip('/')}/auth/v1/.well-known/jwks.json")


def verify_user_token(token: str) -> str:
    if settings.dev_auth and token.startswith("dev:"):
        return token[4:]
    try:
        if settings.supabase_jwt_secret:
            claims = jwt.decode(token, settings.supabase_jwt_secret, algorithms=["HS256"], audience="authenticated")
        else:
            key = _jwks().get_signing_key_from_jwt(token)
            claims = jwt.decode(token, key.key, algorithms=["ES256", "RS256"], audience="authenticated")
    except (jwt.PyJWTError, jwt.PyJWKClientError) as e:
        raise HTTPException(401, "invalid or expired session — sign in again") from e
    sub = claims.get("sub")
    if not sub:
        raise HTTPException(401, "invalid token")
    return sub


async def current_user(authorization: str = Header(default="")) -> str:
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    return verify_user_token(authorization[7:].strip())


async def internal_only(x_internal_key: str = Header(default="")) -> None:
    if not hmac.compare_digest(x_internal_key.encode(), settings.internal_api_key.encode()):
        raise HTTPException(403, "internal endpoint")


CurrentUser = Depends(current_user)
InternalOnly = Depends(internal_only)


def hash_pin(pin: str) -> str:
    return bcrypt.hashpw(pin.encode(), bcrypt.gensalt()).decode()


def check_pin(pin: str, pin_hash: str | None) -> bool:
    if not pin_hash:
        return False
    try:
        return bcrypt.checkpw(pin.encode(), pin_hash.encode())
    except ValueError:
        return False


def mint_corp_session(user_id: str, membership_id: str) -> str:
    now = int(time.time())
    return jwt.encode({"sub": user_id, "mid": membership_id, "iat": now, "exp": now + CORP_SESSION_TTL_S,
                       "typ": "corp"}, settings.internal_api_key, algorithm="HS256")


def read_corp_session(token: str, user_id: str) -> str:
    try:
        claims = jwt.decode(token, settings.internal_api_key, algorithms=["HS256"])
    except jwt.PyJWTError as e:
        raise HTTPException(401, "corporate session expired — sign in with your corporate ID again") from e
    if claims.get("sub") != user_id or claims.get("typ") != "corp":
        raise HTTPException(401, "corporate session does not belong to this user")
    return claims["mid"]

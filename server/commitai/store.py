"""A deliberately small data-access layer.

Business logic only needs four operations (select / insert / update / delete
with equality filters), so the same code runs against:

* ``MemoryStore`` — zero-setup demo + tests, seeded with a sample company.
* ``SupabaseStore`` — PostgREST with the service-role key, matching the
  schema in ``supabase/migrations``.
"""

from __future__ import annotations

import copy
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from typing import Any

import httpx

Row = dict[str, Any]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class Store(ABC):
    @abstractmethod
    async def select(self, table: str, *, order: str | None = None, desc: bool = False,
                     limit: int | None = None, in_: dict[str, list] | None = None,
                     contains: dict[str, str] | None = None, **eq: Any) -> list[Row]: ...
    # contains: case-insensitive substring match per column (e.g. {"full_name": "ada"}).

    @abstractmethod
    async def insert(self, table: str, row: Row | list[Row]) -> list[Row]: ...

    @abstractmethod
    async def update(self, table: str, patch: Row, **eq: Any) -> list[Row]: ...

    @abstractmethod
    async def delete(self, table: str, **eq: Any) -> None: ...

    async def get(self, table: str, **eq: Any) -> Row | None:
        rows = await self.select(table, limit=1, **eq)
        return rows[0] if rows else None

    async def upsert(self, table: str, row: Row, key: str) -> Row:
        existing = await self.get(table, **{key: row[key]})
        if existing:
            return (await self.update(table, row, **{key: row[key]}))[0]
        return (await self.insert(table, row))[0]


# Columns Postgres would fill in for us.
_DEFAULTS: dict[str, dict[str, Any]] = {
    "calls": {"status": "ringing", "processing": "not_applicable", "consent_announced": False},
    "commitments": {"status": "pending_review", "owner": "employee", "category": "other",
                    "priority": "medium", "confidence": 0.8, "confirmed_by_employee": False},
}
_IDENTITY = {"transcript_segments", "commitment_events"}


class MemoryStore(Store):
    def __init__(self) -> None:
        self.tables: dict[str, list[Row]] = {}
        self._seq = 0

    def _t(self, table: str) -> list[Row]:
        return self.tables.setdefault(table, [])

    async def select(self, table, *, order=None, desc=False, limit=None, in_=None, contains=None, **eq):
        rows = [r for r in self._t(table)
                if all(str(v).lower() in str(r.get(k) or "").lower() for k, v in (contains or {}).items())]
        rows = [r for r in rows
                if all(r.get(k) == v for k, v in eq.items())
                and all(r.get(k) in vs for k, vs in (in_ or {}).items())]
        if order:
            present = [r for r in rows if r.get(order) is not None]
            present.sort(key=lambda r: r[order], reverse=desc)
            rows = present + [r for r in rows if r.get(order) is None]
        if limit:
            rows = rows[:limit]
        return copy.deepcopy(rows)

    async def insert(self, table, row):
        rows = row if isinstance(row, list) else [row]
        out = []
        for r in rows:
            r = {**_DEFAULTS.get(table, {}), **r}
            if table in _IDENTITY:
                self._seq += 1
                r.setdefault("id", self._seq)
            else:
                r.setdefault("id", str(uuid.uuid4()))
            r.setdefault("created_at", now_iso())
            if table == "commitments":
                r.setdefault("updated_at", r["created_at"])
            self._t(table).append(r)
            out.append(copy.deepcopy(r))
        return out

    async def update(self, table, patch, **eq):
        out = []
        for r in self._t(table):
            if all(r.get(k) == v for k, v in eq.items()):
                r.update(patch)
                if table == "commitments":
                    r["updated_at"] = now_iso()
                out.append(copy.deepcopy(r))
        return out

    async def delete(self, table, **eq):
        self.tables[table] = [r for r in self._t(table)
                              if not all(r.get(k) == v for k, v in eq.items())]


class SupabaseStore(Store):
    def __init__(self, url: str, service_key: str) -> None:
        self._http = httpx.AsyncClient(
            base_url=f"{url.rstrip('/')}/rest/v1",
            headers={"apikey": service_key, "Authorization": f"Bearer {service_key}",
                     "Prefer": "return=representation"},
            timeout=15,
        )

    @staticmethod
    def _filters(eq: dict, in_: dict | None) -> dict[str, str]:
        params = {k: ("is.null" if v is None else f"eq.{str(v).lower() if isinstance(v, bool) else v}")
                  for k, v in eq.items()}
        for k, vs in (in_ or {}).items():
            # Quote each value so commas, dots or brackets inside one can't break the list.
            quoted = ('"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"' for v in vs)
            params[k] = "in.(" + ",".join(quoted) + ")"
        return params

    async def select(self, table, *, order=None, desc=False, limit=None, in_=None, contains=None, **eq):
        params = self._filters(eq, in_)
        for k, v in (contains or {}).items():
            # PostgREST ilike; strip characters that have meaning in its filter syntax.
            safe = "".join(ch for ch in v if ch not in "*%,()\\\"")
            params[k] = f"ilike.*{safe}*"
        params["select"] = "*"
        if order:
            params["order"] = f"{order}.{'desc' if desc else 'asc'}.nullslast"
        if limit:
            params["limit"] = str(limit)
        r = await self._http.get(f"/{table}", params=params)
        r.raise_for_status()
        return r.json()

    async def insert(self, table, row):
        r = await self._http.post(f"/{table}", json=row)
        r.raise_for_status()
        return r.json()

    async def update(self, table, patch, **eq):
        r = await self._http.patch(f"/{table}", params=self._filters(eq, None), json=patch)
        r.raise_for_status()
        return r.json()

    async def delete(self, table, **eq):
        r = await self._http.delete(f"/{table}", params=self._filters(eq, None))
        r.raise_for_status()


def make_store() -> Store:
    from .config import settings

    if settings.use_supabase:
        return SupabaseStore(settings.supabase_url, settings.supabase_service_key)
    from .seed import seed_memory_store

    store = MemoryStore()
    seed_memory_store(store)
    return store

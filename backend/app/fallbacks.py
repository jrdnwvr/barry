"""Every answer that came from a fallback instead of the NOAA feeds on
Tower, kept so the month before the fallbacks are removed (NOAA.md phase
7) is measured rather than assumed.

What counts: the point forecast, the Aloft column, the radar's wind grid
and its winds aloft answered by Open-Meteo instead of the HRRR and NBM
store; the radar timeline answered by RainViewer instead of Barry's own
MRMS frames; and the observed pressure curve answered by Open-Meteo's
surface pressure when AWC fails. Each carries why: `off-grid` (the point
lies outside the HRRR domain, which is expected and not a defect),
`no-data` (the store holds nothing for it, or nothing at all), `stale`
(radar frames held but old), `off` (the feed is switched off by
configuration), `upstream` (AWC failed). And where: a station, or a
point to a tenth of a degree.

Every occurrence counts on /metrics (`barry_fallbacks_total`); the log
keeps one event per kind, reason and place every ten minutes, 60 days,
written to disk by the scheduler once a cycle. `/fallbacks` sums it by
day and lists the newest events.
"""

from __future__ import annotations

import threading
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

from . import metrics, persist

KINDS = ("forecast", "aloft", "field", "levels", "radar", "pressure")
REASONS = ("off-grid", "no-data", "stale", "off", "upstream")
DEDUPE_S = 600.0
KEEP_DAYS = 60
RECENT = 40
STORE = "fallbacks"


class Log:
    def __init__(self) -> None:
        self._events: Optional[List[dict]] = None
        self._last: Dict[tuple, float] = {}
        self._dirty = False
        self._lock = threading.Lock()

    def _load(self) -> List[dict]:
        if self._events is None:
            self._events = persist.load(STORE) or []
        return self._events

    def note(self, kind: str, reason: str, where: str, now: datetime) -> bool:
        """Count the occurrence; keep it as an event unless the same kind,
        reason and place was kept in the last ten minutes. Returns whether
        an event was kept."""
        metrics.inc("barry_fallbacks_total", kind, reason)
        key = (kind, reason, where)
        t = now.timestamp()
        with self._lock:
            if t - self._last.get(key, 0.0) < DEDUPE_S:
                return False
            self._last[key] = t
            self._load().append({"t": now.isoformat(), "kind": kind, "reason": reason, "where": where})
            self._dirty = True
        return True

    def flush(self, now: datetime) -> bool:
        """Prune to KEEP_DAYS and write when anything changed."""
        with self._lock:
            events = self._load()
            cut = (now - timedelta(days=KEEP_DAYS)).isoformat()
            kept = [e for e in events if e.get("t", "") >= cut]
            if not self._dirty and len(kept) == len(events):
                return False
            self._events = kept
            self._dirty = False
            snapshot = list(kept)
        persist.save(STORE, snapshot)
        return True

    def events(self) -> List[dict]:
        with self._lock:
            return list(self._load())

    def summary(self, days: int = 14, now: Optional[datetime] = None) -> dict:
        """By UTC day, newest first: events, and how many of each kind for
        each reason; then the newest events."""
        events = self.events()
        by_day: Dict[str, List[dict]] = {}
        for e in events:
            by_day.setdefault(e["t"][:10], []).append(e)
        out_days = []
        for day in sorted(by_day, reverse=True)[:days]:
            rows = by_day[day]
            kinds: Dict[str, Dict[str, int]] = {}
            for e in rows:
                kinds.setdefault(e["kind"], {})
                kinds[e["kind"]][e["reason"]] = kinds[e["kind"]].get(e["reason"], 0) + 1
            out_days.append({"day": day, "events": len(rows), "byKind": kinds})
        recent = sorted(events, key=lambda e: e["t"], reverse=True)[:RECENT]
        return {"days": out_days, "recent": recent, "total": len(events),
                "asOf": (now or datetime.now(timezone.utc)).isoformat()}

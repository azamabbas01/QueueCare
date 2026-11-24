from collections import OrderedDict
from math import ceil
from threading import Lock
from time import monotonic


class FixedWindowRateLimiter:
    """Small bounded process-local limiter for public auth endpoints."""

    def __init__(self, max_keys: int = 20_000) -> None:
        self._max_keys = max_keys
        self._windows: OrderedDict[str, tuple[float, int]] = OrderedDict()
        self._lock = Lock()
        self._checks = 0

    def consume(
        self,
        key: str,
        *,
        limit: int,
        window_seconds: int,
        now: float | None = None,
    ) -> tuple[bool, int]:
        current = monotonic() if now is None else now
        with self._lock:
            self._checks += 1
            if self._checks % 64 == 0:
                self._prune(current)

            entry = self._windows.get(key)
            if entry is None or current - entry[0] >= window_seconds:
                if entry is None and len(self._windows) >= self._max_keys:
                    self._windows.popitem(last=False)
                self._windows[key] = (current, 1)
                self._windows.move_to_end(key)
                return True, 0

            started, count = entry
            self._windows.move_to_end(key)
            if count >= limit:
                return False, max(1, ceil(started + window_seconds - current))

            self._windows[key] = (started, count + 1)
            return True, 0

    def blocked(self, key: str, *, limit: int, window_seconds: int, now: float | None = None) -> int:
        """Seconds left if ``key`` already used up ``limit`` hits in the window, else 0."""
        current = monotonic() if now is None else now
        with self._lock:
            entry = self._windows.get(key)
            if entry is None or current - entry[0] >= window_seconds:
                return 0
            started, count = entry
            return max(1, ceil(started + window_seconds - current)) if count >= limit else 0

    def reset(self, key: str) -> None:
        with self._lock:
            self._windows.pop(key, None)

    def _prune(self, now: float) -> None:
        expired = [
            key
            for key, (started, _) in self._windows.items()
            if now - started >= 3600
        ]
        for key in expired:
            self._windows.pop(key, None)

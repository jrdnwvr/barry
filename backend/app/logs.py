"""One line of JSON per log record, carrying the request id when there is
one. Nothing here adds a per-request line: the access log stays off, and
what gets logged is what the code chose to log. Set BARRY_LOG_JSON=0 for
the plain format in a terminal."""

from __future__ import annotations

import json
import logging
import os
from contextvars import ContextVar
from datetime import datetime, timezone

request_id: ContextVar[str] = ContextVar("barry_request_id", default="-")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        d = {
            "t": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        rid = request_id.get()
        if rid != "-":
            d["rid"] = rid
        if record.exc_info:
            d["exc"] = self.formatException(record.exc_info)
        return json.dumps(d, ensure_ascii=False)


def configure() -> None:
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    if os.environ.get("BARRY_LOG_JSON", "1") == "0":
        logging.basicConfig(level=logging.INFO)
        return
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root.handlers[:] = [handler]

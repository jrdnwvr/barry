"""Counters, the request id, structured log lines, and who may read /metrics."""
import json
import logging

import httpx
import pytest

from app import logs, metrics
from app.service import PressureService


@pytest.fixture
async def api(client):
    from app.main import app
    metrics.reset()
    app.state.service = PressureService(client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False, client=("127.0.0.1", 1)),
                                 base_url="http://t") as c:
        yield c


@pytest.mark.asyncio
async def test_requests_are_counted_by_template_never_by_path(api, upstream):
    await api.get("/pressure/KLUK")
    await api.get("/pressure/KLUK")          # served from the cache
    await api.get("/pressure/KCVG")
    await api.get("/pressure/K1")            # 422
    await api.get("/nothing/here")
    text = (await api.get("/metrics")).text
    assert 'barry_requests_total{route="/pressure/{station}",status="200"} 3' in text
    assert 'barry_requests_total{route="/pressure/{station}",status="422"} 1' in text
    assert 'barry_requests_total{route="unmatched",status="404"} 1' in text
    assert "KLUK" not in text and "KCVG" not in text
    assert 'barry_cache_total{outcome="hit"}' in text and 'barry_cache_total{outcome="miss"}' in text
    assert "barry_rss_bytes" in text and "barry_cache_entries" in text


@pytest.mark.asyncio
async def test_metrics_answer_only_the_box_itself(client):
    from app.main import app
    app.state.service = PressureService(client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False, client=("127.0.0.1", 1)),
                                 base_url="http://t") as c:
        assert (await c.get("/metrics")).status_code == 200
        r = await c.get("/metrics", headers={"CF-Connecting-IP": "203.0.113.9"})   # through the tunnel
        assert r.status_code == 404 and r.json() == {"detail": "Not Found"}
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False, client=("8.8.8.8", 1)),
                                 base_url="http://t") as c:
        assert (await c.get("/metrics")).status_code == 404


@pytest.mark.asyncio
async def test_every_response_carries_a_request_id_and_log_lines_carry_it(api, caplog):
    r = await api.get("/pressure/KLUK")
    rid = r.headers["x-request-id"]
    assert len(rid) == 12
    assert (await api.get("/pressure/KLUK")).headers["x-request-id"] != rid
    # A log record written inside a request has the id; one outside does not.
    fmt = logs.JsonFormatter()
    token = logs.request_id.set("abc123")
    try:
        rec = logging.LogRecord("barry.test", logging.WARNING, __file__, 1, "pressure %s failed", ("KLUK",), None)
        line = json.loads(fmt.format(rec))
        assert line["rid"] == "abc123" and line["msg"] == "pressure KLUK failed" and line["level"] == "WARNING"
    finally:
        logs.request_id.reset(token)
    assert "rid" not in json.loads(fmt.format(rec))


def test_render_is_prometheus_text():
    metrics.reset()
    metrics.inc("barry_upstream_requests_total", "aviationweather.gov")
    metrics.inc("barry_upstream_requests_total", "aviationweather.gov")
    metrics.inc("barry_upstream_responses_total", "aviationweather.gov", metrics.status_class(503))
    metrics.gauge("barry_scheduler_cycle_seconds", 1.25)
    text = metrics.render()
    assert "# TYPE barry_upstream_requests_total counter" in text
    assert 'barry_upstream_requests_total{host="aviationweather.gov"} 2' in text
    assert 'barry_upstream_responses_total{host="aviationweather.gov",status="5xx"} 1' in text
    assert "barry_scheduler_cycle_seconds 1.25" in text
    assert text.endswith("\n")

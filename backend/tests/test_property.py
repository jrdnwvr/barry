"""Every route, fed from its own schema and from junk: never a 500, never
more than a handful of upstream calls for one request, never a body the
phone could not hold, and the cache never past its cap. The strategies
are built from the OpenAPI document the app generates, so a new parameter
is covered the day it is added."""
from __future__ import annotations

import asyncio

import httpx
from hypothesis import HealthCheck, given, settings, strategies as st

from app.guards import IPLimiter
from app.main import app
from app.service import PressureService
from conftest import FakeUpstream

SPEC = app.openapi()
ROUTES = [(path, [(p["name"], p["in"], p["required"], p.get("schema", {}))
                  for p in op.get("parameters", [])])
          for path, ops in SPEC["paths"].items() for m, op in ops.items() if m == "get"]
OK_STATUSES = {200, 400, 404, 422, 429, 503}
MAX_BODY = 3_000_000
MAX_UPSTREAM_PER_REQUEST = 8

JUNK = st.one_of(
    st.sampled_from(["", "inf", "-inf", "nan", "-0", "1e400", "1e-320", "0x10", "1_0", " 1", "1 ", "٣", "true", "null"]),
    st.text(max_size=8),
    st.integers(min_value=-10**12, max_value=10**12).map(str),
    st.floats(allow_nan=True, allow_infinity=True).map(repr),
)
PATH_SAFE = st.characters(min_codepoint=32, max_codepoint=126, blacklist_characters="/?#")


def _unwrap(schema: dict) -> dict:
    if "anyOf" in schema:
        return next((x for x in schema["anyOf"] if x.get("type") != "null"), {})
    return schema


def _valid(schema: dict):
    sch = _unwrap(schema)
    t = sch.get("type")
    if t == "number":
        lo = sch.get("minimum", sch.get("exclusiveMinimum", -1e6))
        hi = sch.get("maximum", 1e6)
        return st.floats(min_value=lo, max_value=hi, allow_nan=False, allow_infinity=False).map(repr)
    if t == "integer":
        return st.integers(min_value=int(sch.get("minimum", -1000)), max_value=int(sch.get("maximum", 1000))).map(str)
    if t == "boolean":
        return st.sampled_from(["true", "false", "1", "0"])
    return st.one_of(st.sampled_from(["KLUK", "KCVG", "CVG", "I67", "K1", "KLUK,KCVG"]),
                     st.text(alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", min_size=1, max_size=5))


@st.composite
def one_request(draw):
    path, params = draw(st.sampled_from(ROUTES))
    query = {}
    for name, where, required, schema in params:
        value = draw(st.one_of(_valid(schema), _valid(schema), JUNK))
        if where == "path":
            if any(c in value for c in "/?#") or not value.isprintable():
                value = draw(st.text(alphabet=PATH_SAFE, max_size=8))
            path = path.replace("{" + name + "}", value)
        elif required or draw(st.booleans()):
            query[name] = value
    return path, query


async def _run(reqs):
    upstream = FakeUpstream()
    total = 0

    def counted(request):
        nonlocal total
        total += 1
        return upstream.handler(request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(counted), timeout=5.0) as client:
        service = PressureService(client)
        app.state.service = service
        app.state.ip_limiter = IPLimiter(per_minute=0)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
                                     base_url="http://t") as c:
            for path, query in reqs:
                before = total
                r = await c.get(path, params=query)
                assert r.status_code in OK_STATUSES, (path, query, r.status_code, r.text[:200])
                assert len(r.content) <= MAX_BODY, (path, query, len(r.content))
                assert total - before <= MAX_UPSTREAM_PER_REQUEST, (path, query, total - before)
                if r.status_code != 200 and path != "/healthz":
                    assert "detail" in r.json(), (path, query, r.text[:200])
        cap = getattr(service.cache, "_max_entries", 5000)
        assert len(service.cache._store) <= cap


@settings(max_examples=120, deadline=None, suppress_health_check=[HealthCheck.too_slow])
@given(reqs=st.lists(one_request(), min_size=1, max_size=5))
def test_any_request_sequence_is_safe(reqs):
    asyncio.run(_run(reqs))

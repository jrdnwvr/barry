"""The HTTP contract, through the ASGI app: bounds, error shapes, and the
odd floats. Nothing here touches the service's logic; it checks what a
client can rely on at the edge."""
import httpx
import pytest

from app.service import PressureService


@pytest.fixture
async def api(client):
    from app.main import app
    app.state.service = PressureService(client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
                                 base_url="http://t") as c:
        yield c


@pytest.mark.asyncio
@pytest.mark.parametrize("url", [
    "/metars?lat=91&lon=0", "/metars?lat=0&lon=-181", "/metars?lat=inf&lon=0", "/metars?lat=nan&lon=0",
    "/metars?lat=0&lon=0&half=0.1", "/metars?lat=0&lon=0&half=31", "/metars?lat=abc&lon=0", "/metars?lon=0",
    "/lightning?lat=0&lon=0&half=7", "/forecast?lat=1e400&lon=0",
    "/radar/pressure?lat=0&lon=0&latSpan=0&lonSpan=1", "/radar/pressure?lat=0&lon=0&latSpan=-1&lonSpan=1",
    "/radar/pressure?lat=0&lon=0&latSpan=nan&lonSpan=1", "/radar/field?lat=0&lon=0&latSpan=1&lonSpan=inf",
    "/combined?station=KLUK&tz=100000", "/combined?station=KLUK&lat=95",
    "/stations/search?q=", "/stations/search?q=" + "x" * 41, "/stations/search?q=K&limit=0",
    "/stations/nearest?lat=0", "/pressure/KLUK?hours=0",
])
async def test_out_of_range_and_non_finite_inputs_are_422(api, url):
    r = await api.get(url)
    assert r.status_code == 422, url
    body = r.json()
    assert isinstance(body["detail"], list) and body["detail"]
    for err in body["detail"]:
        assert set(err) >= {"loc", "msg", "type"}


@pytest.mark.asyncio
async def test_denormal_and_edge_values_are_accepted(api):
    for url in ("/metars?lat=1e-320&lon=-1e-320", "/metars?lat=90&lon=180&half=0.5", "/metars?lat=-90&lon=-180&half=30",
                "/radar/pressure?lat=0&lon=0&latSpan=1e-300&lonSpan=360",
                "/lightning?lat=39.1&lon=-84.5&half=6", "/pressure/KLUK?hours=1"):
        r = await api.get(url)
        assert r.status_code == 200, url


@pytest.mark.asyncio
async def test_error_bodies_are_a_detail_string_and_nothing_else(api, upstream):
    upstream.rv_fail = True
    r = await api.get("/radar/frames")
    assert r.status_code == 503 and list(r.json()) == ["detail"] and isinstance(r.json()["detail"], str)
    r = await api.get("/pressure/K1")
    assert r.status_code == 422
    r = await api.get("/nope")
    assert r.status_code == 404 and list(r.json()) == ["detail"]


@pytest.mark.asyncio
async def test_combined_has_the_shape_the_phone_reads(api):
    r = await api.get("/combined?station=KLUK&lat=39.1&lon=-84.4")
    assert r.status_code == 200
    body = r.json()
    for key in ("pressure", "forecast", "reading", "conditions", "runways", "sources", "verdict"):
        assert key in body, key
    assert body["pressure"]["station"] == "KLUK"
    assert r.headers["content-type"].startswith("application/json")
    assert "server" not in {k.lower() for k in r.headers}

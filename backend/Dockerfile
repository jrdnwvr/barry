# Barry backend — production container.
FROM python:3.12-slim

WORKDIR /srv
ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080

# Runtime deps from the hash-pinned lock (uv pip compile --generate-hashes,
# resolved for this image's Python), then the app itself without resolving
# anything further. A changed or substituted wheel fails the build.
COPY requirements.lock pyproject.toml ./
COPY app ./app
RUN pip install --upgrade pip \
    && pip install --require-hashes -r requirements.lock \
    && pip install --no-deps .

EXPOSE 8080

# Not root. The state volume is handed to this user at deploy time.
USER nobody

# IMPORTANT: a single worker, on purpose. The TTL cache, the active-station
# registry, and the batched scheduler are all in-process (see app/cache.py). Run
# one worker / one instance so there is exactly one scheduler hitting
# aviationweather.gov per cycle. To scale horizontally, move the cache + registry
# to Redis first, otherwise each worker runs its own scheduler and its own cache.
# No access log: it recorded every client's coordinates in the query string.
# No server header: nothing to announce.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --no-access-log --no-server-header"]

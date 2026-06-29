# Barry backend — production container.
FROM python:3.12-slim

WORKDIR /srv
ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080

# Install the app + its runtime deps (from pyproject; no dev/test extras).
COPY pyproject.toml ./
COPY app ./app
RUN pip install --upgrade pip && pip install .

EXPOSE 8080

# IMPORTANT: a single worker, on purpose. The TTL cache, the active-station
# registry, and the batched scheduler are all in-process (see app/cache.py). Run
# one worker / one instance so there is exactly one scheduler hitting
# aviationweather.gov per cycle. To scale horizontally, move the cache + registry
# to Redis first, otherwise each worker runs its own scheduler and its own cache.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]

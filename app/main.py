from __future__ import annotations

import time
import os
from typing import Callable

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

app = FastAPI(title="demo-api", version="1.0.0")

DEPLOYMENT_LABEL = os.getenv("DEPLOYMENT_LABEL", os.getenv("DEPLOYMENT_TYPE", "unknown"))
NAMESPACE = os.getenv("POD_NAMESPACE", os.getenv("NAMESPACE", "unknown"))

REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests",
    labelnames=("method", "path", "status", "deployment", "namespace"),
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    labelnames=("method", "path", "status", "deployment", "namespace"),
)


@app.middleware("http")
async def prometheus_middleware(request: Request, call_next: Callable) -> Response:
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start

    path = request.url.path
    status = str(response.status_code)
    method = request.method

    REQUESTS_TOTAL.labels(
        method=method, path=path, status=status, deployment=DEPLOYMENT_LABEL, namespace=NAMESPACE
    ).inc()
    REQUEST_DURATION.labels(
        method=method, path=path, status=status, deployment=DEPLOYMENT_LABEL, namespace=NAMESPACE
    ).observe(elapsed)

    return response


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/ready")
def ready() -> dict[str, str]:
    return {"status": "ready"}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/")
def root() -> dict[str, str]:
    return {"service": "demo-api", "message": "It works."}

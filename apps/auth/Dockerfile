# Build context is the repository root so the shared `common` package can be copied in.
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    PORT=8443 \
    OPS_PORT=8000

WORKDIR /app

# Dependencies first: this layer is cached until requirements.txt changes.
COPY apps/auth/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --disable-pip-version-check -r /tmp/requirements.txt

COPY apps/common /app/common
COPY apps/auth/authsvc /app/authsvc

# Non-root by design; the container never needs to write to its own filesystem.
RUN useradd --create-home --uid 10001 appuser
USER appuser

# 8443 is the mTLS data port; 8000 is the plaintext ops port (healthz/readyz only).
EXPOSE 8443 8000

# ECS container health check and `docker compose ps` use the ops port on purpose:
# the data port rejects callers without a client certificate.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=2).status==200 else 1)"

# common.serve reads the TLS variables from the environment (files on Kubernetes,
# secret env vars on ECS) and starts the listener accordingly.
CMD ["python", "-m", "common.serve", "authsvc.main:app"]

# Applications

Three FastAPI services, one image each, built from the repository root so they can share
`apps/common`.

| Service | Port | Exposure | Responsibility |
|---|---|---|---|
| `gateway` | 8000 | **public** (the only one) | JWT validation at the edge, routing to internal services |
| `auth` | 8000 | internal | registration, login, refresh; the only holder of the JWT private key |
| `catalog` | 8000 | internal | JWT-protected CRUD, always scoped to the caller's user id |

Every service exposes `/healthz` (liveness, no dependencies) and `/readyz` (readiness,
includes the database), logs one JSON line per event with a request id, and shuts down
gracefully on SIGTERM.

Shared code lives in `apps/common`: `config.py` (settings), `observability.py` (logging +
request ids), `security.py` (scrypt hashing, RS256 tokens), `db.py` (engine and sessions).

Run the whole stack locally:

```bash
make up        # docker compose, gateway on http://localhost:8080
make smoke     # register -> login -> CRUD through the gateway
make down
```

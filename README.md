# TaskQueue

TaskQueue is a modular asynchronous job-processing service built with FastAPI, SQLAlchemy 2, PostgreSQL, Alembic, Redis, and Docker Compose. The API accepts jobs, workers claim due work through PostgreSQL row locks, execution attempts are audited, and retryable failures are rescheduled with exponential backoff.

## Features

- Hashed API keys (`X-API-Key`); a newly generated raw key is printed only once by the admin CLI.
- PostgreSQL `FOR UPDATE SKIP LOCKED` job claims and transactionally persisted execution attempts.
- Queue lifecycle: `queued -> running -> succeeded|failed`; cancellations are terminal. Failed attempts return to `queued` until retry limits are reached.
- Worker registration, heartbeats, stale-worker detection, and abandoned-job recovery.
- Job listing filters, ordering, pagination, status retrieval, cancellation, and execution history.
- Redis-backed response caching and request rate limits, secure response headers, optional CIDR allow-list.
- JSON structured logs, health/readiness endpoints, Prometheus metrics, and a provisioned Grafana dashboard.
- Versioned Alembic schema migration; production startup never calls SQLAlchemy `create_all`.

## Technology stack

- Python 3.12, FastAPI, and Pydantic for the HTTP API and validation.
- SQLAlchemy 2 and Alembic for PostgreSQL persistence and schema migrations.
- Redis for response caching and request rate limiting.
- Docker Compose for the API, worker, database, cache, Prometheus, and Grafana.
- pytest for API and lifecycle tests; k6 scenarios are provided for load testing.

## Architecture

FastAPI validates and stores submitted jobs in PostgreSQL. Independent worker processes poll for due jobs and claim them in transactions with `FOR UPDATE SKIP LOCKED`, so concurrent workers do not execute the same queued row. Execution attempts are recorded in PostgreSQL; retryable failures are rescheduled with exponential backoff. Redis backs short-lived API caches and rate limits. Prometheus scrapes the API metrics endpoint, and Grafana is provisioned with a TaskQueue dashboard.

## Environment configuration

Start from `.env.example` and copy it to `.env` for local or Compose use. Replace every placeholder password with a strong, unique value; do not commit `.env` or use development credentials in production. Compose supplies the internal PostgreSQL hostname and Redis URL to its containers. For a local Python process, configure PostgreSQL and Redis on the host, then set the relevant `POSTGRES_*` or `DATABASE_URL`, `REDIS_URL`, worker, retry, rate-limit, and API-doc settings. See the production deployment guide below for secret-management guidance.

## Quick start (local Python)

Requirements: Python 3.12+, PostgreSQL 16+, Redis 7+.

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements-dev.txt
if ((Test-Path .env) -and (Get-Item .env).Length -gt 0) { throw ".env already contains values; merge .env.example settings without overwriting secrets." }
Copy-Item .env.example .env -Force
# Edit POSTGRES_PASSWORD, REDIS_URL, and the other secrets/settings. For a local Python process, keep POSTGRES_HOST=localhost; Compose overrides it to the internal db service.
alembic upgrade head
python -m app.cli create-api-key --name local-development
# Save the one-time key printed by the command in $env:API_KEY.
uvicorn app.main:app --reload
```

In another terminal, with the same environment:

```powershell
$env:WORKER_ID = "worker-local"
python -m app.workers.runner
```

Submit and inspect a job:

```powershell
$headers = @{ "X-API-Key" = $env:API_KEY }
$job = Invoke-RestMethod -Method Post -Uri http://localhost:8000/api/v1/jobs `
  -Headers $headers -ContentType "application/json" `
  -Body '{"task_type":"sum","payload":{"values":[1,2,3]}}'
Invoke-RestMethod -Uri "http://localhost:8000/api/v1/jobs/$($job.id)" -Headers $headers
```

Supported built-in worker task types are `echo`, `sum`, and `sleep`. Add business handlers to `app/workers/runner.py`; do not deserialize or execute code supplied in a job payload.

## Docker Compose

```powershell
if ((Test-Path .env) -and (Get-Item .env).Length -gt 0) { throw ".env already contains values; merge .env.example settings without overwriting secrets." }
Copy-Item .env.example .env -Force
# Replace all development passwords/secrets in .env before starting.
docker compose up --build -d
docker compose ps
docker compose logs -f api worker
```

Compose starts PostgreSQL, Redis, the migrated API, a worker, Prometheus, and Grafana. API readiness waits for PostgreSQL and Redis. Each worker uses a unique worker ID incorporating its container hostname and process ID, so a restarted worker does not renew a previous process's lease. OpenAPI is at `http://localhost:8000/docs`, Prometheus at `http://localhost:9090`, and Grafana at `http://localhost:3000`. To add workers, scale the worker service:

```powershell
docker compose up -d --scale worker=3
```

Do not expose database, Redis, Prometheus, or Grafana ports publicly without appropriate network controls and authentication. The compose file intentionally publishes the monitoring UIs for local use.

## API and operations

See [docs/API.md](docs/API.md) for endpoint contracts and [PHASE_STATUS.md](PHASE_STATUS.md) for the phase-by-phase implementation/verification state. Interactive API docs are served at `/docs` and `/redoc` when `API_DOCS_ENABLED=true`.

| Endpoint | Purpose |
|---|---|
| `GET /health` | Process liveness |
| `GET /ready` | PostgreSQL and Redis readiness |
| `GET /metrics` | Prometheus scrape endpoint |
| `POST /api/v1/jobs` | Submit a job |
| `GET /api/v1/jobs` | Filter, sort, and paginate jobs |
| `GET /api/v1/jobs/{id}` | Retrieve current job state |
| `GET /api/v1/jobs/{id}/executions` | Attempt history |
| `POST /api/v1/jobs/{id}/cancel` | Cancel a queued/running job |
| `POST /api/v1/workers/register` | Register/refresh worker identity |
| `POST /api/v1/workers/{id}/heartbeat` | Update worker liveness |
| `GET /api/v1/workers` | Worker status |
| `GET /api/v1/metrics` | Queue and worker summary (API key required) |

## Tests and load tests

```powershell
python -m pytest -q
```

Tests use SQLite for fast lifecycle/API checks; the production configuration is PostgreSQL. Run the provided k6 scenarios against a running stack using `API_URL` and `API_KEY` environment variables:

```powershell
$env:API_URL = "http://localhost:8000"
$env:API_KEY = "<created-api-key>"
k6 run loadtests/job_submission.js
k6 run loadtests/job_status.js
k6 run loadtests/concurrent_workload.js
```

## Production deployment guide

1. Use managed PostgreSQL and Redis or isolated, private production services. Configure TLS where supported and restrict network ingress.
2. Provide `DATABASE_URL` (or the `POSTGRES_*` connection settings) and `REDIS_URL` through the deployment platform's secret manager. Set unique, high-entropy PostgreSQL/Grafana credentials; never commit `.env`.
3. Configure `ALLOWED_IP_NETWORKS` as comma-separated CIDRs when a known trusted ingress range is available. Terminate HTTPS at a trusted load balancer; expose only the API and authenticated monitoring surfaces.
4. Disable public API docs if not needed (`API_DOCS_ENABLED=false`), retain `RATE_LIMIT_ENABLED=true`, and tune limits, worker lease timeouts, retries, and concurrency to the workload.
5. Run `alembic upgrade head` as a controlled release/migration step before rolling out API and worker replicas. The container command runs this migration on API startup for the single-host Compose setup; production orchestrators should run migrations as a one-off job to avoid concurrent migration runners.
6. Create an API key with `python -m app.cli create-api-key --name <owner>` in a controlled environment and deliver the one-time output via a secret manager. Revoke a key by setting its `api_keys.is_active` flag to false.
7. Deploy API and worker containers from the same immutable image, use separate unique worker identities, configure liveness/readiness probes, backups, retention, alerting, and log collection.
8. Verify `/health`, `/ready`, authenticated API flows, Prometheus scrape health, and a complete job execution before promoting the release.

This repository provides deployment configuration but does not claim that a production deployment has been run.
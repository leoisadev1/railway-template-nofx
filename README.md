# Deploy and Host NOFX on Railway

Self-hosted [NOFX](https://github.com/NoFxAiOS/nofx) AI trading terminal: SQLite on a volume at `/app/data`, a real `/health` check, and a generated JWT secret.

NOFX is an open-source terminal where a language model proposes trades and a Go runtime enforces hard risk limits. This listing is a one-service deploy of the official all-in-one Railway image shape (backend binary + frontend static files + nginx), pinned by digest.

**Do not place real trades from a throwaway deploy.** Automated trading can lose money. Size positions yourself, keep exchange keys off shared machines, and never fund an instance you do not control.

## About Hosting NOFX

The container runs the Go API on port `8081` and nginx on Railway `PORT`. SQLite lives at `/app/data/data.db` on a persistent volume. Railway healthchecks `GET /health`, which nginx proxies to `/api/health`.

First boot: open the public URL and register. That account becomes the instance owner; later registration is rejected with `System already initialized`. Autopilot stays off until you start it. This template does not place trades on its own.

Source: [leoisadev1/railway-template-nofx](https://github.com/leoisadev1/railway-template-nofx), based on [NoFxAiOS/nofx@638d404](https://github.com/NoFxAiOS/nofx/commit/638d4042118995fbf1a38d3822b1139aa3c6b467) (`Dockerfile.railway`).

## Why Deploy

The popular marketplace `nofx` card (health 68) points at upstream but ships neither the `/app/data` volume nor a wired `/health` check. This template:

- Pins `ghcr.io/nofxaios/nofx/nofx-backend` and `nofx-frontend` **and** `alpine:3.22` by digest (no floating `:latest`)
- Mounts a volume at `/app/data` for SQLite, logs, and persisted RSA/AES keys
- Sets Railway `healthcheckPath = /health` (proxied to the Go `/api/health` endpoint)
- Generates `JWT_SECRET` and `DATA_ENCRYPTION_KEY` with `${{secret()}}` on each new deploy
- Documents first-boot owner lock

## Common Use Cases

- Self-host the NOFX dashboard without cloning an empty GitHub repo
- Keep SQLite and encryption keys across Railway redeploys
- Paper-trade or testnet an AI trader before attaching live exchange keys

## Dependencies for NOFX Hosting

- One Railway service built from this Dockerfile (GHCR backend + frontend layers, alpine 3.22)
- Volume mounted at `/app/data`
- Public HTTPS domain (nginx)
- Generated `JWT_SECRET` (32+ characters) and `DATA_ENCRYPTION_KEY`

No exchange API keys or model keys are required to boot the UI. Add those in the app after you register.

### Deployment Dependencies

| Piece | Pin / value | Notes |
| --- | --- | --- |
| Backend image | `ghcr.io/nofxaios/nofx/nofx-backend:latest@sha256:f781904f35b8235053ecc0c9e213bb1d6b2dd11514a72a8121ca20e161b0ab06` | Recorded 2026-09-07 |
| Frontend image | `ghcr.io/nofxaios/nofx/nofx-frontend:latest@sha256:889335c1f1f21a2bb60cb25dbf5a3ab5d688d4a9639a4cf20d7f352515f5c71d` | Recorded 2026-09-07 |
| Runtime | `alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce` | Multi-arch index |
| Volume | `/app/data` | SQLite `data.db` + RSA PEM |
| Healthcheck | `GET /health` | Timeout 120s |
| Upstream commit | `638d4042118995fbf1a38d3822b1139aa3c6b467` | NoFxAiOS/nofx `dev` 2026-09-05 |

## After deploy

1. Open the public HTTPS URL Railway assigns to the `nofx` service.
2. Register the first account (email + password, 8+ characters). That user is the instance owner. Registration then locks.
3. Follow the in-app launch guide: add an AI model (your own API key, or Claw402 USDC metering) and an exchange. **Paper / testnet first.**
4. Autopilot is optional and off until you start it.

`GET /health` returns the backend JSON `{"status":"ok"}` once nginx and the Go API are up.

## Variables

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `JWT_SECRET` | yes | `${{secret()}}` | HS256 signing key, 32+ characters. Generated per deploy. |
| `DATA_ENCRYPTION_KEY` | yes | `${{secret()}}` | AES key for credentials at rest. Generated per deploy. Changing it makes stored exchange keys unreadable. |
| `DB_TYPE` | no | `sqlite` (image ENV) | Keep sqlite unless you attach your own Postgres. |
| `DB_PATH` | no | `/app/data/data.db` (image ENV) | Must stay on the volume. |
| `TZ` | no | `UTC` (image ENV) | Container timezone. |
| `TRANSPORT_ENCRYPTION` | no | unset (false) | Set `true` only if you want browser-side API-key encryption (HTTPS already terminates at Railway). |
| `RSA_PRIVATE_KEY` | no | generated on first boot, saved to `/app/data/rsa_private_key.pem` | PEM. Leave empty; the start script persists it on the volume. |

Optional market-data keys (`ALPACA_API_KEY`, `ALPACA_SECRET_KEY`, `TWELVEDATA_API_KEY`) stay empty. Add them in the dashboard if you need those feeds.

## Volume and port

- Volume mount: `/app/data` (SQLite + encryption material)
- HTTP: Railway `PORT` (nginx). Backend listens on `8081` inside the container and is not public.
- Healthcheck: `GET /health` (timeout 120s)

Redeploys keep the owner account, strategies, and encrypted exchange credentials as long as the volume and `DATA_ENCRYPTION_KEY` stay put.

## Login / owner lock

There is no default user. On a fresh volume:

1. Open the site and register.
2. The first successful `POST /api/register` creates the owner.
3. Further registration is rejected with `System already initialized`.

If you need a new owner, wipe the volume (you will lose the SQLite database). There is no implicit credential adoption after a reset.

## Risk

This is self-hosted trading software (AGPL-3.0). The template does not include exchange API keys, does not enable Autopilot, and does not fund wallets. You are responsible for keys, balances, and venue rules. See upstream [DISCLAIMER.md](https://github.com/NoFxAiOS/nofx/blob/dev/DISCLAIMER.md).

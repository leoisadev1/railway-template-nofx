# Deploy and Host NOFX on Railway

Self-hosted [NOFX](https://github.com/NoFxAiOS/nofx) with a persistent SQLite volume, backend healthcheck, protected owner registration, and restart-invalidated sessions. Backend, frontend, and Alpine image digests are pinned in the Dockerfile.

**Do not attach real funds or credentials based on deployment tests.** Automated trading can lose money. No real trading, deposits, funded wallets, or model/exchange credentials are covered by the audit.

## About Hosting NOFX

One container runs nginx on port `8080` and the Go backend on `127.0.0.1:8081`, reachable only from inside the container. Both run as an unprivileged `nofx` user with no capabilities and `no_new_privs`; the wrapper uses root only at startup to write nginx's configuration and take ownership of the volume. SQLite, RSA, and fallback AES key material live on `/app/data`. Railway checks `GET /health`, which proxies to the backend's `/api/health`.

The startup wrapper requires a setup password and protects `/api/register` (including its trailing-slash form) with nginx HTTP Basic authentication. Upstream's anonymous trader-data endpoints (`/api/traders`, `/api/competition`, `/api/top-traders`, equity history and public trader config) list every trader's name, exchange, equity and PnL by default, so nginx requires a signed-in owner for them; the competition page needs login. Other APIs retain their normal Bearer-token authentication. Publish port `8080` only. Upstream throttles login attempts per client address (8, then one every 6 seconds). For connections from Railway's edge range (`100.64.0.0/10`), nginx takes the client address from `X-Real-IP`, which the edge sets itself, so each internet client has its own limit and nobody can escape it by forging forwarding headers.

Other services in the same Railway project reach NOFX only through nginx on `8080`, with the same setup gate and login as the public domain. Services that connect over the private network also come from `100.64.0.0/10`, so they can set `X-Real-IP` and are not reliably rate-limited; keep untrusted software out of the project.

Upstream's usage telemetry (Google Analytics events for startup, model usage, and each trade's exchange, symbol, USD amount and leverage) is off unless you set `EXPERIENCE_IMPROVEMENT=true`.

Each startup derives a new effective JWT signing key from the private JWT seed and fresh random entropy. **All sessions expire on restart/redeploy; log in again.** SQLite, RSA and data-encryption keys are not rotated. Use one replica and the supplied startup wrapper, not the backend binary directly.

## First setup and login

1. Set the required variables below and mount `/app/data` before starting. Missing or invalid `SETUP_PASSWORD` fails closed before nginx/backend launch.
2. Open the Railway HTTPS domain and fill in the owner email and account password.
3. When registration prompts for **NOFX owner setup**, use HTTP username **`setup`** and the generated **`SETUP_PASSWORD`** from Railway variables. This is separate from your account password. Browsers may cache this HTTP credential; use a private browser context on shared devices.
4. Complete owner registration. Subsequent registration remains setup-gated and the backend rejects additional owners with `System already initialized`.
5. On later visits or after restart, sign in with the owner email/account password. Normal login does not require the setup password. Do not paste the setup password into API Bearer headers.

Keep the setup secret private. It proves permission to attempt owner registration, not ownership of an already initialized account. Anyone holding it can participate in initial setup. A populated volume may contain existing trader configuration; it is not necessarily inert. The app may automatically generate an **unfunded** wallet during onboarding without the operator making a deposit.

## Variables

| Variable | Required/default | Purpose |
| --- | --- | --- |
| `SETUP_PASSWORD` | Required; template generates `${{secret()}}` | At least 16 letters, digits, `_` or `-`; HTTP Basic username is `setup`. Never used for wallet encryption. |
| `JWT_SECRET` | Required, 32+ characters; `${{secret()}}` | Private seed combined with fresh 256-bit random entropy on each startup. Effective session-signing key is not persisted. |
| `DATA_ENCRYPTION_KEY` | Listing generates independent `${{secret()}}` | Keep stable with the volume. Upstream accepts/normalizes encoded key material; an audited 32-character Base64 value decoded to 24 bytes (AES-192). Do not rotate it to invalidate sessions. |
| `RSA_PRIVATE_KEY` | Optional; generated/persisted if omitted | RSA-2048 PEM at `/app/data/rsa_private_key.pem`; not rotated on restart. |
| `TRANSPORT_ENCRYPTION` | Optional, false | `true` enables browser-side credential transport encryption in addition to HTTPS. |
| `EXPERIENCE_IMPROVEMENT` | Optional, false | `true` turns on upstream's usage telemetry to Google Analytics. |
| `EDGE_PROXY_CIDRS` | Optional, `100.64.0.0/10` | CIDRs of the reverse proxy whose client-address header nginx believes for the login rate limit. Leave unset on Railway. |
| `EDGE_CLIENT_IP_HEADER` | Optional, `X-Real-IP` | That header: `X-Real-IP`, or `X-Forwarded-For` for your own proxy that sends no `X-Real-IP`. Leave unset on Railway. |
| `PORT` | `8080` | nginx/public HTTP port; do not expose backend `8081`. |
| `DB_TYPE` / `DB_PATH` | `sqlite` / `/app/data/data.db` | Keep the database on the volume. |
| `TZ` | `UTC` | Container timezone. |

If `DATA_ENCRYPTION_KEY` is omitted, startup generates Base64 of 32 random bytes and persists it at `/app/data/data_encryption_key`. Back up the database and its stable encryption material together.

**Existing deployments:** set a valid `SETUP_PASSWORD` in the service variables before updating to this wrapper. Do not set `RAILWAY_RUN_UID`; the first start changes the owner of the files on `/app/data` to the `nofx` user. New template deployments generate it automatically, but updating a template listing does not add variables to existing instances. Keep `DATA_ENCRYPTION_KEY` and the volume unchanged. Every restart invalidates all sessions; sign in again with the owner account password.

## Common Use Cases

- Evaluate the dashboard with a synthetic account and no trading keys.
- Retain owner/configuration data through restarts while invalidating all old sessions.
- Run a single-user instance with a separate owner-setup credential.

## Dependencies for NOFX Hosting

- One service built from this Dockerfile and a persistent `/app/data` volume.
- HTTPS domain targeting nginx port `8080` only; one replica.
- Required setup password and JWT seed; stable data-encryption material.
- No model or exchange key is needed for health, owner login, or inactive configuration tests.

### Deployment Dependencies

[Template source](https://github.com/leoisadev1/railway-template-nofx) wraps pinned official GHCR backend/frontend artifacts. The source reference inspected for routes, listen address and JWT use is [NoFxAiOS/nofx@65e9037](https://github.com/NoFxAiOS/nofx/commit/65e9037b452707c216d9746ea2c942fd1843badc), an untagged development build; upstream publishes no releases. The Dockerfile retains all existing digest pins. Railway health timeout is 120 seconds.

## Why Deploy NOFX on Railway?

Railway provides the container, HTTPS routing, generated secrets, and the persistent `/app/data` volume. You remain responsible for every exchange key, model key, wallet, trade, backup, and image update. NOFX is experimental trading software; deploying it does not make trading safe.

## Validation and limits

Run `python3 tests/test_start.py` for the 19 local startup regression tests. They exercise setup fail-closed behavior, registration-only gate generation, fresh session keys, the privilege drop and loopback bind, the telemetry default, the trusted edge range, the client-address header setting and their validation, and stable RSA/AES material without starting a local server. The container smoke test additionally checks process privileges, the loopback-only backend, the trader-data gate, a per-client login throttle behind a stand-in for Railway's edge that clients cannot escape by forging `X-Forwarded-For` or `X-Real-IP`, logout, restart invalidation, and an upgrade from a 1.0.x volume.

The 1.0.0 wrapper (revision `5033202222decb2560ee20703ec3d92364a74ade`) also passed controlled Railway tests: missing/wrong setup credentials were rejected, owner registration and login worked in a real browser, Bearer APIs remained usable, and both logged-out and previously active tokens were rejected after restart. Fresh login, inactive configuration, and stable RSA/data-encryption material were verified afterward, with zero traders. Browser automation's global Basic-header override was cleared after registration before testing normal login; native desktop/phone authentication dialogs were not manually tested. These checks used no real model/exchange keys, trades, deposits or funding.

Restart invalidation deliberately trades session continuity for fail-closed revocation. This wrapper does not implement persistent individual-token revocation or change upstream password-reset/session semantics. Financial execution, exchange risk controls, concurrent authorized setup, multi-replica sessions, and funded-wallet recovery are outside these tests. NOFX is AGPL-3.0 software; see its upstream disclaimer before any financial use.

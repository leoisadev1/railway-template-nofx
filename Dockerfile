# NOFX all-in-one Railway image.
# Reuses official GHCR backend + frontend bits (same shape as upstream
# Dockerfile.railway) but pins every layer by digest.
#
# Upstream: NoFxAiOS/nofx@65e9037b452707c216d9746ea2c942fd1843badc (dev, 2026-11-04)
# GHCR latest index digests recorded 2026-11-19 (image label main-amd64).
# The backend binary is built on Alpine 3.24, so the runtime uses 3.24 too.

FROM ghcr.io/nofxaios/nofx/nofx-backend:latest@sha256:de852567df3c260c9d8b4d050b92308fa48563004909d629d97fd3224e1319dc AS backend

FROM ghcr.io/nofxaios/nofx/nofx-frontend:latest@sha256:407ebafec2991c02212ea3b2167a2dbb5b6ff27217f52cbdf7dea9d60d0e3be9 AS frontend

FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache ca-certificates tzdata sqlite nginx openssl wget setpriv \
  && addgroup -S -g 10001 nofx \
  && adduser -S -D -H -u 10001 -G nofx -h /app -s /sbin/nologin nofx

COPY --from=backend /app/nofx /app/nofx
COPY --from=backend /usr/local/lib/libta_lib* /usr/local/lib/
RUN ldconfig /usr/local/lib 2>/dev/null || true

COPY --from=frontend /usr/share/nginx/html /usr/share/nginx/html

WORKDIR /app
RUN mkdir -p /app/data && chown nofx:nofx /app/data && chmod 700 /app/data

COPY railway/start.sh /app/start.sh
COPY railway/serve.sh /app/serve.sh
RUN chmod 755 /app/start.sh /app/serve.sh

ENV DB_TYPE=sqlite \
    DB_PATH=/app/data/data.db \
    TZ=UTC

EXPOSE 8080

# No HEALTHCHECK: Docker would run it as root next to the unprivileged
# processes, and Railway ignores it in favour of railway.toml's /health check.
# Probe http://<host>:<port>/health from outside the container instead.

# start.sh runs as root only to hand the volume to the nofx user and write
# nginx's root-owned config, then replaces itself with serve.sh under setpriv
# (UID 10001, no supplementary groups, empty capability bounding set,
# no_new_privs). No root process remains.
CMD ["/app/start.sh"]

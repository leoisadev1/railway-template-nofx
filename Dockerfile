# NOFX all-in-one Railway image.
# Reuses official GHCR backend + frontend bits (same shape as upstream
# Dockerfile.railway) but pins every layer by digest.
#
# Upstream: NoFxAiOS/nofx@638d4042118995fbf1a38d3822b1139aa3c6b467 (dev, 2026-09-05)
# GHCR latest digests recorded 2026-09-07.

FROM ghcr.io/nofxaios/nofx/nofx-backend:latest@sha256:f781904f35b8235053ecc0c9e213bb1d6b2dd11514a72a8121ca20e161b0ab06 AS backend

FROM ghcr.io/nofxaios/nofx/nofx-frontend:latest@sha256:889335c1f1f21a2bb60cb25dbf5a3ab5d688d4a9639a4cf20d7f352515f5c71d AS frontend

FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

RUN apk add --no-cache ca-certificates tzdata sqlite nginx openssl wget

COPY --from=backend /app/nofx /app/nofx
COPY --from=backend /usr/local/lib/libta_lib* /usr/local/lib/
RUN ldconfig /usr/local/lib 2>/dev/null || true

COPY --from=frontend /usr/share/nginx/html /usr/share/nginx/html

WORKDIR /app
RUN mkdir -p /app/data

COPY railway/start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV DB_TYPE=sqlite \
    DB_PATH=/app/data/data.db \
    TZ=UTC

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:${PORT:-8080}/health || exit 1

CMD ["/app/start.sh"]

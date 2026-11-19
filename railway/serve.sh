#!/bin/sh
# NOFX startup, unprivileged half. start.sh runs this under setpriv as the nofx
# user: it creates or loads the key files on the volume, then runs the backend
# on loopback and nginx in front of it.
set -eu
umask 077

if [ "$(id -u)" -eq 0 ]; then
  echo "serve.sh must not run as root; start the container with /app/start.sh" >&2
  exit 1
fi

mkdir -p /app/data
chmod 700 /app/data

# Persist RSA across restarts so browser transport keys stay valid.
if [ -z "${RSA_PRIVATE_KEY:-}" ]; then
  if [ -f /app/data/rsa_private_key.pem ]; then
    RSA_PRIVATE_KEY="$(cat /app/data/rsa_private_key.pem)"
  else
    openssl genrsa 2048 > /app/data/rsa_private_key.pem 2>/dev/null
    chmod 600 /app/data/rsa_private_key.pem
    RSA_PRIVATE_KEY="$(cat /app/data/rsa_private_key.pem)"
  fi
  export RSA_PRIVATE_KEY
fi

# Persist AES data key if the operator did not supply one.
if [ -z "${DATA_ENCRYPTION_KEY:-}" ]; then
  if [ -f /app/data/data_encryption_key ]; then
    DATA_ENCRYPTION_KEY="$(cat /app/data/data_encryption_key)"
  else
    openssl rand -base64 32 > /app/data/data_encryption_key
    chmod 600 /app/data/data_encryption_key
    DATA_ENCRYPTION_KEY="$(cat /app/data/data_encryption_key)"
  fi
  export DATA_ENCRYPTION_KEY
fi

# --- end of unit-tested setup ---

echo "Starting NOFX backend on 127.0.0.1:8081, nginx on ${PORT}"

# Loopback only, so other services in the Railway project cannot bypass nginx.
# Only nginx (127.0.0.1) may supply the client address for the login rate limit.
NOFX_API_BIND_ADDRESS=127.0.0.1 API_SERVER_PORT=8081 NOFX_TRUSTED_PROXIES=127.0.0.1 /app/nofx &
BACKEND_PID=$!

i=0
while [ "$i" -lt 45 ]; do
  if wget --no-verbose --tries=1 --spider http://127.0.0.1:8081/api/health >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    echo "NOFX backend exited before becoming healthy" >&2
    exit 1
  fi
  i=$((i + 1))
  sleep 1
done

if ! wget --no-verbose --tries=1 --spider http://127.0.0.1:8081/api/health >/dev/null 2>&1; then
  echo "NOFX backend did not become healthy in time" >&2
  kill "$BACKEND_PID" 2>/dev/null || true
  exit 1
fi

nginx -e stderr -c /run/nofx/conf/nginx.conf -g 'daemon off;' &
NGINX_PID=$!

trap 'kill "$BACKEND_PID" "$NGINX_PID" 2>/dev/null || true; wait; exit 0' TERM INT

echo "NOFX is up (backend pid ${BACKEND_PID}, nginx pid ${NGINX_PID})"

while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$NGINX_PID" 2>/dev/null; do
  sleep 2
done

echo "NOFX process exited" >&2
kill "$BACKEND_PID" "$NGINX_PID" 2>/dev/null || true
wait || true
exit 1

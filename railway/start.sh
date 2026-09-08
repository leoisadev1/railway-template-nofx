#!/bin/sh
set -eu
umask 077

export PORT="${PORT:-8080}"
export DB_TYPE="${DB_TYPE:-sqlite}"
export DB_PATH="${DB_PATH:-/app/data/data.db}"
export TZ="${TZ:-UTC}"

mkdir -p /app/data
chmod 700 /app/data

if [ -z "${JWT_SECRET:-}" ] || [ "${#JWT_SECRET}" -lt 32 ]; then
  echo "JWT_SECRET is required (set a 32+ character secret)" >&2
  exit 1
fi

if [ -z "${SETUP_PASSWORD:-}" ] || [ "${#SETUP_PASSWORD}" -lt 16 ]; then
  echo "SETUP_PASSWORD is required (set a 16+ character secret)" >&2
  exit 1
fi
case "$SETUP_PASSWORD" in
  *[!a-zA-Z0-9_-]*)
    echo "SETUP_PASSWORD must contain only letters, digits, underscores or hyphens" >&2
    exit 1
    ;;
esac

# Invalidate all prior sessions when the backend process is started again.
BOOT_NONCE="$(openssl rand -hex 32)"
JWT_SECRET="$(printf '%s:%s' "$JWT_SECRET" "$BOOT_NONCE" | openssl dgst -sha256)"
JWT_SECRET="${JWT_SECRET##* }"
[ "${#JWT_SECRET}" -eq 64 ] || exit 1
export JWT_SECRET
unset BOOT_NONCE

# nginx workers need read access to the hash, never the setup password.
mkdir -p /run/nofx-auth
chmod 755 /run/nofx-auth
SETUP_HASH="$(printf '%s' "$SETUP_PASSWORD" | openssl passwd -6 -stdin)"
printf 'setup:%s\n' "$SETUP_HASH" > /run/nofx-auth/registration.htpasswd
chmod 644 /run/nofx-auth/registration.htpasswd
unset SETUP_PASSWORD SETUP_HASH

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

cat > /etc/nginx/http.d/default.conf << NGINX_EOF
server {
    listen ${PORT};
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    location /health {
        proxy_pass http://127.0.0.1:8081/api/health;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_connect_timeout 2s;
        proxy_read_timeout 5s;
    }

    location ~ ^/api/register/?$ {
        auth_basic "NOFX owner setup";
        auth_basic_user_file /run/nofx-auth/registration.htpasswd;
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host \$host;
        proxy_set_header Authorization "";
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8081/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX_EOF

echo "Starting NOFX backend on 8081, nginx on ${PORT}"

API_SERVER_PORT=8081 /app/nofx &
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

nginx -g 'daemon off;' &
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

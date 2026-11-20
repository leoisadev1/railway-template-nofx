#!/bin/sh
# NOFX startup, privileged half. Validates the secrets, writes nginx's
# configuration and the registration hash as root-owned read-only files, hands
# the volume to the nofx user, then replaces itself with serve.sh under setpriv.
set -eu
umask 077

APP_USER=nofx
CONF_DIR=/run/nofx/conf
STATE_DIR=/run/nofx/state

export PORT="${PORT:-8080}"
export DB_TYPE="${DB_TYPE:-sqlite}"
export DB_PATH="${DB_PATH:-/app/data/data.db}"
export TZ="${TZ:-UTC}"
# Upstream sends startup, trade (exchange, symbol, USD amount, leverage) and
# model-usage events to Google Analytics unless this is false. Opt in by
# setting it to true.
export EXPERIENCE_IMPROVEMENT="${EXPERIENCE_IMPROVEMENT:-false}"
# Proxies whose X-Real-IP nginx believes: Railway's edge only. Any wider range
# would let more peers choose the client address the login limit uses.
EDGE_PROXY_CIDRS="${EDGE_PROXY_CIDRS:-100.64.0.0/10}"
# Header those proxies carry the client address in. Railway's edge writes
# X-Real-IP: <client>; its X-Forwarded-For ends with the edge's own public
# address. X-Forwarded-For (taking the rightmost entry not in EDGE_PROXY_CIDRS)
# is for a reverse proxy of your own that appends to it and sets no X-Real-IP.
EDGE_CLIENT_IP_HEADER="${EDGE_CLIENT_IP_HEADER:-X-Real-IP}"

if [ "$(id -u)" -ne 0 ]; then
  echo "start.sh must start as root; it drops to the ${APP_USER} user itself" >&2
  exit 1
fi

case "$PORT" in
  '' | *[!0-9]*)
    echo "PORT must be a number" >&2
    exit 1
    ;;
esac

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

# Accept only well-formed IPv4 or IPv6 CIDRs with a non-zero prefix: the value
# is written into nginx's configuration, and /0 would trust every client.
# Count the colon-separated hextets in one side of an IPv6 address (the part
# before or after "::"). Prints the count; fails on an empty or over-long group.
ipv6_groups() {
  [ -n "$1" ] || { echo 0; return 0; }
  case "$1" in :* | *: | *::*) return 1 ;; esac
  n=0
  old_ifs="$IFS"
  IFS=:
  for group in $1; do
    n=$((n + 1))
    if [ -z "$group" ] || [ "${#group}" -gt 4 ]; then
      IFS="$old_ifs"
      return 1
    fi
  done
  IFS="$old_ifs"
  echo "$n"
}

valid_cidr() {
  addr="${1%/*}"
  bits="${1##*/}"
  [ "$addr" != "$1" ] || return 1
  case "$bits" in '' | *[!0-9]*) return 1 ;; esac
  [ "${#bits}" -le 3 ] || return 1
  case "$addr" in
    *:*)
      case "$addr" in *[!0-9a-fA-F:]* | *:::*) return 1 ;; esac
      [ "${#addr}" -le 39 ] || return 1
      tail="${addr#*::}"
      if [ "$tail" != "$addr" ]; then
        # Compressed form: "::" appears once and stands for at least one group.
        case "$tail" in *::*) return 1 ;; esac
        head="${addr%%::*}"
        h="$(ipv6_groups "$head")" || return 1
        t="$(ipv6_groups "$tail")" || return 1
        [ $((h + t)) -le 7 ] || return 1
      else
        # Full form: exactly eight groups of one to four hex digits.
        n="$(ipv6_groups "$addr")" || return 1
        [ "$n" -eq 8 ] || return 1
      fi
      [ "$bits" -ge 1 ] && [ "$bits" -le 128 ]
      ;;
    *)
      case "$addr" in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
      [ "$bits" -ge 1 ] && [ "$bits" -le 32 ] || return 1
      octets=0
      old_ifs="$IFS"
      IFS=.
      for octet in $addr; do
        octets=$((octets + 1))
        if [ "${#octet}" -gt 3 ] || [ "$octet" -gt 255 ]; then
          IFS="$old_ifs"
          return 1
        fi
      done
      IFS="$old_ifs"
      [ "$octets" -eq 4 ]
      ;;
  esac
}
REAL_IP_FROM=""
set -f
for cidr in $(printf '%s' "$EDGE_PROXY_CIDRS" | tr ',' ' '); do
  if ! valid_cidr "$cidr"; then
    echo "EDGE_PROXY_CIDRS must be a comma-separated list of IPv4 or IPv6 CIDRs with a prefix of at least 1" >&2
    exit 1
  fi
  REAL_IP_FROM="${REAL_IP_FROM}    set_real_ip_from ${cidr};
"
done
set +f
if [ -z "$REAL_IP_FROM" ]; then
  echo "EDGE_PROXY_CIDRS must list at least one CIDR" >&2
  exit 1
fi
case "$EDGE_CLIENT_IP_HEADER" in
  X-Real-IP)
    REAL_IP_HEADER="    real_ip_header X-Real-IP;
"
    ;;
  X-Forwarded-For)
    REAL_IP_HEADER="    real_ip_header X-Forwarded-For;
    real_ip_recursive on;
"
    ;;
  *)
    echo "EDGE_CLIENT_IP_HEADER must be exactly X-Real-IP (the default, for Railway) or X-Forwarded-For" >&2
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

# Root-owned and read-only for the nofx user: the backend cannot change what
# nginx enforces. nginx needs the hash, never the setup password.
mkdir -p "$CONF_DIR"
chmod 755 /run/nofx "$CONF_DIR"
SETUP_HASH="$(printf '%s' "$SETUP_PASSWORD" | openssl passwd -6 -stdin)"
printf 'setup:%s\n' "$SETUP_HASH" > "$CONF_DIR/registration.htpasswd"
chmod 644 "$CONF_DIR/registration.htpasswd"
unset SETUP_PASSWORD SETUP_HASH

cat > "$CONF_DIR/nginx.conf" << NGINX_EOF
worker_processes 2;
pid ${STATE_DIR}/nginx.pid;
error_log stderr warn;
pcre_jit on;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    client_max_body_size 1m;
    sendfile on;
    tcp_nopush on;
    access_log off;

    client_body_temp_path ${STATE_DIR}/client_body;
    proxy_temp_path ${STATE_DIR}/proxy;
    fastcgi_temp_path ${STATE_DIR}/fastcgi;
    uwsgi_temp_path ${STATE_DIR}/uwsgi;
    scgi_temp_path ${STATE_DIR}/scgi;

    # When the TCP peer is a trusted edge proxy (EDGE_PROXY_CIDRS, Railway's
    # 100.64.0.0/10 by default), take the client address from the header
    # EDGE_CLIENT_IP_HEADER names, X-Real-IP by default. Railway's edge
    # discards what the client sent and writes X-Real-IP: <client> and
    # X-Forwarded-For: <client>, <edge public address>, so the rightmost
    # untrusted X-Forwarded-For entry would be a shared, rotating edge address,
    # not the client. Any other peer is the client itself, whatever headers it
    # sends. The backend keys its login rate limit on this address.
${REAL_IP_FROM}${REAL_IP_HEADER}
    server {
        listen ${PORT};
        server_name _;
        root /usr/share/nginx/html;
        index index.html;
        absolute_redirect off;
        gzip on;
        gzip_vary on;
        gzip_types text/plain text/css application/json application/javascript;

        location /health {
            proxy_pass http://127.0.0.1:8081/api/health;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_connect_timeout 2s;
            proxy_read_timeout 5s;
        }

        location ~ ^/api/register/?$ {
            auth_basic "NOFX owner setup";
            auth_basic_user_file ${CONF_DIR}/registration.htpasswd;
            proxy_pass http://127.0.0.1:8081;
            proxy_set_header Host \$host;
            proxy_set_header Authorization "";
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
        }

        # Upstream serves these without login. It lists every trader with
        # show_in_competition=true (its default): names, model, exchange,
        # equity, PnL, positions and prompt template. Require an owner session.
        location = /_nofx_owner_session {
            internal;
            proxy_pass http://127.0.0.1:8081/api/my-traders;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header Authorization \$http_authorization;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_connect_timeout 2s;
            proxy_read_timeout 10s;
        }

        location ~ ^/api/(traders|competition|top-traders|equity-history|equity-history-batch|traders/[^/]+/public-config)/?$ {
            auth_request /_nofx_owner_session;
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_connect_timeout 300s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
        }

        location /api/ {
            proxy_pass http://127.0.0.1:8081/api/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_connect_timeout 300s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
        }

        # Never cache the SPA shell, so an image update takes effect at once.
        location = /index.html {
            add_header Cache-Control "no-cache, no-store, must-revalidate";
        }

        # Upstream's SPA routes that share a name with a static directory.
        location = /frontier {
            try_files /index.html =404;
            add_header Cache-Control "no-store";
        }
        location = /planning {
            try_files /index.html =404;
            add_header Cache-Control "no-store";
        }
        location = /planning/ {
            try_files /index.html =404;
            add_header Cache-Control "no-store";
        }
        location = /planning/chart.js {
            try_files \$uri =404;
            add_header Cache-Control "no-cache, must-revalidate";
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
NGINX_EOF
chmod 644 "$CONF_DIR/nginx.conf"

# --- end of unit-tested setup ---

# Railway mounts volumes root-owned, and releases before 1.1.0 wrote every file
# as root. Hand them to the nofx user. find does not follow symlinks and chown
# -h changes a link itself, so a planted link cannot redirect the chown; nothing
# runs as nofx yet, so nothing can swap a path in between.
mkdir -p /app/data
find /app/data -xdev \( ! -user "$APP_USER" -o ! -group "$APP_USER" \) -exec chown -h "$APP_USER:$APP_USER" {} +
chmod 700 /app/data

# nginx's pid file and temp files, writable only by the nofx user.
rm -rf /run/nofx/state
mkdir -m 700 "$STATE_DIR"
chown "$APP_USER:$APP_USER" "$STATE_DIR"

exec setpriv --reuid="$APP_USER" --regid="$APP_USER" --clear-groups \
  --bounding-set=-all --inh-caps=-all --no-new-privs \
  env HOME=/app /app/serve.sh

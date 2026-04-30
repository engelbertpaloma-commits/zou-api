FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    software-properties-common build-essential \
    postgresql-client redis-tools nginx xmlsec1 ffmpeg curl jq \
    && rm -rf /var/lib/apt/lists/*

# Install Python 3.12
RUN add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install -y python3.12 python3.12-venv python3.12-dev \
    && rm -rf /var/lib/apt/lists/*

# Create zou user and directories
RUN useradd --home /opt/zou zou \
    && mkdir -p /opt/zou/backups /opt/zou/previews /opt/zou/tmp /opt/zou/logs \
    && chown -R zou:zou /opt/zou

# Install Zou and Gunicorn
RUN python3.12 -m venv /opt/zou/zouenv \
    && /opt/zou/zouenv/bin/pip install --upgrade pip \
    && /opt/zou/zouenv/bin/pip install zou gunicorn[gevent] gevent-websocket \
    && /opt/zou/zouenv/bin/pip install flask-sqlalchemy flask-mail
    
ENV PATH="/opt/zou/zouenv/bin:/usr/bin:$PATH"

# Create startup script
RUN cat > /start.sh << 'EOF'
#!/bin/bash
set -e

echo "Railway PORT: $PORT"
echo "PGHOST: $PGHOST"
echo "REDIS_HOST: $REDIS_HOST"

# Validate required env vars
: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${REDIS_HOST:?REDIS_HOST is required}"
: "${PORT:?PORT is required}"

# Write zou's config.py at runtime so it picks up Railway's env vars.
# Zou loads this file via the APP_SETTINGS env var (Flask config from envvar).
# This is the authoritative way to configure zou — env vars alone are not
# read by zou's default config loader; a Python config file is required.
mkdir -p /etc/zou
cat > /etc/zou/config.py << ZOUCFG
# Auto-generated at container startup from Railway environment variables.
import os

SECRET_KEY = os.environ.get("SECRET_KEY", "$(openssl rand -hex 32)")
JWT_SECRET_KEY = os.environ.get("JWT_SECRET_KEY", "$(openssl rand -hex 32)")

# PostgreSQL — built from Railway's Postgres reference variables
DB_URI = "postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}"

# Redis — built from Railway's Redis reference variables
KV_STORE_BACKEND = "redis"
KV_STORE_HOST = "${REDIS_HOST}"
KV_STORE_PORT = ${REDIS_PORT:-6379}

# File storage paths
PREVIEW_FOLDER = "/opt/zou/previews"
TMP_FOLDER = "/opt/zou/tmp"
LOGS_FOLDER = "/opt/zou/logs"
BACKUP_FOLDER = "/opt/zou/backups"
ZOUCFG

export APP_SETTINGS="/etc/zou/config.py"

echo "DB_URI (host only): postgresql://${PGUSER}:***@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "KV_STORE_HOST: ${REDIS_HOST}"
echo "KV_STORE_PORT: ${REDIS_PORT:-6379}"
echo "APP_SETTINGS: $APP_SETTINGS"

# Wait for Postgres to be ready before running migrations
echo "Waiting for Postgres at ${PGHOST}:${PGPORT}..."
until pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -q; do
    echo "  Postgres not ready yet, retrying in 2s..."
    sleep 2
done
echo "Postgres is ready."

# Wait for Redis to be ready
echo "Waiting for Redis at ${REDIS_HOST}:${REDIS_PORT:-6379}..."
until redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT:-6379}" ping | grep -q PONG; do
    echo "  Redis not ready yet, retrying in 2s..."
    sleep 2
done
echo "Redis is ready."

# Initialize database schema and seed data
/opt/zou/zouenv/bin/zou init-db || true
/opt/zou/zouenv/bin/zou init-data || true

# Create default admin user (no-op if already exists)
/opt/zou/zouenv/bin/zou create-admin --password mysecretpassword admin@example.com || true

# Start Gunicorn on Railway's PORT
exec /opt/zou/zouenv/bin/gunicorn \
    -w 3 \
    -k gevent \
    -b 0.0.0.0:$PORT \
    --access-logfile - \
    --error-logfile - \
    zou.app:app
EOF

RUN chmod +x /start.sh

EXPOSE $PORT
CMD ["/start.sh"]

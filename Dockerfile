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

# Pre-create the config directory so the startup script can write into it.
RUN mkdir -p /etc/zou

# Tell zou where its config file lives. Setting this as a Docker ENV (not just
# a shell export) guarantees every process — gunicorn workers, zou CLI commands,
# and any future entrypoints — inherits the variable without relying on the
# shell export surviving across exec boundaries.
ENV APP_SETTINGS="/etc/zou/config.py"

# Create startup script.
# The outer heredoc uses 'EOF' (single-quoted) so that the script is written
# verbatim — no variable expansion happens at image-build time.
# The inner heredoc uses an unquoted delimiter (ZOUCFG) so that bash expands
# $PGHOST, $REDIS_HOST, etc. at *container start* time when the real Railway
# env vars are present.
RUN cat > /start.sh << 'OUTEREOF'
#!/bin/bash
set -e

echo "=== zou-api startup ==="
echo "Railway PORT:  $PORT"
echo "PGHOST:        $PGHOST"
echo "PGPORT:        $PGPORT"
echo "PGDATABASE:    $PGDATABASE"
echo "REDIS_HOST:    $REDIS_HOST"

# Validate required env vars — fail fast with a clear message if any are absent.
: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${REDIS_HOST:?REDIS_HOST is required}"
: "${PORT:?PORT is required}"

# Resolve Redis port: use $REDIS_PORT if set, otherwise default to 6379.
RESOLVED_REDIS_PORT="${REDIS_PORT:-6379}"

# Build the DB URI once so we can reuse it and log it safely.
DB_URI="postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}"

# Generate a random secret if none is provided.
RESOLVED_SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 32)}"
RESOLVED_JWT_SECRET_KEY="${JWT_SECRET_KEY:-$(openssl rand -hex 32)}"

# Write zou's config.py using printf so there is no heredoc nesting and no
# risk of the shell misinterpreting quotes or special characters inside the
# Python source. Every value is fully resolved before being written, so the
# resulting file is plain Python with no shell syntax — it imports cleanly.
printf '%s\n' \
    "# Auto-generated at container startup — do not edit by hand." \
    "# Source of truth: Railway environment variables." \
    "" \
    "SECRET_KEY = '${RESOLVED_SECRET_KEY}'" \
    "JWT_SECRET_KEY = '${RESOLVED_JWT_SECRET_KEY}'" \
    "" \
    "# PostgreSQL" \
    "DB_URI = '${DB_URI}'" \
    "" \
    "# Redis" \
    "KV_STORE_BACKEND = 'redis'" \
    "KV_STORE_HOST = '${REDIS_HOST}'" \
    "KV_STORE_PORT = ${RESOLVED_REDIS_PORT}" \
    "" \
    "# File storage paths" \
    "PREVIEW_FOLDER = '/opt/zou/previews'" \
    "TMP_FOLDER = '/opt/zou/tmp'" \
    "LOGS_FOLDER = '/opt/zou/logs'" \
    "BACKUP_FOLDER = '/opt/zou/backups'" \
    > /etc/zou/config.py

# Verify the generated file is syntactically valid Python before proceeding.
# If this fails the container exits immediately with a clear error rather than
# a confusing "connection refused" from zou trying to use its default config.
echo "Validating /etc/zou/config.py syntax..."
/opt/zou/zouenv/bin/python -c "
import ast, sys
with open('/etc/zou/config.py') as f:
    src = f.read()
try:
    ast.parse(src)
    print('  OK — config.py is valid Python')
except SyntaxError as e:
    print('  FAIL — syntax error in config.py:', e)
    print('--- config.py contents ---')
    print(src)
    sys.exit(1)
"

echo "APP_SETTINGS:  $APP_SETTINGS"
echo "DB_URI:        postgresql://${PGUSER}:***@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "KV_STORE_HOST: ${REDIS_HOST}:${RESOLVED_REDIS_PORT}"

# Confirm zou can actually import its config before we try to run migrations.
echo "Verifying zou can load config..."
/opt/zou/zouenv/bin/python -c "
import os, sys
cfg = os.environ.get('APP_SETTINGS', '')
print('  APP_SETTINGS =', repr(cfg))
if not cfg:
    print('  ERROR: APP_SETTINGS is not set')
    sys.exit(1)
import importlib.util
spec = importlib.util.spec_from_file_location('zou_config', cfg)
mod  = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print('  DB_URI      =', getattr(mod, 'DB_URI', '<missing>'))
print('  KV_STORE_HOST =', getattr(mod, 'KV_STORE_HOST', '<missing>'))
print('  KV_STORE_PORT =', getattr(mod, 'KV_STORE_PORT', '<missing>'))
print('  Config loaded successfully')
"

# Wait for Postgres to be ready before running migrations.
echo "Waiting for Postgres at ${PGHOST}:${PGPORT}..."
until pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -q; do
    echo "  Postgres not ready yet, retrying in 2s..."
    sleep 2
done
echo "Postgres is ready."

# Initialize database schema and seed data.
/opt/zou/zouenv/bin/zou init-db   || true
/opt/zou/zouenv/bin/zou init-data || true

# Create default admin user (no-op if already exists).
/opt/zou/zouenv/bin/zou create-admin --password mysecretpassword admin@example.com || true

# Start Gunicorn on Railway's PORT.
exec /opt/zou/zouenv/bin/gunicorn \
    -w 3 \
    -k gevent \
    -b "0.0.0.0:${PORT}" \
    --access-logfile - \
    --error-logfile - \
    zou.app:app
OUTEREOF

RUN chmod +x /start.sh

EXPOSE $PORT
CMD ["/start.sh"]

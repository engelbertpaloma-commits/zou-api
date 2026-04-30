#!/bin/bash
set -e

echo "=========================================="
echo "Railway PORT: $PORT"
echo "DATABASE_URL: ${DATABASE_URL:-not set}"
echo "PGHOST: ${PGHOST:-not set}"
echo "PGPORT: ${PGPORT:-not set}"
echo "REDIS_URL: ${REDIS_URL:-not set}"
echo "REDIS_HOST: ${REDIS_HOST:-not set}"
echo "=========================================="

# Export standard PostgreSQL variables for Zou
if [ -n "$DATABASE_URL" ]; then
    echo "Using DATABASE_URL for database connection"
    export DB_HOST=""
    export DB_PORT=""
    export DB_USERNAME=""
    export DB_PASSWORD=""
    export DB_DATABASE=""
elif [ -n "$PGHOST" ]; then
    echo "Using PG* variables for database connection"
    export DB_HOST="$PGHOST"
    export DB_PORT="${PGPORT:-5432}"
    export DB_USERNAME="$PGUSER"
    export DB_PASSWORD="$PGPASSWORD"
    export DB_DATABASE="$PGDATABASE"
fi

# Export Redis variables - Zou expects these
if [ -n "$REDIS_URL" ]; then
    echo "Parsing REDIS_URL..."
    # Extract host from redis://user:pass@host:port/db
    export REDIS_HOST=$(echo "$REDIS_URL" | sed -n 's|redis://.*@\(.*\):[0-9]*.*|\1|p')
    export REDIS_PORT=$(echo "$REDIS_URL" | sed -n 's|redis://.*@.*:\([0-9]*\).*|\1|p')
    export REDIS_PASSWORD=$(echo "$REDIS_URL" | sed -n 's|redis://.*:\(.*\)@.*|\1|p')
fi

# Fallback for REDIS_HOST if still not set
if [ -z "$REDIS_HOST" ] && [ -n "$REDISHOST" ]; then
    export REDIS_HOST="$REDISHOST"
fi
if [ -z "$REDIS_PORT" ] && [ -n "$REDISPORT" ]; then
    export REDIS_PORT="$REDISPORT"
fi
if [ -z "$REDIS_PASSWORD" ] && [ -n "$REDISPASSWORD" ]; then
    export REDIS_PASSWORD="$REDISPASSWORD"
fi

echo "REDIS_HOST: ${REDIS_HOST:-not set}"
echo "REDIS_PORT: ${REDIS_PORT:-not set}"

# Initialize database (with retry)
echo "Initializing database..."
/opt/zou/zouenv/bin/zou init-db || echo "Database init failed or already exists"
/opt/zou/zouenv/bin/zou init-data || echo "Data init failed or already exists"

# Create default admin user
echo "Creating admin user..."
/opt/zou/zouenv/bin/zou create-admin --password mysecretpassword admin@example.com || echo "Admin user may already exist"

# Start Gunicorn on Railway's PORT
echo "Starting Gunicorn on port $PORT..."
exec /opt/zou/zouenv/bin/gunicorn \
    -w 3 \
    -k gevent \
    -b 0.0.0.0:$PORT \
    --access-logfile - \
    --error-logfile - \
    zou.app:app

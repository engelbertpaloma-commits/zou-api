FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    software-properties-common build-essential \
    postgresql-client postgresql-server-dev-all \
    redis-tools nginx xmlsec1 ffmpeg curl jq \
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
    && /opt/zou/zouenv/bin/pip install zou gunicorn[gevent] gevent-websocket

ENV PATH="/opt/zou/zouenv/bin:/usr/bin:$PATH"

# Create startup script
RUN cat > /start.sh << 'EOF'
#!/bin/bash
set -e

echo "Railway PORT: $PORT"
echo "DB_HOST: $DB_HOST"

# Initialize database
/opt/zou/zouenv/bin/zou init-db || true
/opt/zou/zouenv/bin/zou init-data || true

# Create default admin user
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

#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# First argument: base URL for scripts in Azure Storage
SCRIPTS_BASE_URL="${1:?Usage: vm-setup.sh <scripts-base-url>}"

# Update and install base dependencies (jq for parsing userData JSON from IMDS)
apt-get update
apt-get install -y python3 python3-pip python3-venv curl gnupg jq

# Install Microsoft ODBC driver for SQL Server
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main" > /etc/apt/sources.list.d/mssql-release.list
apt-get update
ACCEPT_EULA=Y apt-get install -y msodbcsql18 unixodbc-dev

# Create application directory
mkdir -p /opt/demo-app

# Create Python virtual environment and install dependencies
python3 -m venv /opt/demo-app/venv
/opt/demo-app/venv/bin/pip install --upgrade pip
/opt/demo-app/venv/bin/pip install flask pyodbc gunicorn

# Download the Flask application from Azure Storage
curl -fsSL "${SCRIPTS_BASE_URL}/app.py" -o /opt/demo-app/app.py

# Create startup wrapper script that fetches DB config from userData (IMDS)
cat > /opt/demo-app/start.sh << 'STARTEOF'
#!/bin/bash
set -e

# Fetch userData from Azure IMDS (returns base64-encoded JSON)
USER_DATA=$(curl -s -H "Metadata: true" \
  "http://169.254.169.254/metadata/instance/compute/userData?api-version=2021-01-01&format=text" \
  | base64 -d)

# Parse JSON and export as environment variables
export SQL_SERVER=$(echo "$USER_DATA" | jq -r '.sqlServer')
export SQL_DATABASE=$(echo "$USER_DATA" | jq -r '.sqlDatabase')
export SQL_USER=$(echo "$USER_DATA" | jq -r '.sqlUser')
export SQL_PASSWORD=$(echo "$USER_DATA" | jq -r '.sqlPassword')

# Start gunicorn with the Flask app
exec /opt/demo-app/venv/bin/gunicorn --bind 0.0.0.0:80 --workers 2 \
  --access-logfile /var/log/demo-app-access.log \
  --error-logfile /var/log/demo-app-error.log \
  app:app
STARTEOF

chmod 755 /opt/demo-app/start.sh

# Create systemd service (uses start.sh which fetches DB config from userData)
cat > /etc/systemd/system/demo-app.service << 'SVCEOF'
[Unit]
Description=Demo Flask App
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/demo-app
ExecStart=/opt/demo-app/start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# Enable and start the service
systemctl daemon-reload
systemctl enable demo-app
systemctl start demo-app

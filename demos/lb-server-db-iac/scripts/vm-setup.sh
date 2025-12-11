#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# SQL connection info (placeholders replaced by Bicep)
SQL_SERVER="{{SQL_SERVER}}"
SQL_DATABASE="{{SQL_DATABASE}}"
SQL_USER="{{SQL_USER}}"
SQL_PASSWORD="{{SQL_PASSWORD}}"

# Update and install base dependencies
apt-get update
apt-get install -y python3 python3-pip python3-venv curl gnupg

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

# Create the Flask application
cat > /opt/demo-app/app.py << 'PYEOF'
{{APP_PY}}
PYEOF

# Create environment file with SQL connection info
cat > /opt/demo-app/.env << ENVEOF
SQL_SERVER=${SQL_SERVER}
SQL_DATABASE=${SQL_DATABASE}
SQL_USER=${SQL_USER}
SQL_PASSWORD=${SQL_PASSWORD}
ENVEOF

chmod 600 /opt/demo-app/.env

# Create systemd service
cat > /etc/systemd/system/demo-app.service << 'SVCEOF'
[Unit]
Description=Demo Flask App
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/demo-app
EnvironmentFile=/opt/demo-app/.env
ExecStart=/opt/demo-app/venv/bin/gunicorn --bind 0.0.0.0:80 --workers 2 --access-logfile /var/log/demo-app-access.log --error-logfile /var/log/demo-app-error.log app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# Enable and start the service
systemctl daemon-reload
systemctl enable demo-app
systemctl start demo-app

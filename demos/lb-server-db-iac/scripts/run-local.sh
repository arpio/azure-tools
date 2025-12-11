#!/bin/bash
# Run the Flask app locally for testing (without a real database)

cd "$(dirname "$0")"

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

# Activate and install dependencies (flask only - pyodbc needs unixodbc)
source .venv/bin/activate
pip install -q flask

# Set dummy SQL environment variables
export SQL_SERVER="localhost"
export SQL_DATABASE="testdb"
export SQL_USER="testuser"
export SQL_PASSWORD="testpass"

echo "Starting Flask app on http://localhost:8080"
echo "Press Ctrl+C to stop"
echo ""

# Run with a mock pyodbc module so the app loads without the real driver
python3 -c "
import sys

# Create a mock pyodbc module
class MockPyodbc:
    def connect(self, *args, **kwargs):
        raise Exception('Mock mode - no database connection')

sys.modules['pyodbc'] = MockPyodbc()

import app
app.app.run(host='0.0.0.0', port=8080, debug=True)
"

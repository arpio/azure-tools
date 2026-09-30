#!/bin/bash
# Run the Flask Web App locally for testing (without real Azure services)

cd "$(dirname "$0")"

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

# Activate and install dependencies (flask + requests only - Azure SDK not needed locally)
source .venv/bin/activate
pip install -q flask requests

# Leave Azure env vars unset so the app shows "Not configured" status
# (the app handles missing clients gracefully)

echo "Starting Flask app on http://localhost:8080"
echo "Press Ctrl+C to stop"
echo ""

# Run with mock Azure modules so the app loads without the real SDKs
python3 -c "
import sys
import types

# Create mock Azure modules so imports succeed
for mod_name in [
    'azure', 'azure.identity', 'azure.keyvault', 'azure.keyvault.secrets',
]:
    sys.modules[mod_name] = types.ModuleType(mod_name)

# Provide the classes the app imports
class MockCredential:
    def __init__(self, **kwargs): pass

class MockSecretClient:
    def __init__(self, **kwargs): pass

sys.modules['azure.identity'].DefaultAzureCredential = MockCredential
sys.modules['azure.keyvault.secrets'].SecretClient = MockSecretClient

import app
app.app.run(host='0.0.0.0', port=8080, debug=True)
"

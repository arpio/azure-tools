"""
Azure Function - Status API (Arpio Demo 05)

HTTP-triggered function that returns JSON with hostname, runtime info,
Key Vault connectivity status, and Arpio tags. Called by the Web App
dashboard to display Function App health.

Uses the v1 programming model (function.json + __init__.py) so that
route registration survives Arpio DR recovery without redeployment.
"""
import json
import os
import socket
from datetime import datetime, timezone

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

# Config from environment (injected by Bicep app settings)
KEY_VAULT_URL = os.environ.get('KEY_VAULT_URL', '')
AZURE_CLIENT_ID = os.environ.get('AZURE_CLIENT_ID', '')

HOSTNAME = socket.gethostname()

# Azure clients (lazy-initialized)
_credential = None
_secret_client = None


def get_credential():
    global _credential
    if _credential is None:
        kwargs = {}
        if AZURE_CLIENT_ID:
            kwargs['managed_identity_client_id'] = AZURE_CLIENT_ID
        _credential = DefaultAzureCredential(**kwargs)
    return _credential


def get_secret_client():
    global _secret_client
    if _secret_client is None and KEY_VAULT_URL:
        _secret_client = SecretClient(vault_url=KEY_VAULT_URL, credential=get_credential())
    return _secret_client


def check_keyvault():
    """Check Key Vault connectivity and return status info."""
    client = get_secret_client()
    if not client:
        return {'configured': False, 'url': '', 'status': 'not_configured'}
    try:
        count = sum(1 for _ in client.list_properties_of_secrets())
        return {
            'configured': True,
            'url': KEY_VAULT_URL,
            'secretCount': count,
            'status': 'ok',
        }
    except Exception as e:
        return {
            'configured': True,
            'url': KEY_VAULT_URL,
            'status': 'error',
            'error': str(e),
        }


def main(req: func.HttpRequest) -> func.HttpResponse:
    """Return JSON status of the Function App and its connected services."""
    kv_status = check_keyvault()

    body = {
        'functionApp': {
            'hostname': HOSTNAME,
            'runtime': 'python',
            'status': 'running',
            'timestamp': datetime.now(timezone.utc).isoformat(),
        },
        'keyVault': kv_status,
        'tags': {
            'ArpioDemo05': 'True',
        },
    }

    return func.HttpResponse(
        json.dumps(body, indent=2),
        mimetype='application/json',
        status_code=200,
    )

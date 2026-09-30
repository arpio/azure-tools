"""
Flask Web App - Dashboard for Arpio Demo 05 (Web Apps, Functions & Container Apps)

Displays a dashboard with:
- Arpio logo loaded from Azure Blob Storage
- Web App hostname and status
- Key Vault secrets (demo-secret, app-region, storage-blob-url)
- Function App status (calls /api/status endpoint)
- Blob Storage info (account name, endpoint, logo preview)
- Container App background worker config (read live from the ARM API)

All Azure service access uses a user-assigned managed identity.
"""
import json
import os
import re
import socket
import html as html_lib

import requests
from flask import Flask

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

app = Flask(__name__)

# Config from environment (injected by Bicep app settings)
KEY_VAULT_URL = os.environ.get('KEY_VAULT_URL', '')
FUNCTION_APP_URL = os.environ.get('FUNCTION_APP_URL', '')
STORAGE_BLOB_URL = os.environ.get('STORAGE_BLOB_URL', '')
AZURE_CLIENT_ID = os.environ.get('AZURE_CLIENT_ID', '')
CONTAINER_APP_ID = os.environ.get('CONTAINER_APP_ID', '')
CONTAINER_APP_NAME = os.environ.get('CONTAINER_APP_NAME', '')

# Azure Resource Manager API version for Container Apps
CONTAINER_APPS_API_VERSION = '2024-03-01'

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


def check_service(name, check_fn):
    """Check connectivity to a service. Returns (status, detail)."""
    try:
        detail = check_fn()
        return ('ok', detail)
    except Exception as e:
        return ('error', f'{name}: {e}')


def check_keyvault():
    client = get_secret_client()
    if not client:
        return 'Not configured'
    count = sum(1 for _ in client.list_properties_of_secrets())
    return f'{count} secret(s)'


def read_secret(name):
    """Read a secret value from Key Vault. Returns None on failure."""
    client = get_secret_client()
    if not client:
        return None
    try:
        secret = client.get_secret(name)
        return secret.value
    except Exception:
        return None


def get_storage_account_name(blob_url):
    """Extract storage account name from blob endpoint URL."""
    if not blob_url:
        return None
    match = re.match(r'https://([^.]+)\.blob\.core\.windows\.net', blob_url)
    return match.group(1) if match else None


def parse_region_from_arm_id(arm_id):
    """Extract the region name from an ARM location resource ID.

    Format: /subscriptions/{sub}/providers/Microsoft.Resources/locations/{region}
    Returns the region string, or the raw value if it doesn't match the expected format.
    """
    if not arm_id:
        return None
    match = re.search(r'/providers/Microsoft\.Resources/locations/([^/]+)$', arm_id, re.IGNORECASE)
    return match.group(1) if match else arm_id


def get_logo_url():
    """Build the logo URL from the blob storage endpoint."""
    url = STORAGE_BLOB_URL
    if not url:
        return None
    return f'{url.rstrip("/")}/assets/arpio-logo.svg'


def get_favicon_url():
    """Build the favicon URL from the blob storage endpoint.

    Reuses STORAGE_BLOB_URL so after Arpio DR failover the favicon is served from
    the recovered storage account automatically.
    """
    url = STORAGE_BLOB_URL
    if not url:
        return None
    return f'{url.rstrip("/")}/assets/arpio-favicon.png'


def normalize_region(r):
    """Normalize an Azure region string to its slug form for comparison.
    "East US 2" / "eastus2" / " EastUS2 " -> "eastus2"
    """
    if not r:
        return None
    return r.lower().replace(' ', '').strip()


def get_container_app_config():
    """Read the Container App's live configuration from the Azure Resource Manager API.

    Uses the managed identity to get an ARM token, then queries the container app
    resource. Returns a dict with status, image, revision, and environment variables,
    or an error dict on failure. A background worker has no HTTP endpoint, so this
    is how we surface its configuration on the dashboard.
    """
    if not CONTAINER_APP_ID:
        return {'configured': False, 'error': 'CONTAINER_APP_ID not set'}
    try:
        token = get_credential().get_token('https://management.azure.com/.default')
        url = f'https://management.azure.com{CONTAINER_APP_ID}?api-version={CONTAINER_APPS_API_VERSION}'
        resp = requests.get(
            url,
            headers={'Authorization': f'Bearer {token.token}'},
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()
        props = data.get('properties', {})
        template = props.get('template', {})
        containers = template.get('containers', [])
        first = containers[0] if containers else {}
        env_list = first.get('env', [])
        # ARM returns env as a list of {name, value} (and secretRef for secrets)
        env = {e.get('name'): e.get('value', e.get('secretRef', '')) for e in env_list}
        return {
            'configured': True,
            'name': data.get('name'),
            'location': data.get('location'),
            'provisioningState': props.get('provisioningState'),
            'runningStatus': props.get('runningStatus'),
            'image': first.get('image'),
            'latestRevision': props.get('latestRevisionName'),
            'env': env,
            'status': 'ok',
        }
    except Exception as e:
        return {'configured': True, 'status': 'error', 'error': str(e)}


def call_function_app():
    """Call the Function App's /api/status endpoint."""
    if not FUNCTION_APP_URL:
        return {'status': 'not_configured', 'error': 'FUNCTION_APP_URL not set'}
    try:
        resp = requests.get(f'{FUNCTION_APP_URL}/api/status', timeout=15)
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.Timeout:
        return {'status': 'timeout', 'error': 'Function App may be cold-starting. Try refreshing in a few seconds.'}
    except Exception as e:
        return {'status': 'error', 'error': str(e)}


# --- HTML helpers ---

STYLE = """
        body { font-family: Arial, sans-serif; max-width: 900px; margin: 50px auto; padding: 20px;
               background: #f5f6fa; }
        h1 { color: #333; }
        h2 { color: #555; margin-top: 30px; }
        .header { text-align: center; margin-bottom: 30px; }
        .header img { height: 60px; margin-bottom: 10px; }
        .header h1 { margin: 5px 0; }
        .header .subtitle { color: #666; font-size: 14px; }
        .hostname { background: #e7f3ff; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .region-badge { display: inline-block; padding: 4px 12px; border-radius: 15px;
                        background: #667eea; color: white; font-weight: bold; font-size: 13px; }
        .status { padding: 10px; border-radius: 5px; margin-bottom: 10px; }
        .status.ok { background: #d4edda; color: #155724; }
        .status.error { background: #f8d7da; color: #721c24; }
        .status.info { background: #e7f3ff; color: #004085; }
        .card { background: #fff; border: 1px solid #dee2e6; border-radius: 8px;
                padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.05); }
        .card h3 { margin-top: 0; color: #333; }
        table { width: 100%; border-collapse: collapse; margin: 10px 0; }
        th, td { padding: 10px 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f8f9fa; }
        pre { background: #f8f9fa; padding: 15px; border-radius: 5px; overflow-x: auto;
              font-size: 13px; line-height: 1.4; }
        .secret-value { background: #fff3cd; padding: 8px 12px; border-radius: 5px;
                        border: 1px solid #ffc107; font-family: monospace; font-size: 13px; }
        .badge { display: inline-block; padding: 3px 8px; border-radius: 12px;
                 font-size: 12px; font-weight: bold; }
        .badge.ok { background: #d4edda; color: #155724; }
        .badge.error { background: #f8d7da; color: #721c24; }
        .logo-preview { display: block; margin: 10px 0; max-width: 200px; }
        .mono { font-family: monospace; font-size: 13px; }
        .dr-banner { background: #fff3cd; border: 2px solid #ffc107; border-radius: 8px;
                     padding: 15px; margin-bottom: 20px; text-align: center; }
        .dr-banner.match { background: #d4edda; border-color: #28a745; }
        /* DR-active state: when the running region differs from the configured region,
           paint the whole page light orange and surface a prominent banner. */
        body.dr-active { background: #ffe8d1; }
        body.dr-active .card { border-color: #ff9933; }
        .dr-active-banner { background: #ff7700; color: #fff; padding: 14px 20px;
                            border-radius: 8px; margin-bottom: 20px; text-align: center;
                            font-weight: bold; font-size: 15px;
                            box-shadow: 0 2px 6px rgba(0,0,0,0.15); }
        .region-badge.dr { background: #ff7700; }
"""


def page_header(title, logo_url=None, favicon_url=None, body_class=''):
    logo_html = ''
    if logo_url:
        logo_html = f'<img src="{html_lib.escape(logo_url)}" alt="Arpio" onerror="this.style.display=\'none\'">'
    favicon_html = ''
    if favicon_url:
        favicon_html = f'<link rel="icon" type="image/png" href="{html_lib.escape(favicon_url)}">'
    body_attr = f' class="{html_lib.escape(body_class)}"' if body_class else ''
    return f"""<!DOCTYPE html>
<html>
<head>
    <title>{html_lib.escape(title)}</title>
    {favicon_html}
    <style>{STYLE}</style>
</head>
<body{body_attr}>
    <div class="header">
        {logo_html}
        <h1>{html_lib.escape(title)}</h1>
        <div class="subtitle">Hostname: <strong>{html_lib.escape(HOSTNAME)}</strong></div>
    </div>
"""


PAGE_FOOTER = """
</body>
</html>
"""


@app.route('/')
def dashboard():
    # Read Key Vault secrets
    kv_status, kv_detail = check_service('Key Vault', check_keyvault)
    demo_secret_value = read_secret('demo-secret')
    region_arm_id = read_secret('app-region')
    region_value = parse_region_from_arm_id(region_arm_id)
    storage_blob_url_from_kv = read_secret('storage-blob-url')

    # Build logo / favicon URLs from env var (direct from Bicep app setting).
    # Both are served from the blob storage account, which Arpio recovers and
    # translates STORAGE_BLOB_URL for — so favicon/logo follow the app to DR.
    logo_url = get_logo_url()
    favicon_url = get_favicon_url()

    # Storage account info
    storage_account_name = get_storage_account_name(STORAGE_BLOB_URL)

    # Call Function App
    func_data = call_function_app()
    func_ok = isinstance(func_data, dict) and func_data.get('functionApp', {}).get('status') == 'running'

    # Container App config (read live from ARM). We use its `location` as the
    # *actual* region the app stack is running in — Azure populates this when
    # Arpio creates the recovered Container App in the failover region.
    ca = get_container_app_config()
    running_region = ca.get('location') if ca.get('status') == 'ok' else None

    # DR detection: configured region (from KV secret) vs actual running region.
    # Arpio translates the subscription segment of app-region but leaves the
    # location segment as-is, so the KV-secret region reflects the *original*
    # (primary) region. When the Container App's actual location differs, DR
    # is active.
    expected_norm = normalize_region(region_value)
    running_norm = normalize_region(running_region)
    dr_active = bool(expected_norm and running_norm and expected_norm != running_norm)

    body_class = 'dr-active' if dr_active else ''
    html = page_header(
        'Arpio Demo 05 - Web Apps, Functions & Container Apps',
        logo_url=logo_url,
        favicon_url=favicon_url,
        body_class=body_class,
    )

    # -- DR-active banner (only when running region differs from configured) --
    if dr_active:
        html += f"""
    <div class="dr-active-banner">
        DR Recovery Detected &mdash; this app is running in
        <strong>{html_lib.escape(running_region)}</strong>
        but was originally configured for
        <strong>{html_lib.escape(region_value)}</strong>.
    </div>
    """

    # -- Region card: shows the actual running region (Container App location) --
    badge_display = running_region or region_value or 'unknown'
    badge_class = 'region-badge dr' if dr_active else 'region-badge'
    html += f"""
    <div class="card" style="text-align: center;">
        <span class="{badge_class}">{html_lib.escape(badge_display)}</span>
        <p style="margin: 10px 0 0 0; color: #666; font-size: 13px;">
            Actual running region (read live from the Container App's
            <code>location</code> via Azure Resource Manager).<br>
            Configured region in <code>app-region</code> Key Vault secret:
            <strong>{html_lib.escape(region_value or 'unknown')}</strong>
            (Arpio translates the subscription segment, leaves location as-is).
        </p>
    </div>
    """

    # -- Web App card --
    html += """
    <div class="card">
        <h3>Web App</h3>
        <table>
            <tr><th>Property</th><th>Value</th></tr>
            <tr><td>Hostname</td><td>{hostname}</td></tr>
            <tr><td>Runtime</td><td>Python 3.12 / Flask</td></tr>
            <tr><td>Status</td><td><span class="badge ok">Running</span></td></tr>
        </table>
    </div>
    """.format(hostname=html_lib.escape(HOSTNAME))

    # -- Key Vault card --
    kv_badge = f'<span class="badge {kv_status}">{html_lib.escape(kv_detail)}</span>'
    html += f"""
    <div class="card">
        <h3>Key Vault</h3>
        <div class="status {kv_status}">Status: {kv_badge}</div>
        <table>
            <tr><th>Property</th><th>Value</th></tr>
            <tr><td>URL</td><td class="mono"><small>{html_lib.escape(KEY_VAULT_URL or 'Not configured')}</small></td></tr>
            <tr><td>Connection</td><td>{kv_badge}</td></tr>
    """
    if demo_secret_value:
        html += f'        <tr><td><code>demo-secret</code></td><td class="secret-value">{html_lib.escape(demo_secret_value)}</td></tr>\n'
    if region_arm_id:
        html += f'        <tr><td><code>app-region</code></td><td class="secret-value" style="word-break:break-all">{html_lib.escape(region_arm_id)}</td></tr>\n'
    if storage_blob_url_from_kv:
        html += f'        <tr><td><code>storage-blob-url</code></td><td class="secret-value">{html_lib.escape(storage_blob_url_from_kv)}</td></tr>\n'
    html += """
        </table>
    </div>
    """

    # -- Blob Storage card --
    html += f"""
    <div class="card">
        <h3>Blob Storage</h3>
        <table>
            <tr><th>Property</th><th>Value</th></tr>
            <tr><td>Storage Account</td><td class="mono">{html_lib.escape(storage_account_name or 'Not configured')}</td></tr>
            <tr><td>Blob Endpoint</td><td class="mono"><small>{html_lib.escape(STORAGE_BLOB_URL or 'Not configured')}</small></td></tr>
            <tr><td>Container</td><td class="mono">assets</td></tr>
    """
    if logo_url:
        html += f"""
            <tr><td>Logo Blob</td><td><a href="{html_lib.escape(logo_url)}" target="_blank">arpio-logo.svg</a></td></tr>
            <tr>
                <td>Logo Preview</td>
                <td><img src="{html_lib.escape(logo_url)}" alt="Arpio Logo from Blob" class="logo-preview"
                         onerror="this.parentElement.innerHTML='<span class=\\'badge error\\'>Failed to load from blob storage</span>'"></td>
            </tr>
    """
    html += """
        </table>
    </div>
    """

    # -- Function App card --
    func_badge_class = 'ok' if func_ok else 'error'
    func_badge_text = 'Connected' if func_ok else 'Unavailable'
    html += f"""
    <div class="card">
        <h3>Function App (Status API)</h3>
        <div class="status {func_badge_class}">Status: <span class="badge {func_badge_class}">{func_badge_text}</span></div>
        <table>
            <tr><th>Property</th><th>Value</th></tr>
            <tr><td>URL</td><td class="mono"><small>{html_lib.escape(FUNCTION_APP_URL or 'Not configured')}</small></td></tr>
    """

    if func_ok:
        func_info = func_data.get('functionApp', {})
        func_kv = func_data.get('keyVault', {})
        html += f"""
            <tr><td>Function Hostname</td><td>{html_lib.escape(func_info.get('hostname', 'N/A'))}</td></tr>
            <tr><td>Function Runtime</td><td>{html_lib.escape(func_info.get('runtime', 'N/A'))}</td></tr>
            <tr><td>Function KV Status</td><td>{html_lib.escape(func_kv.get('status', 'N/A'))}</td></tr>
            <tr><td>Timestamp</td><td>{html_lib.escape(func_info.get('timestamp', 'N/A'))}</td></tr>
        """
    elif 'error' in func_data:
        html += f'        <tr><td>Error</td><td class="secret-value">{html_lib.escape(str(func_data["error"]))}</td></tr>\n'

    html += """
        </table>
    """

    # Show raw JSON response if available
    if func_ok:
        html += f'    <details><summary>Raw JSON response</summary><pre>{html_lib.escape(json.dumps(func_data, indent=2))}</pre></details>\n'

    html += '    </div>\n'

    # -- Container App card (background worker) --
    # `ca` was already fetched at the top of the dashboard for DR detection.
    ca_ok = ca.get('status') == 'ok'
    ca_badge_class = 'ok' if ca_ok else 'error'
    ca_badge_text = ca.get('runningStatus') or ('Running' if ca_ok else 'Unavailable')
    html += f"""
    <div class="card">
        <h3>Container App (Background Worker)</h3>
        <div class="status {ca_badge_class}">Status: <span class="badge {ca_badge_class}">{html_lib.escape(str(ca_badge_text))}</span></div>
        <table>
            <tr><th>Property</th><th>Value</th></tr>
            <tr><td>Name</td><td class="mono">{html_lib.escape(str(ca.get('name') or CONTAINER_APP_NAME or 'Not configured'))}</td></tr>
    """
    if ca_ok:
        html += f"""
            <tr><td>Image</td><td class="mono"><small>{html_lib.escape(str(ca.get('image', 'N/A')))}</small></td></tr>
            <tr><td>Provisioning State</td><td>{html_lib.escape(str(ca.get('provisioningState', 'N/A')))}</td></tr>
            <tr><td>Latest Revision</td><td class="mono"><small>{html_lib.escape(str(ca.get('latestRevision', 'N/A')))}</small></td></tr>
            <tr><td>Location</td><td>{html_lib.escape(str(ca.get('location', 'N/A')))}</td></tr>
        """
        # Display the worker's environment variables (its "configuration")
        env = ca.get('env', {})
        if env:
            html += '            <tr><td>Environment Variables</td><td>'
            for k, v in env.items():
                html += f'<div class="secret-value" style="margin:2px 0;word-break:break-all"><strong>{html_lib.escape(str(k))}</strong> = {html_lib.escape(str(v))}</div>'
            html += '</td></tr>\n'
    elif 'error' in ca:
        html += f'        <tr><td>Error</td><td class="secret-value">{html_lib.escape(str(ca["error"]))}</td></tr>\n'

    html += """
        </table>
        <p style="color:#666;font-size:13px;margin:5px 0 0 0;">
            Background worker (no HTTP endpoint) &mdash; its configuration is read live
            from the Azure Resource Manager API using the managed identity.
        </p>
    </div>
    """

    # -- Resource summary card --
    html += """
    <div class="card">
        <h3>Resource Summary</h3>
        <p>All resources are tagged with <code>ArpioDemo05: True</code> for Arpio DR discovery.</p>
        <table>
            <tr><th>Resource</th><th>Type</th><th>Details</th></tr>
            <tr><td>Web App</td><td>Microsoft.Web/sites</td><td>Flask dashboard (this page)</td></tr>
            <tr><td>Function App</td><td>Microsoft.Web/sites</td><td>HTTP-triggered Status API</td></tr>
            <tr><td>Key Vault</td><td>Microsoft.KeyVault/vaults</td><td>demo-secret, app-region, storage-blob-url</td></tr>
            <tr><td>Blob Storage</td><td>Microsoft.Storage/storageAccounts</td><td>Arpio logo in assets container</td></tr>
            <tr><td>App Service Plan</td><td>Microsoft.Web/serverfarms</td><td>Basic B1 (Web App)</td></tr>
            <tr><td>Function Plan</td><td>Microsoft.Web/serverfarms</td><td>Basic B1 (Function App)</td></tr>
            <tr><td>Function Storage</td><td>Microsoft.Storage/storageAccounts</td><td>Function App backing store</td></tr>
            <tr><td>Container App</td><td>Microsoft.App/containerApps</td><td>Background worker (busybox heartbeat)</td></tr>
            <tr><td>Container Env</td><td>Microsoft.App/managedEnvironments</td><td>Container Apps hosting environment</td></tr>
            <tr><td>Log Analytics</td><td>Microsoft.OperationalInsights/workspaces</td><td>Container App logs</td></tr>
            <tr><td>Managed Identity</td><td>Microsoft.ManagedIdentity</td><td>Shared by Web App, Function App, Container App</td></tr>
        </table>
    </div>
    """

    html += PAGE_FOOTER
    return html


@app.route('/health')
def health():
    return 'OK', 200

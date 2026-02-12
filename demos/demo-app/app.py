"""
Flask demo app - Key Vault secrets, Blob Storage, and Queue Storage operations.
Displays hostname and provides CRUD for Azure services via managed identity.
"""
import os
import socket
import html as html_lib

from flask import Flask, request, redirect, url_for, session

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.blob import BlobServiceClient
from azure.storage.queue import QueueClient

app = Flask(__name__)
app.secret_key = 'demo-app-fixed-secret-key-for-app-gateway'

# Config from environment (injected by ACI)
KEY_VAULT_URL = os.environ.get('KEY_VAULT_URL', '')
STORAGE_ACCOUNT_URL = os.environ.get('STORAGE_ACCOUNT_URL', '')
QUEUE_ACCOUNT_URL = os.environ.get('QUEUE_ACCOUNT_URL', '')
QUEUE_NAME = os.environ.get('QUEUE_NAME', 'demo-queue')
BLOB_CONTAINER = os.environ.get('BLOB_CONTAINER', 'demo-blobs')
AZURE_CLIENT_ID = os.environ.get('AZURE_CLIENT_ID', '')

HOSTNAME = socket.gethostname()

# Azure clients (lazy-initialized)
_credential = None
_secret_client = None
_blob_service_client = None
_queue_client = None


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


def get_blob_service_client():
    global _blob_service_client
    if _blob_service_client is None and STORAGE_ACCOUNT_URL:
        _blob_service_client = BlobServiceClient(account_url=STORAGE_ACCOUNT_URL, credential=get_credential())
    return _blob_service_client


def get_queue_client():
    global _queue_client
    if _queue_client is None and QUEUE_ACCOUNT_URL:
        _queue_client = QueueClient(account_url=QUEUE_ACCOUNT_URL, queue_name=QUEUE_NAME, credential=get_credential())
    return _queue_client


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
    # List secrets to verify connectivity
    count = sum(1 for _ in client.list_properties_of_secrets())
    return f'{count} secret(s)'


def check_blob():
    client = get_blob_service_client()
    if not client:
        return 'Not configured'
    container = client.get_container_client(BLOB_CONTAINER)
    count = sum(1 for _ in container.list_blobs())
    return f'{count} blob(s)'


def check_queue():
    client = get_queue_client()
    if not client:
        return 'Not configured'
    props = client.get_queue_properties()
    count = props.approximate_message_count
    return f'~{count} message(s)'


# --- HTML helpers ---

STYLE = """
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
        h1 { color: #333; }
        .hostname { background: #e7f3ff; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .status { padding: 10px; border-radius: 5px; margin-bottom: 10px; }
        .status.ok { background: #d4edda; color: #155724; }
        .status.error { background: #f8d7da; color: #721c24; }
        .nav { margin-bottom: 20px; }
        .nav a { display: inline-block; padding: 10px 20px; background: #007bff; color: white;
                 text-decoration: none; border-radius: 4px; margin-right: 8px; margin-bottom: 8px; }
        .nav a:hover { background: #0056b3; }
        .nav a.active { background: #0056b3; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f8f9fa; }
        form { margin: 20px 0; }
        input[type="text"], textarea { padding: 10px; width: 300px; border: 1px solid #ccc; border-radius: 4px; }
        textarea { width: 400px; height: 80px; vertical-align: top; }
        button { padding: 10px 20px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:hover { background: #0056b3; }
        .delete-btn { background: #dc3545; padding: 5px 10px; font-size: 12px; }
        .delete-btn:hover { background: #c82333; }
        .download-btn { background: #28a745; padding: 5px 10px; font-size: 12px; }
        .download-btn:hover { background: #218838; }
        .back { display: inline-block; margin-bottom: 15px; color: #007bff; text-decoration: none; }
        .back:hover { text-decoration: underline; }
        pre { background: #f8f9fa; padding: 15px; border-radius: 5px; overflow-x: auto; }
"""


def page_header(title, active=None):
    error_msg = session.pop('error', None)
    success_msg = session.pop('success', None)

    nav_items = [
        ('/', 'Dashboard', 'dashboard'),
        ('/secrets', 'Secrets', 'secrets'),
        ('/blobs', 'Blobs', 'blobs'),
        ('/queues', 'Queues', 'queues'),
    ]
    nav_html = ''
    for href, label, key in nav_items:
        cls = ' class="active"' if key == active else ''
        nav_html += f'<a href="{href}"{cls}>{label}</a>'

    flash = ''
    if error_msg:
        flash += f'<div class="status error"><strong>Error:</strong> {html_lib.escape(str(error_msg))}</div>'
    if success_msg:
        flash += f'<div class="status ok"><strong>Success:</strong> {html_lib.escape(str(success_msg))}</div>'

    return f"""<!DOCTYPE html>
<html>
<head>
    <title>{title} - {HOSTNAME}</title>
    <style>{STYLE}
    </style>
</head>
<body>
    <h1>{title}</h1>
    <div class="hostname"><strong>Hostname:</strong> {HOSTNAME}</div>
    <div class="nav">{nav_html}</div>
    {flash}
"""


PAGE_FOOTER = """
</body>
</html>"""


# --- Routes ---

@app.route('/health')
def health():
    return 'OK', 200


@app.route('/')
def index():
    kv_status, kv_detail = check_service('Key Vault', check_keyvault)
    blob_status, blob_detail = check_service('Blob Storage', check_blob)
    queue_status, queue_detail = check_service('Queue Storage', check_queue)

    html = page_header('Demo App', active='dashboard')
    html += f"""
    <h2>Service Status</h2>
    <div class="status {kv_status}">
        <strong>Key Vault:</strong> {html_lib.escape(kv_detail)}
        {f'<br><small>{html_lib.escape(KEY_VAULT_URL)}</small>' if KEY_VAULT_URL else ''}
    </div>
    <div class="status {blob_status}">
        <strong>Blob Storage:</strong> {html_lib.escape(blob_detail)}
        {f'<br><small>{html_lib.escape(STORAGE_ACCOUNT_URL)}/{html_lib.escape(BLOB_CONTAINER)}</small>' if STORAGE_ACCOUNT_URL else ''}
    </div>
    <div class="status {queue_status}">
        <strong>Queue Storage:</strong> {html_lib.escape(queue_detail)}
        {f'<br><small>{html_lib.escape(QUEUE_ACCOUNT_URL)}/{html_lib.escape(QUEUE_NAME)}</small>' if QUEUE_ACCOUNT_URL else ''}
    </div>
"""
    html += PAGE_FOOTER
    return html


# --- Secrets ---

@app.route('/secrets', methods=['GET', 'POST'])
def secrets():
    client = get_secret_client()
    if not client:
        session['error'] = 'Key Vault not configured'
        return redirect(url_for('index'))

    if request.method == 'POST':
        name = request.form.get('name', '').strip()
        value = request.form.get('value', '').strip()
        if name and value:
            try:
                client.set_secret(name, value)
                session['success'] = f'Secret "{name}" created'
            except Exception as e:
                session['error'] = f'Create secret failed: {e}'
        return redirect(url_for('secrets'))

    # GET - list secrets
    secret_list = []
    try:
        for prop in client.list_properties_of_secrets():
            secret_list.append(prop)
    except Exception as e:
        session['error'] = f'List secrets failed: {e}'

    html = page_header('Key Vault Secrets', active='secrets')
    html += """
    <h2>Add Secret</h2>
    <form method="POST">
        <input type="text" name="name" placeholder="Secret name" required>
        <input type="text" name="value" placeholder="Secret value" required>
        <button type="submit">Add Secret</button>
    </form>

    <h2>Secrets</h2>
    <table>
        <tr><th>Name</th><th>Created</th><th>Updated</th><th>Actions</th></tr>
"""
    if secret_list:
        for s in secret_list:
            name_escaped = html_lib.escape(s.name)
            created = s.created_on.strftime('%Y-%m-%d %H:%M') if s.created_on else 'N/A'
            updated = s.updated_on.strftime('%Y-%m-%d %H:%M') if s.updated_on else 'N/A'
            html += f"""        <tr>
            <td>{name_escaped}</td>
            <td>{created}</td>
            <td>{updated}</td>
            <td>
                <a href="/secrets/view/{name_escaped}" class="download-btn" style="color:white;text-decoration:none;">View</a>
                <form method="POST" action="/secrets/delete/{name_escaped}" style="display:inline;margin:0;">
                    <button type="submit" class="delete-btn">Delete</button>
                </form>
            </td>
        </tr>
"""
    else:
        html += '        <tr><td colspan="4">No secrets found.</td></tr>\n'

    html += '    </table>'
    html += PAGE_FOOTER
    return html


@app.route('/secrets/view/<name>')
def view_secret(name):
    client = get_secret_client()
    if not client:
        session['error'] = 'Key Vault not configured'
        return redirect(url_for('index'))
    try:
        secret = client.get_secret(name)
        html = page_header(f'Secret: {html_lib.escape(name)}', active='secrets')
        html += f"""
    <a href="/secrets" class="back">&larr; Back to Secrets</a>
    <h2>{html_lib.escape(name)}</h2>
    <pre>{html_lib.escape(secret.value)}</pre>
"""
        html += PAGE_FOOTER
        return html
    except Exception as e:
        session['error'] = f'View secret failed: {e}'
        return redirect(url_for('secrets'))


@app.route('/secrets/delete/<name>', methods=['POST'])
def delete_secret(name):
    client = get_secret_client()
    if not client:
        session['error'] = 'Key Vault not configured'
        return redirect(url_for('index'))
    try:
        client.begin_delete_secret(name)
        session['success'] = f'Secret "{name}" deleted'
    except Exception as e:
        session['error'] = f'Delete secret failed: {e}'
    return redirect(url_for('secrets'))


# --- Blobs ---

@app.route('/blobs', methods=['GET', 'POST'])
def blobs():
    client = get_blob_service_client()
    if not client:
        session['error'] = 'Blob Storage not configured'
        return redirect(url_for('index'))

    container = client.get_container_client(BLOB_CONTAINER)

    if request.method == 'POST':
        name = request.form.get('name', '').strip()
        content = request.form.get('content', '')
        if name:
            try:
                blob = container.get_blob_client(name)
                blob.upload_blob(content.encode('utf-8'), overwrite=True)
                session['success'] = f'Blob "{name}" uploaded'
            except Exception as e:
                session['error'] = f'Upload blob failed: {e}'
        return redirect(url_for('blobs'))

    # GET - list blobs
    blob_list = []
    try:
        for b in container.list_blobs():
            blob_list.append(b)
    except Exception as e:
        session['error'] = f'List blobs failed: {e}'

    html = page_header('Blob Storage', active='blobs')
    html += f"""
    <h2>Upload Text Blob</h2>
    <form method="POST">
        <input type="text" name="name" placeholder="Blob name (e.g. notes.txt)" required><br><br>
        <textarea name="content" placeholder="Text content..."></textarea><br><br>
        <button type="submit">Upload</button>
    </form>

    <h2>Blobs in "{html_lib.escape(BLOB_CONTAINER)}"</h2>
    <table>
        <tr><th>Name</th><th>Size</th><th>Last Modified</th><th>Actions</th></tr>
"""
    if blob_list:
        for b in blob_list:
            name_escaped = html_lib.escape(b.name)
            size = b.size
            modified = b.last_modified.strftime('%Y-%m-%d %H:%M') if b.last_modified else 'N/A'
            html += f"""        <tr>
            <td>{name_escaped}</td>
            <td>{size} bytes</td>
            <td>{modified}</td>
            <td>
                <a href="/blobs/download/{name_escaped}" class="download-btn" style="color:white;text-decoration:none;">Download</a>
                <form method="POST" action="/blobs/delete/{name_escaped}" style="display:inline;margin:0;">
                    <button type="submit" class="delete-btn">Delete</button>
                </form>
            </td>
        </tr>
"""
    else:
        html += '        <tr><td colspan="4">No blobs found.</td></tr>\n'

    html += '    </table>'
    html += PAGE_FOOTER
    return html


@app.route('/blobs/download/<path:name>')
def download_blob(name):
    client = get_blob_service_client()
    if not client:
        session['error'] = 'Blob Storage not configured'
        return redirect(url_for('index'))
    try:
        container = client.get_container_client(BLOB_CONTAINER)
        blob = container.get_blob_client(name)
        data = blob.download_blob().readall()
        html = page_header(f'Blob: {html_lib.escape(name)}', active='blobs')
        html += f"""
    <a href="/blobs" class="back">&larr; Back to Blobs</a>
    <h2>{html_lib.escape(name)}</h2>
    <pre>{html_lib.escape(data.decode('utf-8', errors='replace'))}</pre>
"""
        html += PAGE_FOOTER
        return html
    except Exception as e:
        session['error'] = f'Download blob failed: {e}'
        return redirect(url_for('blobs'))


@app.route('/blobs/delete/<path:name>', methods=['POST'])
def delete_blob(name):
    client = get_blob_service_client()
    if not client:
        session['error'] = 'Blob Storage not configured'
        return redirect(url_for('index'))
    try:
        container = client.get_container_client(BLOB_CONTAINER)
        container.delete_blob(name)
        session['success'] = f'Blob "{name}" deleted'
    except Exception as e:
        session['error'] = f'Delete blob failed: {e}'
    return redirect(url_for('blobs'))


# --- Queues ---

@app.route('/queues', methods=['GET', 'POST'])
def queues():
    client = get_queue_client()
    if not client:
        session['error'] = 'Queue Storage not configured'
        return redirect(url_for('index'))

    if request.method == 'POST':
        action = request.form.get('action', '')

        if action == 'send':
            message = request.form.get('message', '').strip()
            if message:
                try:
                    client.send_message(message)
                    session['success'] = 'Message sent'
                except Exception as e:
                    session['error'] = f'Send message failed: {e}'

        elif action == 'receive':
            try:
                messages = client.receive_messages(max_messages=1, visibility_timeout=30)
                msg = next(messages, None)
                if msg:
                    client.delete_message(msg)
                    session['success'] = f'Received and dequeued: "{msg.content}"'
                else:
                    session['success'] = 'Queue is empty'
            except Exception as e:
                session['error'] = f'Receive message failed: {e}'

        return redirect(url_for('queues'))

    # GET - show queue info
    try:
        props = client.get_queue_properties()
        count = props.approximate_message_count
    except Exception as e:
        session['error'] = f'Get queue info failed: {e}'
        count = '?'

    # Peek at messages
    peeked = []
    try:
        peeked = list(client.peek_messages(max_messages=5))
    except Exception:
        pass

    html = page_header('Queue Storage', active='queues')
    html += f"""
    <h2>Queue: {html_lib.escape(QUEUE_NAME)}</h2>
    <div class="status ok"><strong>Approximate message count:</strong> {count}</div>

    <h2>Send Message</h2>
    <form method="POST">
        <input type="hidden" name="action" value="send">
        <input type="text" name="message" placeholder="Message text..." required>
        <button type="submit">Send</button>
    </form>

    <h2>Receive Message</h2>
    <form method="POST">
        <input type="hidden" name="action" value="receive">
        <button type="submit">Receive &amp; Dequeue (1 message)</button>
    </form>

    <h2>Peek (up to 5 messages)</h2>
    <table>
        <tr><th>#</th><th>Content</th><th>Inserted</th><th>Dequeue Count</th></tr>
"""
    if peeked:
        for i, msg in enumerate(peeked, 1):
            inserted = msg.inserted_on.strftime('%Y-%m-%d %H:%M') if msg.inserted_on else 'N/A'
            html += f"""        <tr>
            <td>{i}</td>
            <td>{html_lib.escape(str(msg.content))}</td>
            <td>{inserted}</td>
            <td>{msg.dequeue_count}</td>
        </tr>
"""
    else:
        html += '        <tr><td colspan="4">No messages to peek.</td></tr>\n'

    html += '    </table>'
    html += PAGE_FOOTER
    return html


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)

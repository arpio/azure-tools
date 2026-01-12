"""
Flask demo app - CRUD operations with Azure SQL Database.
Displays hostname and allows adding/deleting messages.
Fetches external time via NAT Gateway to demonstrate outbound connectivity.
"""
import os
import socket
import pyodbc
import requests
from flask import Flask, request, redirect, url_for, session

app = Flask(__name__)
app.secret_key = 'demo-app-fixed-secret-key-for-load-balancer'

# SQL connection info (injected by Bicep via vm-setup.sh)
SQL_SERVER = os.environ.get('SQL_SERVER', '')
SQL_DATABASE = os.environ.get('SQL_DATABASE', '')
SQL_USER = os.environ.get('SQL_USER', '')
SQL_PASSWORD = os.environ.get('SQL_PASSWORD', '')
BLOB_STORAGE_URL = os.environ.get('BLOB_STORAGE_URL', '')
BLOB_STORAGE_ACCOUNT = os.environ.get('BLOB_STORAGE_ACCOUNT', '')

HOSTNAME = socket.gethostname()

def get_connection():
    """Get a connection to the SQL database."""
    conn_str = (
        f"Driver={{ODBC Driver 18 for SQL Server}};"
        f"Server={SQL_SERVER};"
        f"Database={SQL_DATABASE};"
        f"Uid={SQL_USER};"
        f"Pwd={SQL_PASSWORD};"
        f"Encrypt=yes;"
        f"TrustServerCertificate=no;"
    )
    return pyodbc.connect(conn_str)

def init_db():
    """Create the messages table if it doesn't exist."""
    try:
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='messages' AND xtype='U')
            CREATE TABLE messages (
                id INT IDENTITY(1,1) PRIMARY KEY,
                message NVARCHAR(500) NOT NULL,
                hostname NVARCHAR(100) NOT NULL,
                created_at DATETIME DEFAULT GETDATE()
            )
        """)
        conn.commit()
        conn.close()
        return True
    except Exception as e:
        print(f"DB init error: {e}")
        return False

def init_blob_access():
    """Setup external data source for reading from blob storage."""
    if not BLOB_STORAGE_ACCOUNT:
        return False
    try:
        conn = get_connection()
        cursor = conn.cursor()

        # Create master key if not exists
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
            CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'BulkDemo123!'
        """)
        conn.commit()

        # Create credential using managed identity
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.database_scoped_credentials WHERE name = 'BlobStorageCredential')
            CREATE DATABASE SCOPED CREDENTIAL BlobStorageCredential
            WITH IDENTITY = 'Managed Identity'
        """)
        conn.commit()

        # Check if external data source exists and has correct URL
        cursor.execute("SELECT location FROM sys.external_data_sources WHERE name = 'BlobStorage'")
        row = cursor.fetchone()

        if row is None:
            # Doesn't exist - create it
            cursor.execute(f"""
                CREATE EXTERNAL DATA SOURCE BlobStorage
                WITH (
                    TYPE = BLOB_STORAGE,
                    LOCATION = '{BLOB_STORAGE_URL}',
                    CREDENTIAL = BlobStorageCredential
                )
            """)
            conn.commit()
        elif row[0] != BLOB_STORAGE_URL:
            # Exists but URL is wrong (e.g., after DR) - recreate it
            cursor.execute("DROP EXTERNAL DATA SOURCE BlobStorage")
            conn.commit()
            cursor.execute(f"""
                CREATE EXTERNAL DATA SOURCE BlobStorage
                WITH (
                    TYPE = BLOB_STORAGE,
                    LOCATION = '{BLOB_STORAGE_URL}',
                    CREDENTIAL = BlobStorageCredential
                )
            """)
            conn.commit()
        # else: exists and URL matches - do nothing

        conn.close()
        return True
    except Exception as e:
        print(f"Blob access setup error: {e}")
        return False

def get_outbound_ip():
    """Fetch outbound public IP via NAT Gateway using ipify.org."""
    try:
        resp = requests.get('https://api.ipify.org?format=json', timeout=5)
        if resp.status_code == 200:
            data = resp.json()
            return {
                'ip': data.get('ip', 'N/A'),
                'status': 'OK'
            }
    except requests.exceptions.Timeout:
        return {'status': 'Timeout', 'ip': 'N/A'}
    except Exception as e:
        return {'status': f'Error: {e}', 'ip': 'N/A'}
    return {'status': 'Failed', 'ip': 'N/A'}

@app.route('/')
def index():
    """Display hostname, messages list, and add form."""
    db_status = "Connected"
    messages = []

    # Get any error/success messages from session
    error_msg = session.pop('error', None)
    success_msg = session.pop('success', None)

    try:
        conn = get_connection()
        init_db()
        cursor = conn.cursor()
        cursor.execute("SELECT id, message, hostname, created_at FROM messages ORDER BY created_at DESC")
        messages = cursor.fetchall()
        conn.close()
    except Exception as e:
        db_status = f"Error: {e}"

    # Fetch outbound IP via NAT Gateway
    outbound_ip = get_outbound_ip()

    # Build HTML response
    html = f"""<!DOCTYPE html>
<html>
<head>
    <title>Demo App - {HOSTNAME}</title>
    <style>
        body {{ font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }}
        h1 {{ color: #333; }}
        .hostname {{ background: #e7f3ff; padding: 15px; border-radius: 5px; margin-bottom: 20px; }}
        .status {{ padding: 10px; border-radius: 5px; margin-bottom: 20px; }}
        .status.ok {{ background: #d4edda; color: #155724; }}
        .status.error {{ background: #f8d7da; color: #721c24; }}
        table {{ width: 100%; border-collapse: collapse; margin: 20px 0; }}
        th, td {{ padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }}
        th {{ background: #f8f9fa; }}
        form {{ margin: 20px 0; }}
        input[type="text"] {{ padding: 10px; width: 300px; border: 1px solid #ccc; border-radius: 4px; }}
        button {{ padding: 10px 20px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }}
        button:hover {{ background: #0056b3; }}
        .delete-btn {{ background: #dc3545; padding: 5px 10px; font-size: 12px; }}
        .delete-btn:hover {{ background: #c82333; }}
        .blob-btn {{ background: #28a745; }}
        .blob-btn:hover {{ background: #218838; }}
    </style>
</head>
<body>
    <h1>Demo App</h1>

    <div class="hostname">
        <strong>Hostname:</strong> {HOSTNAME}
    </div>

    <div class="status {'ok' if db_status == 'Connected' else 'error'}">
        <strong>Database:</strong> {db_status}
        {f'<br><small>{SQL_SERVER} / {SQL_DATABASE}</small>' if db_status == 'Connected' else ''}
    </div>

    <div class="status {'ok' if outbound_ip['status'] == 'OK' else 'error'}">
        <strong>NAT Gateway (Outbound IP):</strong> {outbound_ip['status']}
        {f"<br><small>Public IP: {outbound_ip['ip']}</small>" if outbound_ip['status'] == 'OK' else ''}
    </div>

    {f'<div class="status error"><strong>Error:</strong> {error_msg}</div>' if error_msg else ''}
    {f'<div class="status ok"><strong>Success:</strong> {success_msg}</div>' if success_msg else ''}

    <h2>Add Message</h2>
    <form method="POST" action="/add" style="display: inline;">
        <input type="text" name="message" placeholder="Enter a message..." required>
        <button type="submit">Add</button>
    </form>
    <form method="POST" action="/import-from-blob" style="display: inline; margin-left: 10px;">
        <button type="submit" class="blob-btn" title="Import messages from Azure Blob Storage using SQL Server managed identity">Import from Blob</button>
    </form>

    <h2>Messages</h2>
    <table>
        <tr>
            <th>ID</th>
            <th>Message</th>
            <th>From Host</th>
            <th>Created</th>
            <th>Action</th>
        </tr>
"""

    if messages:
        for msg in messages:
            html += f"""        <tr>
            <td>{msg[0]}</td>
            <td>{msg[1]}</td>
            <td>{msg[2]}</td>
            <td>{msg[3]}</td>
            <td>
                <form method="POST" action="/delete/{msg[0]}" style="margin:0;">
                    <button type="submit" class="delete-btn">Delete</button>
                </form>
            </td>
        </tr>
"""
    else:
        html += """        <tr><td colspan="5">No messages yet. Add one above!</td></tr>
"""

    html += """    </table>
</body>
</html>"""

    return html

@app.route('/add', methods=['POST'])
def add_message():
    """Add a new message."""
    message = request.form.get('message', '').strip()
    if message:
        try:
            conn = get_connection()
            cursor = conn.cursor()
            cursor.execute(
                "INSERT INTO messages (message, hostname) VALUES (?, ?)",
                (message, HOSTNAME)
            )
            conn.commit()
            conn.close()
        except Exception as e:
            session['error'] = f"Add message failed: {e}"
    return redirect(url_for('index'))

@app.route('/delete/<int:msg_id>', methods=['POST'])
def delete_message(msg_id):
    """Delete a message by ID."""
    try:
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("DELETE FROM messages WHERE id = ?", (msg_id,))
        conn.commit()
        conn.close()
    except Exception as e:
        session['error'] = f"Delete failed: {e}"
    return redirect(url_for('index'))

@app.route('/import-from-blob', methods=['POST'])
def import_from_blob():
    """Import messages from blob storage CSV using SQL Server's outbound connection."""
    try:
        conn = get_connection()
        cursor = conn.cursor()

        # Ensure blob access is set up
        init_blob_access()

        # Read CSV from blob storage using OPENROWSET
        cursor.execute("""
            SELECT BulkColumn
            FROM OPENROWSET(
                BULK 'sample-data.csv',
                DATA_SOURCE = 'BlobStorage',
                SINGLE_CLOB
            ) AS data
        """)
        csv_content = cursor.fetchone()[0]

        # Parse CSV and insert messages
        lines = csv_content.strip().split('\n')
        count = 0
        for line in lines[1:]:  # Skip header row
            message = line.strip()
            if message:
                cursor.execute(
                    "INSERT INTO messages (message, hostname) VALUES (?, ?)",
                    (message, "Blob Import")
                )
                count += 1
        conn.commit()
        conn.close()
        session['success'] = f"Imported {count} messages from blob storage"
    except Exception as e:
        session['error'] = f"Blob import failed: {e}"
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)

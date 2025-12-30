"""
Flask demo app - CRUD operations with Azure SQL Database.
Displays hostname and allows adding/deleting messages.
Fetches external time via NAT Gateway to demonstrate outbound connectivity.
"""
import os
import socket
import pyodbc
import requests
from datetime import datetime
from flask import Flask, request, redirect, url_for

app = Flask(__name__)

# SQL connection info (injected by Bicep via vm-setup.sh)
SQL_SERVER = os.environ.get('SQL_SERVER', '')
SQL_DATABASE = os.environ.get('SQL_DATABASE', '')
SQL_USER = os.environ.get('SQL_USER', '')
SQL_PASSWORD = os.environ.get('SQL_PASSWORD', '')

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
    error_msg = ""

    try:
        conn = get_connection()
        init_db()
        cursor = conn.cursor()
        cursor.execute("SELECT id, message, hostname, created_at FROM messages ORDER BY created_at DESC")
        messages = cursor.fetchall()
        conn.close()
    except Exception as e:
        db_status = f"Error: {e}"
        error_msg = str(e)

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

    <h2>Add Message</h2>
    <form method="POST" action="/add">
        <input type="text" name="message" placeholder="Enter a message..." required>
        <button type="submit">Add</button>
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
            print(f"Add error: {e}")
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
        print(f"Delete error: {e}")
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)

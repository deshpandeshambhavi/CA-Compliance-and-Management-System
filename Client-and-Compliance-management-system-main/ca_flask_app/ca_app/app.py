from flask import Flask, render_template, request, redirect, url_for, flash
import mysql.connector
from mysql.connector import Error

app = Flask(__name__)
app.secret_key = 'ca_secret_key_2024'

# ── DB config ────────────────────────────────────────────────
DB_CONFIG = {
    'host':     'localhost',
    'user':     'root',
    'password': 'your_password',   # ← change this
    'database': 'ca_management'
}

def get_db():
    return mysql.connector.connect(**DB_CONFIG)

def query(sql, params=(), fetchone=False, commit=False):
    conn = get_db()
    cur  = conn.cursor(dictionary=True)
    cur.execute(sql, params)
    if commit:
        conn.commit()
        result = cur.rowcount
    elif fetchone:
        result = cur.fetchone()
    else:
        result = cur.fetchall()
    cur.close()
    conn.close()
    return result

# ── HOME ─────────────────────────────────────────────────────
@app.route('/')
def index():
    stats = {
        'clients':    query("SELECT COUNT(*) AS n FROM Client",     fetchone=True)['n'],
        'services':   query("SELECT COUNT(*) AS n FROM Service",    fetchone=True)['n'],
        'unpaid':     query("SELECT COUNT(*) AS n FROM Billing WHERE Payment_Status != 'Paid'", fetchone=True)['n'],
        'overdue':    query("SELECT COUNT(*) AS n FROM Compliance WHERE Status = 'Overdue'",    fetchone=True)['n'],
    }
    recent_compliance = query("""
        SELECT c.Name AS Client_Name, co.Type, co.Status, co.Due_Date
        FROM Compliance co JOIN Client c ON co.Client_ID = c.Client_ID
        ORDER BY co.Due_Date ASC LIMIT 5
    """)
    return render_template('index.html', stats=stats, recent_compliance=recent_compliance)

# ── CLIENTS ──────────────────────────────────────────────────
@app.route('/clients')
def clients():
    rows = query("SELECT * FROM Client ORDER BY Client_ID DESC")
    return render_template('clients.html', clients=rows)

@app.route('/clients/add', methods=['GET', 'POST'])
def add_client():
    if request.method == 'POST':
        try:
            query("INSERT INTO Client (Name, PAN, Phone, Email) VALUES (%s,%s,%s,%s)",
                  (request.form['name'], request.form['pan'],
                   request.form['phone'], request.form['email']), commit=True)
            flash('Client added successfully!', 'success')
            return redirect(url_for('clients'))
        except Error as e:
            flash(f'Error: {e}', 'danger')
    return render_template('add_client.html')

@app.route('/clients/<int:client_id>')
def client_report(client_id):
    client   = query("SELECT * FROM Client WHERE Client_ID=%s", (client_id,), fetchone=True)
    services = query("""
        SELECT s.Service_Name, s.Fees, cs.Usage_Date
        FROM Client_Service cs JOIN Service s ON cs.Service_ID=s.Service_ID
        WHERE cs.Client_ID=%s
    """, (client_id,))
    bills = query("SELECT * FROM Billing WHERE Client_ID=%s ORDER BY Bill_Date DESC", (client_id,))
    compliance = query("""
        SELECT co.*, r.Name AS Reg_Name
        FROM Compliance co JOIN Regulations r ON co.Reg_ID=r.Reg_ID
        WHERE co.Client_ID=%s ORDER BY co.Due_Date
    """, (client_id,))
    return render_template('client_report.html',
                           client=client, services=services,
                           bills=bills, compliance=compliance)

# ── SERVICES ─────────────────────────────────────────────────
@app.route('/services')
def services():
    rows = query("SELECT * FROM Service ORDER BY Service_ID")
    return render_template('services.html', services=rows)

@app.route('/services/add', methods=['GET', 'POST'])
def add_service():
    if request.method == 'POST':
        try:
            query("INSERT INTO Service (Service_Name, Fees) VALUES (%s,%s)",
                  (request.form['service_name'], request.form['fees']), commit=True)
            flash('Service added!', 'success')
            return redirect(url_for('services'))
        except Error as e:
            flash(f'Error: {e}', 'danger')
    return render_template('add_service.html')

@app.route('/services/assign', methods=['GET', 'POST'])
def assign_service():
    clients_list  = query("SELECT Client_ID, Name FROM Client")
    services_list = query("SELECT Service_ID, Service_Name, Fees FROM Service")
    if request.method == 'POST':
        try:
            query("INSERT INTO Client_Service (Client_ID, Service_ID, Usage_Date) VALUES (%s,%s,%s)",
                  (request.form['client_id'], request.form['service_id'],
                   request.form['usage_date']), commit=True)
            flash('Service assigned!', 'success')
            return redirect(url_for('services'))
        except Error as e:
            flash(f'Error: {e}', 'danger')
    return render_template('assign_service.html',
                           clients=clients_list, services=services_list)

# ── BILLING ──────────────────────────────────────────────────
@app.route('/billing')
def billing():
    rows = query("""
        SELECT b.*, c.Name AS Client_Name
        FROM Billing b JOIN Client c ON b.Client_ID=c.Client_ID
        ORDER BY b.Bill_Date DESC
    """)
    return render_template('billing.html', bills=rows)

@app.route('/billing/generate/<int:client_id>', methods=['POST'])
def generate_bill(client_id):
    try:
        conn = get_db()
        cur  = conn.cursor()
        cur.callproc('GenerateBill', [client_id])
        conn.commit()
        cur.close(); conn.close()
        flash('Bill generated successfully!', 'success')
    except Error as e:
        flash(f'Error: {e}', 'danger')
    return redirect(url_for('billing'))

@app.route('/billing/pay/<int:bill_id>', methods=['POST'])
def mark_paid(bill_id):
    query("UPDATE Billing SET Payment_Status='Paid' WHERE Bill_ID=%s",
          (bill_id,), commit=True)
    flash('Bill marked as Paid.', 'success')
    return redirect(url_for('billing'))

@app.route('/billing/mark-overdue', methods=['POST'])
def mark_overdue():
    try:
        conn = get_db()
        cur  = conn.cursor()
        cur.callproc('MarkOverdueBills')
        conn.commit()
        cur.close(); conn.close()
        flash('Overdue bills updated.', 'success')
    except Error as e:
        flash(f'Error: {e}', 'danger')
    return redirect(url_for('billing'))

# ── COMPLIANCE ───────────────────────────────────────────────
@app.route('/compliance')
def compliance():
    rows = query("""
        SELECT co.*, c.Name AS Client_Name, r.Name AS Reg_Name
        FROM Compliance co
        JOIN Client c      ON co.Client_ID = c.Client_ID
        JOIN Regulations r ON co.Reg_ID    = r.Reg_ID
        ORDER BY co.Due_Date
    """)
    return render_template('compliance.html', compliance=rows)

@app.route('/compliance/add', methods=['GET', 'POST'])
def add_compliance():
    clients_list = query("SELECT Client_ID, Name FROM Client")
    regs_list    = query("SELECT Reg_ID, Name FROM Regulations")
    if request.method == 'POST':
        try:
            query("""INSERT INTO Compliance (Type, Status, Due_Date, Reg_ID, Client_ID)
                     VALUES (%s,%s,%s,%s,%s)""",
                  (request.form['type'], request.form['status'],
                   request.form['due_date'], request.form['reg_id'],
                   request.form['client_id']), commit=True)
            flash('Compliance record added!', 'success')
            return redirect(url_for('compliance'))
        except Error as e:
            flash(f'Error: {e}', 'danger')
    return render_template('add_compliance.html',
                           clients=clients_list, regs=regs_list)

@app.route('/compliance/update/<int:compliance_id>', methods=['POST'])
def update_compliance(compliance_id):
    query("UPDATE Compliance SET Status=%s WHERE Compliance_ID=%s",
          (request.form['status'], compliance_id), commit=True)
    flash('Status updated.', 'success')
    return redirect(url_for('compliance'))

# ── REPORTS ──────────────────────────────────────────────────
@app.route('/reports')
def reports():
    revenue = query("""
        SELECT s.Service_Name, COUNT(cs.CS_ID) AS Times_Used, SUM(s.Fees) AS Total_Revenue
        FROM Client_Service cs JOIN Service s ON cs.Service_ID=s.Service_ID
        GROUP BY s.Service_ID, s.Service_Name ORDER BY Total_Revenue DESC
    """)
    multi_service_clients = query("""
        SELECT c.Name, COUNT(cs.CS_ID) AS Service_Count
        FROM Client_Service cs JOIN Client c ON cs.Client_ID=c.Client_ID
        GROUP BY cs.Client_ID HAVING COUNT(*) > 1 ORDER BY Service_Count DESC
    """)
    overdue_compliance = query("""
        SELECT c.Name AS Client_Name, co.Type, co.Due_Date
        FROM Compliance co JOIN Client c ON co.Client_ID=c.Client_ID
        WHERE co.Status='Overdue' ORDER BY co.Due_Date
    """)
    return render_template('reports.html',
                           revenue=revenue,
                           multi_service_clients=multi_service_clients,
                           overdue_compliance=overdue_compliance)

if __name__ == '__main__':
    app.run(debug=True)


import csv
from io import StringIO

from flask import Blueprint, Response, render_template

from app.db import get_db
from app.security import current_user, role_required


finance_bp = Blueprint(
    "finance",
    __name__,
    url_prefix="/finance"
)


@finance_bp.route("/")
@role_required("finance_lead")
def index():
    db = get_db()

    # Main finance dashboard figures
    summary = db.execute("""
        SELECT *
        FROM v_dashboard
    """).fetchone()

    # Monthly invoiced vs collected revenue
    monthly_revenue = db.execute("""
        SELECT month, invoiced, collected
        FROM v_monthly_revenue
        ORDER BY month DESC
        LIMIT 6
    """).fetchall()

    monthly_revenue = list(reversed(monthly_revenue))

    # Outstanding invoices
    outstanding_invoices = db.execute("""
        SELECT
            id,
            invoice_number,
            customer_name,
            invoice_date,
            due_date,
            total_amount,
            amount_paid,
            amount_due,
            display_status,
            days_overdue
        FROM v_outstanding_invoices
        ORDER BY is_overdue DESC, due_date ASC
        LIMIT 8
    """).fetchall()

    # Overdue invoices
    overdue_invoices = db.execute("""
        SELECT
            id,
            invoice_number,
            customer_name,
            due_date,
            amount_due,
            days_overdue
        FROM v_overdue_invoices
        ORDER BY days_overdue DESC
        LIMIT 5
    """).fetchall()

    # Recent payments
    recent_payments = db.execute("""
        SELECT
            p.id,
            p.payment_number,
            p.payment_date,
            p.method,
            p.amount,
            c.name AS customer_name,
            i.invoice_number
        FROM payments p
        JOIN customers c ON c.id = p.customer_id
        JOIN invoices i ON i.id = p.invoice_id
        ORDER BY p.payment_date DESC, p.id DESC
        LIMIT 8
    """).fetchall()

    # Recent invoices
    recent_invoices = db.execute("""
        SELECT
            i.id,
            i.invoice_number,
            i.invoice_date,
            i.due_date,
            i.status,
            i.total_amount,
            i.amount_paid,
            c.name AS customer_name
        FROM invoices i
        JOIN customers c ON c.id = i.customer_id
        WHERE i.status IN ('confirmed', 'paid')
        ORDER BY i.created_at DESC, i.id DESC
        LIMIT 5
    """).fetchall()

    return render_template(
        "finance/index.html",
        current_user=current_user(),
        summary=summary,
        monthly_revenue=monthly_revenue,
        outstanding_invoices=outstanding_invoices,
        overdue_invoices=overdue_invoices,
        recent_payments=recent_payments,
        recent_invoices=recent_invoices
    )


@finance_bp.route("/reports/revenue.csv")
@role_required("finance_lead")
def export_revenue_csv():
    db = get_db()

    rows = db.execute("""
        SELECT month, invoiced, collected
        FROM v_monthly_revenue
        ORDER BY month ASC
    """).fetchall()

    output = StringIO()
    writer = csv.writer(output)

    writer.writerow([
        "Month",
        "Invoiced (INR)",
        "Collected (INR)"
    ])

    for row in rows:
        writer.writerow([
            row["month"],
            f"{row['invoiced'] / 100:.2f}",
            f"{row['collected'] / 100:.2f}"
        ])

    response = Response(
        output.getvalue(),
        mimetype="text/csv"
    )

    response.headers["Content-Disposition"] = (
        "attachment; filename=staxio_revenue_report.csv"
    )

    return response

from flask import Blueprint, render_template

from app.db import get_db
from app.security import login_required, role_required


dashboard_bp = Blueprint(
    "dashboard",
    __name__,
    url_prefix="/dashboard"
)


@dashboard_bp.route("/")
@login_required
@role_required("admin", "staff")
def index():
    db = get_db()

    summary = db.execute(
        "SELECT * FROM v_dashboard"
    ).fetchone()

    monthly_revenue = db.execute("""
        SELECT month, invoiced, collected
        FROM v_monthly_revenue
        ORDER BY month DESC
        LIMIT 12
    """).fetchall()

    outstanding_invoices = db.execute("""
        SELECT *
        FROM v_outstanding_invoices
        ORDER BY is_overdue DESC, due_date ASC
        LIMIT 8
    """).fetchall()

    recent_subscriptions = db.execute("""
        SELECT
            id,
            subscription_number,
            customer_name,
            plan_name,
            status,
            start_date,
            next_billing_date,
            recurring_subtotal
        FROM v_subscription_overview
        ORDER BY id DESC
        LIMIT 8
    """).fetchall()

    recent_payments = db.execute("""
        SELECT
            p.id,
            p.payment_number,
            p.amount,
            p.method,
            p.payment_date,
            c.name AS customer_name,
            i.invoice_number
        FROM payments p
        JOIN customers c ON c.id = p.customer_id
        JOIN invoices i ON i.id = p.invoice_id
        ORDER BY p.payment_date DESC, p.id DESC
        LIMIT 8
    """).fetchall()

    return render_template(
        "dashboard/index.html",
        summary=summary,
        monthly_revenue=list(reversed(monthly_revenue)),
        outstanding_invoices=outstanding_invoices,
        recent_subscriptions=recent_subscriptions,
        recent_payments=recent_payments
    )
from flask import Blueprint, render_template

from app.db import get_db
from app.security import current_user, role_required

staff_bp = Blueprint("staff", __name__, url_prefix="/staff")


@staff_bp.route("/")
@role_required("staff")
def index():
    db = get_db()

    # Subscription overview
    subscription_summary = db.execute("""
        SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active,
            SUM(CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END) AS confirmed,
            SUM(CASE WHEN status = 'paused' THEN 1 ELSE 0 END) AS paused,
            SUM(CASE WHEN status = 'quotation' THEN 1 ELSE 0 END) AS quotations,
            SUM(CASE WHEN status = 'draft' THEN 1 ELSE 0 END) AS drafts
        FROM subscriptions
        WHERE status NOT IN ('cancelled', 'expired', 'closed')
    """).fetchone()

    # Invoice overview
    invoice_summary = db.execute("""
        SELECT
            COUNT(*) AS total,
            COALESCE(SUM(
                CASE WHEN status = 'confirmed'
                THEN 1 ELSE 0 END
            ), 0) AS unpaid,
            COALESCE(SUM(
                CASE WHEN status = 'paid'
                THEN 1 ELSE 0 END
            ), 0) AS paid,
            COALESCE(SUM(
                CASE WHEN status = 'confirmed'
                THEN total_amount - amount_paid ELSE 0 END
            ), 0) AS outstanding
        FROM invoices
        WHERE status IN ('confirmed', 'paid')
    """).fetchone()

    # Overdue invoices
    overdue_summary = db.execute("""
        SELECT
            COUNT(*) AS count,
            COALESCE(SUM(total_amount - amount_paid), 0) AS amount
        FROM invoices
        WHERE status = 'confirmed'
          AND due_date < date('now', 'localtime')
          AND total_amount > amount_paid
    """).fetchone()

    # Upcoming renewals/billing dates
    upcoming_billing = db.execute("""
        SELECT
            s.id,
            s.subscription_number,
            s.status,
            s.next_billing_date,
            c.name AS customer_name,
            p.name AS plan_name
        FROM subscriptions s
        JOIN customers c ON c.id = s.customer_id
        JOIN plans p ON p.id = s.plan_id
        WHERE s.status = 'active'
          AND s.next_billing_date IS NOT NULL
          AND s.next_billing_date >= date('now', 'localtime')
          AND s.next_billing_date <= date('now', 'localtime', '+7 days')
        ORDER BY s.next_billing_date ASC
        LIMIT 5
    """).fetchall()

    # Recently created subscriptions
    recent_subscriptions = db.execute("""
        SELECT
            s.id,
            s.subscription_number,
            s.status,
            s.created_at,
            c.name AS customer_name,
            p.name AS plan_name
        FROM subscriptions s
        JOIN customers c ON c.id = s.customer_id
        JOIN plans p ON p.id = s.plan_id
        ORDER BY s.created_at DESC, s.id DESC
        LIMIT 5
    """).fetchall()

    # Recently issued/confirmed invoices
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
        "staff/index.html",
        user=current_user(),
        subscription_summary=subscription_summary,
        invoice_summary=invoice_summary,
        overdue_summary=overdue_summary,
        upcoming_billing=upcoming_billing,
        recent_subscriptions=recent_subscriptions,
        recent_invoices=recent_invoices,
    )
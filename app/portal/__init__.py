from flask import Blueprint, abort, flash, redirect, render_template, url_for

from app.db import get_db
from app.security import current_user, login_required, role_required


portal_bp = Blueprint(
    "portal",
    __name__,
    url_prefix="/portal"
)


def get_portal_customer():
    user = current_user()

    if not user:
        return None

    return get_db().execute("""
        SELECT *
        FROM customers
        WHERE user_id = ?
    """, (user["id"],)).fetchone()


@portal_bp.route("/")
@login_required
@role_required("customer")
def index():
    db = get_db()
    customer = get_portal_customer()

    if not customer:
        return render_template(
            "portal/not_linked.html"
        ), 403

    summary = db.execute("""
        SELECT
            COUNT(*) AS invoice_count,
            COALESCE(SUM(total_amount), 0) AS total_invoiced,
            COALESCE(SUM(amount_paid), 0) AS total_paid
        FROM invoices
        WHERE customer_id = ?
          AND status IN ('confirmed', 'paid')
    """, (customer["id"],)).fetchone()

    active_subscriptions = db.execute("""
        SELECT
            s.id,
            s.subscription_number,
            s.status,
            s.start_date,
            s.expiry_date,
            s.next_billing_date,
            p.name AS plan_name
        FROM subscriptions s
        JOIN plans p ON p.id = s.plan_id
        WHERE s.customer_id = ?
          AND s.status IN ('confirmed', 'active', 'paused')
        ORDER BY s.id DESC
    """, (customer["id"],)).fetchall()

    outstanding = db.execute("""
        SELECT *
        FROM v_outstanding_invoices
        WHERE customer_id = ?
        ORDER BY due_date ASC
        LIMIT 5
    """, (customer["id"],)).fetchall()

    recent_invoices = db.execute("""
        SELECT
            id,
            invoice_number,
            invoice_date,
            due_date,
            status,
            total_amount,
            amount_paid,
            total_amount - amount_paid AS amount_due
        FROM invoices
        WHERE customer_id = ?
          AND status <> 'cancelled'
        ORDER BY invoice_date DESC, id DESC
        LIMIT 5
    """, (customer["id"],)).fetchall()

    return render_template(
        "portal/index.html",
        customer=customer,
        summary=summary,
        active_subscriptions=active_subscriptions,
        outstanding=outstanding,
        recent_invoices=recent_invoices
    )


@portal_bp.route("/subscriptions")
@login_required
@role_required("customer")
def subscriptions():
    customer = get_portal_customer()

    if not customer:
        return render_template("portal/not_linked.html"), 403

    rows = get_db().execute("""
        SELECT
            s.*,
            p.name AS plan_name,
            p.billing_frequency,
            p.billing_interval
        FROM subscriptions s
        JOIN plans p ON p.id = s.plan_id
        WHERE s.customer_id = ?
        ORDER BY s.id DESC
    """, (customer["id"],)).fetchall()

    return render_template(
        "portal/subscriptions.html",
        customer=customer,
        subscriptions=rows
    )


@portal_bp.route("/subscriptions/<int:subscription_id>")
@login_required
@role_required("customer")
def subscription_detail(subscription_id):
    customer = get_portal_customer()

    if not customer:
        return render_template("portal/not_linked.html"), 403

    db = get_db()

    subscription = db.execute("""
        SELECT
            s.*,
            p.name AS plan_name,
            p.billing_frequency,
            p.billing_interval
        FROM subscriptions s
        JOIN plans p ON p.id = s.plan_id
        WHERE s.id = ?
          AND s.customer_id = ?
    """, (subscription_id, customer["id"])).fetchone()

    if not subscription:
        abort(404)

    lines = db.execute("""
        SELECT
            sl.*,
            p.name AS product_name
        FROM subscription_lines sl
        LEFT JOIN products p ON p.id = sl.product_id
        WHERE sl.subscription_id = ?
        ORDER BY sl.id
    """, (subscription_id,)).fetchall()

    events = db.execute("""
        SELECT from_status, to_status, created_at
        FROM subscription_events
        WHERE subscription_id = ?
        ORDER BY id DESC
    """, (subscription_id,)).fetchall()

    return render_template(
        "portal/subscription_detail.html",
        customer=customer,
        subscription=subscription,
        lines=lines,
        events=events
    )


@portal_bp.route("/invoices")
@login_required
@role_required("customer")
def invoices():
    customer = get_portal_customer()

    if not customer:
        return render_template("portal/not_linked.html"), 403

    rows = get_db().execute("""
        SELECT
            i.id,
            i.invoice_number,
            i.invoice_date,
            i.due_date,
            i.status,
            i.total_amount,
            i.amount_paid,
            i.total_amount - i.amount_paid AS amount_due
        FROM invoices i
        WHERE i.customer_id = ?
          AND i.status <> 'cancelled'
        ORDER BY i.invoice_date DESC, i.id DESC
    """, (customer["id"],)).fetchall()

    return render_template(
        "portal/invoices.html",
        customer=customer,
        invoices=rows
    )


@portal_bp.route("/invoices/<int:invoice_id>")
@login_required
@role_required("customer")
def invoice_detail(invoice_id):
    customer = get_portal_customer()

    if not customer:
        return render_template("portal/not_linked.html"), 403

    db = get_db()

    invoice = db.execute("""
        SELECT *
        FROM invoices
        WHERE id = ?
          AND customer_id = ?
          AND status <> 'cancelled'
    """, (invoice_id, customer["id"])).fetchone()

    if not invoice:
        abort(404)

    lines = db.execute("""
        SELECT *
        FROM invoice_lines
        WHERE invoice_id = ?
        ORDER BY id
    """, (invoice_id,)).fetchall()

    payments = db.execute("""
        SELECT
            payment_number,
            method,
            amount,
            payment_date,
            note
        FROM payments
        WHERE invoice_id = ?
          AND customer_id = ?
        ORDER BY payment_date DESC, id DESC
    """, (invoice_id, customer["id"])).fetchall()

    return render_template(
        "portal/invoice_detail.html",
        customer=customer,
        invoice=invoice,
        lines=lines,
        payments=payments
    )

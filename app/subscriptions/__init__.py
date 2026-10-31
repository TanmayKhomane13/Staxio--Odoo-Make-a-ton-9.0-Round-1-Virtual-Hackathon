from datetime import date

from flask import Blueprint, flash, redirect, render_template, request, url_for

from app.db import get_db
from app.security import login_required, role_required
from app.services.subscriptions import (
    change_subscription_status,
    create_subscription,
    get_subscription,
    get_subscription_lines,
)

subscriptions_bp = Blueprint(
    "subscriptions",
    __name__,
    url_prefix="/subscriptions",
)


@subscriptions_bp.route("/")
@login_required
@role_required("admin", "staff", "finance_lead")
def index():
    db = get_db()

    subscriptions = db.execute(
        """
        SELECT
            s.id,
            s.subscription_number,
            s.status,
            s.start_date,
            s.expiry_date,
            s.next_billing_date,
            c.name AS customer_name,
            p.name AS plan_name,
            p.billing_frequency,
            p.billing_interval,
            COALESCE(
                (
                    SELECT SUM(sl.quantity * sl.unit_price)
                    FROM subscription_lines sl
                    WHERE sl.subscription_id = s.id
                      AND sl.is_active = 1
                ), 0
            ) AS recurring_amount
        FROM subscriptions s
        JOIN customers c ON c.id = s.customer_id
        JOIN plans p ON p.id = s.plan_id
        ORDER BY s.created_at DESC, s.id DESC
        """
    ).fetchall()

    return render_template(
        "subscriptions/index.html",
        subscriptions=subscriptions,
        today=date.today().isoformat(),
    )


@subscriptions_bp.route("/create", methods=["GET", "POST"])
@login_required
@role_required("admin", "staff", "finance_lead")
def create():
    db = get_db()

    customers = db.execute(
        "SELECT id, name, email FROM customers ORDER BY name"
    ).fetchall()

    plans = db.execute(
        """
        SELECT id, name, billing_frequency, billing_interval, minimum_quantity
        FROM plans
        WHERE is_active = 1
        ORDER BY name
        """
    ).fetchall()

    templates = db.execute(
        """
        SELECT id, name, plan_id, validity_days
        FROM quotation_templates
        WHERE is_active = 1
        ORDER BY name
        """
    ).fetchall()

    if request.method == "POST":
        try:
            customer_id = int(request.form.get("customer_id", ""))
            plan_id = int(request.form.get("plan_id", ""))
            template_value = request.form.get("template_id", "").strip()
            template_id = int(template_value) if template_value else None

            start_date = request.form.get("start_date", "").strip()
            status = request.form.get("status", "draft")

            subscription_id = create_subscription(
                customer_id=customer_id,
                plan_id=plan_id,
                start_date=start_date,
                created_by=getattr(
                    __import__("flask").g, "user_id", None
                ),
                template_id=template_id,
                status=status,
            )

            flash("Subscription created successfully.", "success")
            return redirect(
                url_for("subscriptions.detail", subscription_id=subscription_id)
            )

        except (ValueError, TypeError) as exc:
            flash(str(exc) or "Please check the submitted values.", "error")

    return render_template(
        "subscriptions/create.html",
        customers=customers,
        plans=plans,
        templates=templates,
        today=date.today().isoformat(),
    )


@subscriptions_bp.route("/<int:subscription_id>")
@login_required
@role_required("admin", "staff", "finance_lead")
def detail(subscription_id):
    subscription = get_subscription(subscription_id)

    if not subscription:
        flash("Subscription not found.", "error")
        return redirect(url_for("subscriptions.index"))

    lines = get_subscription_lines(subscription_id)

    events = get_db().execute(
        """
        SELECT from_status, to_status, created_at
        FROM subscription_events
        WHERE subscription_id = ?
        ORDER BY created_at DESC, id DESC
        """,
        (subscription_id,),
    ).fetchall()

    return render_template(
        "subscriptions/detail.html",
        subscription=subscription,
        lines=lines,
        events=events,
    )


@subscriptions_bp.route("/<int:subscription_id>/status", methods=["POST"])
@login_required
@role_required("admin", "staff", "finance_lead")
def update_status(subscription_id):
    new_status = request.form.get("status", "").strip()
    reason = request.form.get("cancellation_reason", "").strip()

    try:
        change_subscription_status(
            subscription_id,
            new_status,
            reason=reason or None,
        )
        flash("Subscription status updated.", "success")
    except ValueError as exc:
        flash(str(exc), "error")
    except Exception as exc:
        flash(f"Could not update subscription: {exc}", "error")

    return redirect(
        url_for("subscriptions.detail", subscription_id=subscription_id)
    )

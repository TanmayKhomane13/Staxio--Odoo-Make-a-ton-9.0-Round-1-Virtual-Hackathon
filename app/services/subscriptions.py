
from datetime import date, timedelta

from app.db import get_db


def get_subscription(subscription_id):
    db = get_db()
    return db.execute(
        """
        SELECT
            s.*,
            c.name AS customer_name,
            c.email AS customer_email,
            p.name AS plan_name,
            p.billing_frequency,
            p.billing_interval
        FROM subscriptions s
        JOIN customers c ON c.id = s.customer_id
        JOIN plans p ON p.id = s.plan_id
        WHERE s.id = ?
        """,
        (subscription_id,),
    ).fetchone()


def get_subscription_lines(subscription_id):
    return get_db().execute(
        """
        SELECT
            sl.*,
            p.name AS product_name,
            tr.name AS tax_name,
            tr.rate AS tax_rate
        FROM subscription_lines sl
        LEFT JOIN products p ON p.id = sl.product_id
        LEFT JOIN tax_rates tr ON tr.id = sl.tax_rate_id
        WHERE sl.subscription_id = ?
        ORDER BY sl.id
        """,
        (subscription_id,),
    ).fetchall()


def create_subscription(
    customer_id,
    plan_id,
    start_date,
    created_by=None,
    template_id=None,
    status="draft",
    payment_terms_days=None,
):
    db = get_db()

    if status not in ("draft", "quotation"):
        raise ValueError("New subscriptions must start as draft or quotation.")

    try:
        start = date.fromisoformat(start_date)
    except (TypeError, ValueError):
        raise ValueError("Enter a valid start date.")

    customer = db.execute(
        "SELECT * FROM customers WHERE id = ?",
        (customer_id,),
    ).fetchone()

    if not customer:
        raise ValueError("Customer not found.")

    plan = db.execute(
        "SELECT * FROM plans WHERE id = ? AND is_active = 1",
        (plan_id,),
    ).fetchone()

    if not plan:
        raise ValueError("Select an active plan.")

    if plan["available_from"] and start_date < plan["available_from"]:
        raise ValueError("The plan is not available on the selected start date.")

    if plan["available_until"] and start_date > plan["available_until"]:
        raise ValueError("The plan is no longer available on the selected start date.")

    if template_id:
        template = db.execute(
            """
            SELECT * FROM quotation_templates
            WHERE id = ? AND plan_id = ? AND is_active = 1
            """,
            (template_id, plan_id),
        ).fetchone()

        if not template:
            raise ValueError("The selected quotation template is invalid.")

        source_lines = db.execute(
            """
            SELECT
                qtl.product_id,
                qtl.variant_id,
                qtl.quantity,
                qtl.unit_price,
                p.name AS product_name,
                p.tax_rate_id
            FROM quotation_template_lines qtl
            JOIN products p ON p.id = qtl.product_id
            WHERE qtl.template_id = ?
            """,
            (template_id,),
        ).fetchall()
        quote_valid_until = (
            start + timedelta(days=template["validity_days"])
        ).isoformat() if status == "quotation" else None

    else:
        source_lines = db.execute(
            """
            SELECT
                pl.product_id,
                pl.variant_id,
                pl.quantity,
                pl.unit_price,
                p.name AS product_name,
                p.tax_rate_id
            FROM plan_lines pl
            JOIN products p ON p.id = pl.product_id
            WHERE pl.plan_id = ?
            """,
            (plan_id,),
        ).fetchall()
        quote_valid_until = None

    if not source_lines:
        raise ValueError("Add at least one product line to the plan or quotation template.")

    total_quantity = sum(line["quantity"] for line in source_lines)
    if total_quantity < plan["minimum_quantity"]:
        raise ValueError(
            f"This plan requires a minimum total quantity of {plan['minimum_quantity']}."
        )

    terms = (
        customer["payment_terms_days"]
        if payment_terms_days is None
        else int(payment_terms_days)
    )
    if terms < 0:
        raise ValueError("Payment terms cannot be negative.")

    cursor = db.execute(
        """
        INSERT INTO subscriptions (
            customer_id, plan_id, template_id, status,
            quote_valid_until, start_date, payment_terms_days, created_by
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            customer_id,
            plan_id,
            template_id,
            status,
            quote_valid_until,
            start_date,
            terms,
            created_by,
        ),
    )

    subscription_id = cursor.lastrowid
    subscription_number = f"SUB-{subscription_id:05d}"

    db.execute(
        "UPDATE subscriptions SET subscription_number = ? WHERE id = ?",
        (subscription_number, subscription_id),
    )

    for line in source_lines:
        db.execute(
            """
            INSERT INTO subscription_lines (
                subscription_id, product_id, variant_id, description,
                quantity, unit_price, tax_rate_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                subscription_id,
                line["product_id"],
                line["variant_id"],
                line["product_name"],
                line["quantity"],
                line["unit_price"],
                line["tax_rate_id"],
            ),
        )

    db.commit()
    return subscription_id


def change_subscription_status(subscription_id, new_status, reason=None):
    allowed = {
        "draft": {"quotation", "confirmed", "cancelled"},
        "quotation": {"draft", "confirmed", "cancelled"},
        "confirmed": {"active", "cancelled"},
        "active": {"paused", "cancelled", "expired", "closed"},
        "paused": {"active", "cancelled", "closed"},
        "expired": {"closed"},
        "cancelled": {"closed"},
        "closed": set(),
    }

    db = get_db()
    subscription = db.execute(
        "SELECT * FROM subscriptions WHERE id = ?",
        (subscription_id,),
    ).fetchone()

    if not subscription:
        raise ValueError("Subscription not found.")

    old_status = subscription["status"]

    if new_status not in allowed.get(old_status, set()):
        raise ValueError(
            f"Cannot change subscription from {old_status} to {new_status}."
        )

    updates = ["status = ?"]
    values = [new_status]

    if new_status == "active":
        updates.append("next_billing_date = ?")
        values.append(subscription["start_date"])

    if new_status == "cancelled" and reason:
        updates.append("cancellation_reason = ?")
        values.append(reason.strip())

    values.append(subscription_id)

    try:
        db.execute(
            f"UPDATE subscriptions SET {', '.join(updates)} WHERE id = ?",
            values,
        )
        db.commit()
    except Exception:
        db.rollback()
        raise

    return get_subscription(subscription_id)


from datetime import date

from app.db import get_db


VALID_STATUSES = {
    "draft",
    "quotation",
    "confirmed",
    "active",
    "paused",
    "cancelled",
    "expired",
    "closed",
}


def create_subscription(
    customer_id,
    plan_id,
    start_date,
    created_by=None,
    status="draft",
    template_id=None,
    expiry_date=None,
    payment_terms_days=None,
):
    """
    Create a subscription and copy its selected plan/template lines.

    start_date and expiry_date must use YYYY-MM-DD.
    """
    if status not in {"draft", "quotation"}:
        raise ValueError(
            "New subscriptions must start as draft or quotation."
        )

    db = get_db()

    plan = db.execute(
        """
        SELECT *
        FROM plans
        WHERE id = ? AND is_active = 1
        """,
        (plan_id,)
    ).fetchone()

    if not plan:
        raise ValueError("Selected plan does not exist or is inactive.")

    customer = db.execute(
        "SELECT * FROM customers WHERE id = ?",
        (customer_id,)
    ).fetchone()

    if not customer:
        raise ValueError("Customer does not exist.")

    try:
        parsed_start = date.fromisoformat(start_date)
    except (TypeError, ValueError):
        raise ValueError("Start date must use YYYY-MM-DD.")

    if expiry_date:
        try:
            parsed_expiry = date.fromisoformat(expiry_date)
        except ValueError:
            raise ValueError("Expiry date must use YYYY-MM-DD.")

        if parsed_expiry < parsed_start:
            raise ValueError("Expiry date cannot precede start date.")

    if plan["available_from"] and start_date < plan["available_from"]:
        raise ValueError("Plan is not available on the selected start date.")

    if plan["available_until"] and start_date > plan["available_until"]:
        raise ValueError("Plan is no longer available on the selected date.")

    if template_id is not None:
        template = db.execute(
            """
            SELECT *
            FROM quotation_templates
            WHERE id = ? AND plan_id = ? AND is_active = 1
            """,
            (template_id, plan_id)
        ).fetchone()

        if not template:
            raise ValueError("Invalid or inactive quotation template.")

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
            customer_id,
            plan_id,
            template_id,
            status,
            quote_valid_until,
            start_date,
            expiry_date,
            payment_terms_days,
            created_by
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            customer_id,
            plan_id,
            template_id,
            status,
            None,
            start_date,
            expiry_date,
            terms,
            created_by,
        )
    )

    subscription_id = cursor.lastrowid

    db.execute(
        """
        UPDATE subscriptions
        SET subscription_number = ?
        WHERE id = ?
        """,
        (f"SUB-{subscription_id:05d}", subscription_id)
    )

    if template_id is not None:
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
            (template_id,)
        ).fetchall()

        quote_valid_until = (
            date.fromisoformat(start_date).isoformat()
        )

        quote_valid_until = (
            date.fromordinal(
                parsed_start.toordinal() + template["validity_days"]
            ).isoformat()
        )

        db.execute(
            """
            UPDATE subscriptions
            SET quote_valid_until = ?
            WHERE id = ?
            """,
            (quote_valid_until, subscription_id)
        )

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
            (plan_id,)
        ).fetchall()

    if not source_lines:
        db.rollback()
        raise ValueError("The selected plan has no products.")

    total_quantity = sum(line["quantity"] for line in source_lines)

    if total_quantity < plan["minimum_quantity"]:
        db.rollback()
        raise ValueError(
            f"This plan requires at least "
            f"{plan['minimum_quantity']} units."
        )

    for line in source_lines:
        variant_name = None

        if line["variant_id"]:
            variant = db.execute(
                """
                SELECT attribute_name, attribute_value
                FROM product_variants
                WHERE id = ? AND product_id = ?
                """,
                (line["variant_id"], line["product_id"])
            ).fetchone()

            if variant:
                variant_name = (
                    f"{variant['attribute_name']}: "
                    f"{variant['attribute_value']}"
                )

        description = line["product_name"]

        if variant_name:
            description += f" ({variant_name})"

        db.execute(
            """
            INSERT INTO subscription_lines (
                subscription_id,
                product_id,
                variant_id,
                description,
                quantity,
                unit_price,
                tax_rate_id,
                is_active
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 1)
            """,
            (
                subscription_id,
                line["product_id"],
                line["variant_id"],
                description,
                line["quantity"],
                line["unit_price"],
                line["tax_rate_id"],
            )
        )

    db.commit()

    return subscription_id


def change_subscription_status(subscription_id, new_status):
    """Change a subscription status through the database lifecycle trigger."""
    if new_status not in VALID_STATUSES:
        raise ValueError("Invalid subscription status.")

    db = get_db()

    subscription = db.execute(
        """
        SELECT s.*, p.allow_pause, p.allow_early_cancellation
        FROM subscriptions s
        JOIN plans p ON p.id = s.plan_id
        WHERE s.id = ?
        """,
        (subscription_id,)
    ).fetchone()

    if not subscription:
        raise ValueError("Subscription not found.")

    old_status = subscription["status"]

    if old_status == new_status:
        return subscription_id

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

    if new_status not in allowed.get(old_status, set()):
        raise ValueError(
            f"Cannot change subscription from {old_status} to {new_status}."
        )

    if new_status == "paused" and not subscription["allow_pause"]:
        raise ValueError("This plan does not allow pausing.")

    if new_status == "active":
        if not subscription["start_date"]:
            raise ValueError("Subscription start date is missing.")

        db.execute(
            """
            UPDATE subscriptions
            SET status = ?,
                next_billing_date = start_date
            WHERE id = ?
            """,
            (new_status, subscription_id)
        )
    else:
        db.execute(
            """
            UPDATE subscriptions
            SET status = ?
            WHERE id = ?
            """,
            (new_status, subscription_id)
        )

    db.commit()

    return subscription_id


def get_subscription(subscription_id):
    """Return a subscription with customer and plan details."""
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
        (subscription_id,)
    ).fetchone()


def get_subscription_lines(subscription_id):
    """Return all lines belonging to a subscription."""
    db = get_db()

    return db.execute(
        """
        SELECT
            sl.*,
            tr.name AS tax_name,
            tr.rate AS tax_rate
        FROM subscription_lines sl
        LEFT JOIN tax_rates tr ON tr.id = sl.tax_rate_id
        WHERE sl.subscription_id = ?
        ORDER BY sl.id
        """,
        (subscription_id,)
    ).fetchall()

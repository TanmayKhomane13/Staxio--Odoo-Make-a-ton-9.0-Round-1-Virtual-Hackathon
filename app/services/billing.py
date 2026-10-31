import calendar
from datetime import date, timedelta
from decimal import Decimal

from app.db import get_db
from app.services.pricing import (
    allocate_discount,
    build_invoice_line,
    calculate_discount_amount,
    calculate_invoice_totals,
)


def add_months(source_date, months):
    """Add months without overflowing at month-end."""
    month_index = source_date.month - 1 + months
    year = source_date.year + month_index // 12
    month = month_index % 12 + 1

    day = min(
        source_date.day,
        calendar.monthrange(year, month)[1]
    )

    return date(year, month, day)


def next_billing_date(start_date, frequency, interval):
    """Calculate the next billing date from a period start."""
    interval = int(interval)

    if interval <= 0:
        raise ValueError("Billing interval must be positive.")

    if frequency == "daily":
        return start_date + timedelta(days=interval)

    if frequency == "weekly":
        return start_date + timedelta(weeks=interval)

    if frequency == "monthly":
        return add_months(start_date, interval)

    if frequency == "yearly":
        return add_months(start_date, interval * 12)

    raise ValueError("Unsupported billing frequency.")


def _get_eligible_discounts(db, subscription_id, invoice_date):
    """Fetch active discounts attached to a subscription."""
    return db.execute(
        """
        SELECT d.*
        FROM subscription_discounts sd
        JOIN discounts d ON d.id = sd.discount_id
        WHERE sd.subscription_id = ?
          AND d.is_active = 1
          AND (d.valid_from IS NULL OR d.valid_from <= ?)
          AND (d.valid_until IS NULL OR d.valid_until >= ?)
          AND (d.usage_limit IS NULL OR d.usage_count < d.usage_limit)
        ORDER BY d.id
        """,
        (subscription_id, invoice_date, invoice_date)
    ).fetchall()


def _apply_discounts(lines, discounts):
    """
    Apply discounts to invoice line data.

    Each line is expected to contain:
    product_id, quantity, unit_price, base_amount and discount_amount.
    """
    applied = []

    for discount in discounts:
        eligible_indexes = []

        for index, line in enumerate(lines):
            if discount["product_id"] is not None:
                if line["product_id"] != discount["product_id"]:
                    continue

            eligible_indexes.append(index)

        if not eligible_indexes:
            continue

        eligible_base = sum(
            lines[index]["base_amount"]
            - lines[index]["discount_amount"]
            for index in eligible_indexes
        )

        eligible_quantity = sum(
            lines[index]["quantity"]
            for index in eligible_indexes
        )

        if eligible_base < discount["minimum_purchase"]:
            continue

        if eligible_quantity < discount["minimum_quantity"]:
            continue

        discount_amount = calculate_discount_amount(
            eligible_base,
            discount["discount_type"],
            discount["discount_value"]
        )

        if discount_amount <= 0:
            continue

        remaining_bases = [
            lines[index]["base_amount"]
            - lines[index]["discount_amount"]
            for index in eligible_indexes
        ]

        allocations = allocate_discount(
            discount_amount,
            remaining_bases
        )

        actual_discount = 0

        for index, allocation in zip(eligible_indexes, allocations):
            lines[index]["discount_amount"] += allocation
            actual_discount += allocation

        if actual_discount:
            applied.append({
                "discount_id": discount["id"],
                "amount": actual_discount,
            })

    return applied


def create_invoice_for_subscription(
    subscription_id,
    period_start,
    invoice_date=None,
):
    """
    Generate and confirm one recurring invoice.

    Returns the invoice ID. Duplicate subscription periods are rejected
    by the schema's unique invoice-period index.
    """
    db = get_db()

    invoice_day = invoice_date or date.today().isoformat()

    subscription = db.execute(
        """
        SELECT
            s.*,
            c.name AS customer_name,
            c.address AS customer_address,
            c.tax_number AS customer_tax_number,
            c.payment_terms_days AS customer_payment_terms,
            p.billing_frequency,
            p.billing_interval
        FROM subscriptions s
        JOIN customers c ON c.id = s.customer_id
        JOIN plans p ON p.id = s.plan_id
        WHERE s.id = ?
        """,
        (subscription_id,)
    ).fetchone()

    if not subscription:
        raise ValueError("Subscription not found.")

    if subscription["status"] != "active":
        raise ValueError("Only active subscriptions can be billed.")

    if not subscription["next_billing_date"]:
        raise ValueError("Subscription has no next billing date.")

    period_start_date = date.fromisoformat(period_start)

    if period_start != subscription["next_billing_date"]:
        raise ValueError("Period start does not match next billing date.")

    period_end_date = next_billing_date(
        period_start_date,
        subscription["billing_frequency"],
        subscription["billing_interval"]
    ) - timedelta(days=1)

    # Do not bill beyond the subscription expiry date.
    if subscription["expiry_date"]:
        expiry = date.fromisoformat(subscription["expiry_date"])
        period_end_date = min(period_end_date, expiry)

    if period_end_date < period_start_date:
        raise ValueError("Invalid billing period.")

    period_end = period_end_date.isoformat()

    existing = db.execute(
        """
        SELECT id
        FROM invoices
        WHERE subscription_id = ?
          AND period_start = ?
          AND period_end = ?
          AND status <> 'cancelled'
        """,
        (subscription_id, period_start, period_end)
    ).fetchone()

    if existing:
        raise ValueError("An invoice already exists for this period.")

    source_lines = db.execute(
        """
        SELECT
            sl.product_id,
            sl.description,
            sl.quantity,
            sl.unit_price,
            tr.name AS tax_name,
            COALESCE(tr.rate, 0) AS tax_rate
        FROM subscription_lines sl
        LEFT JOIN tax_rates tr ON tr.id = sl.tax_rate_id
        WHERE sl.subscription_id = ?
          AND sl.is_active = 1
        ORDER BY sl.id
        """,
        (subscription_id,)
    ).fetchall()

    if not source_lines:
        raise ValueError("Subscription has no active billable lines.")

    lines = []

    for source in source_lines:
        base_amount = (
            int(source["quantity"]) * int(source["unit_price"])
        )

        lines.append({
            "product_id": source["product_id"],
            "description": source["description"],
            "quantity": int(source["quantity"]),
            "unit_price": int(source["unit_price"]),
            "tax_name": source["tax_name"],
            "tax_rate": float(source["tax_rate"] or 0),
            "base_amount": base_amount,
            "discount_amount": 0,
        })

    discounts = _get_eligible_discounts(
        db,
        subscription_id,
        invoice_day
    )

    applied_discounts = _apply_discounts(lines, discounts)

    calculated_lines = []

    for line in lines:
        calculation = build_invoice_line(
            quantity=line["quantity"],
            unit_price=line["unit_price"],
            discount_amount=line["discount_amount"],
            tax_rate=line["tax_rate"],
        )

        calculated_lines.append({
            **line,
            **calculation,
        })

    totals = calculate_invoice_totals(calculated_lines)

    terms = int(
        subscription["payment_terms_days"]
        if subscription["payment_terms_days"] is not None
        else subscription["customer_payment_terms"]
    )

    due_date = (
        date.fromisoformat(invoice_day)
        + timedelta(days=terms)
    ).isoformat()

    cursor = db.execute(
        """
        INSERT INTO invoices (
            customer_id,
            subscription_id,
            status,
            invoice_date,
            due_date,
            period_start,
            period_end,
            customer_name,
            customer_address,
            customer_tax_number,
            subtotal,
            discount_total,
            tax_total,
            total_amount
        )
        VALUES (?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            subscription["customer_id"],
            subscription_id,
            invoice_day,
            due_date,
            period_start,
            period_end,
            subscription["customer_name"],
            subscription["customer_address"],
            subscription["customer_tax_number"],
            totals["subtotal"],
            totals["discount_total"],
            totals["tax_total"],
            totals["total_amount"],
        )
    )

    invoice_id = cursor.lastrowid

    db.execute(
        """
        UPDATE invoices
        SET invoice_number = ?
        WHERE id = ?
        """,
        (f"INV-{invoice_id:05d}", invoice_id)
    )

    for line in calculated_lines:
        db.execute(
            """
            INSERT INTO invoice_lines (
                invoice_id,
                product_id,
                description,
                quantity,
                unit_price,
                discount_amount,
                tax_name,
                tax_rate,
                tax_amount,
                line_total
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                invoice_id,
                line["product_id"],
                line["description"],
                line["quantity"],
                line["unit_price"],
                line["discount_amount"],
                line["tax_name"],
                line["tax_rate"],
                line["tax_amount"],
                line["line_total"],
            )
        )

    # The trigger validates each discount and increments usage_count.
    for discount in applied_discounts:
        db.execute(
            """
            INSERT INTO invoice_discounts (
                invoice_id,
                discount_id,
                amount
            )
            VALUES (?, ?, ?)
            """,
            (
                invoice_id,
                discount["discount_id"],
                discount["amount"],
            )
        )

    # The trigger permits draft -> confirmed.
    db.execute(
        """
        UPDATE invoices
        SET status = 'confirmed',
            sent_at = strftime('%Y-%m-%d %H:%M:%S', 'now')
        WHERE id = ?
        """,
        (invoice_id,)
    )

    db.commit()

    return invoice_id


def run_billing(target_date=None):
    """
    Generate invoices for all active subscriptions due on target_date.

    Returns a summary with generated invoice IDs and per-subscription
    errors. A failed subscription does not stop the remaining batch.
    """
    db = get_db()
    target = date.fromisoformat(
        target_date or date.today().isoformat()
    )

    due_subscriptions = db.execute(
        """
        SELECT id, next_billing_date, expiry_date
        FROM subscriptions
        WHERE status = 'active'
          AND next_billing_date IS NOT NULL
          AND next_billing_date <= ?
        ORDER BY next_billing_date, id
        """,
        (target.isoformat(),)
    ).fetchall()

    generated = []
    errors = []

    for subscription in due_subscriptions:
        subscription_id = subscription["id"]
        period_start = subscription["next_billing_date"]

        try:
            start = date.fromisoformat(period_start)

            if subscription["expiry_date"]:
                expiry = date.fromisoformat(
                    subscription["expiry_date"]
                )

                if start > expiry:
                    db.execute(
                        """
                        UPDATE subscriptions
                        SET status = 'expired'
                        WHERE id = ? AND status = 'active'
                        """,
                        (subscription_id,)
                    )
                    db.commit()
                    continue

            invoice_id = create_invoice_for_subscription(
                subscription_id,
                period_start,
                invoice_date=target.isoformat(),
            )

            invoice = db.execute(
                """
                SELECT period_end
                FROM invoices
                WHERE id = ?
                """,
                (invoice_id,)
            ).fetchone()

            period_end = date.fromisoformat(invoice["period_end"])
            next_date = period_end + timedelta(days=1)

            if subscription["expiry_date"]:
                expiry = date.fromisoformat(
                    subscription["expiry_date"]
                )

                if next_date > expiry:
                    db.execute(
                        """
                        UPDATE subscriptions
                        SET status = 'expired',
                            next_billing_date = ?
                        WHERE id = ? AND status = 'active'
                        """,
                        (next_date.isoformat(), subscription_id)
                    )
                else:
                    db.execute(
                        """
                        UPDATE subscriptions
                        SET next_billing_date = ?
                        WHERE id = ? AND status = 'active'
                        """,
                        (next_date.isoformat(), subscription_id)
                    )
            else:
                db.execute(
                    """
                    UPDATE subscriptions
                    SET next_billing_date = ?
                    WHERE id = ? AND status = 'active'
                    """,
                    (next_date.isoformat(), subscription_id)
                )

            db.commit()
            generated.append(invoice_id)

        except Exception as exc:
            db.rollback()
            errors.append({
                "subscription_id": subscription_id,
                "error": str(exc),
            })

    return {
        "target_date": target.isoformat(),
        "generated_count": len(generated),
        "invoice_ids": generated,
        "errors": errors,
    }
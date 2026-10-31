
from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP

from flask import Blueprint, flash, redirect, render_template, request, url_for

from app.db import get_db
from app.security import current_user, login_required, role_required

invoices_bp = Blueprint("invoices", __name__, url_prefix="/invoices")


def _round_paise(value):
    return int(
        Decimal(str(value)).quantize(
            Decimal("1"),
            rounding=ROUND_HALF_UP,
        )
    )


def _create_invoice(subscription_id, invoice_date):
    db = get_db()

    subscription = db.execute(
        """
        SELECT
            s.*,
            c.name AS customer_name,
            c.address AS customer_address,
            c.tax_number AS customer_tax_number,
            c.payment_terms_days AS customer_terms,
            p.name AS plan_name
        FROM subscriptions s
        JOIN customers c ON c.id = s.customer_id
        JOIN plans p ON p.id = s.plan_id
        WHERE s.id = ?
        """,
        (subscription_id,),
    ).fetchone()

    if not subscription:
        raise ValueError("Subscription not found.")

    if subscription["status"] != "active":
        raise ValueError("Only active subscriptions can be invoiced.")

    if (
        subscription["next_billing_date"]
        and subscription["next_billing_date"] > invoice_date
    ):
        raise ValueError("This subscription is not due for billing yet.")

    if (
        subscription["expiry_date"]
        and subscription["expiry_date"] < invoice_date
    ):
        raise ValueError("This subscription has expired.")

    lines = db.execute(
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
        (subscription_id,),
    ).fetchall()

    if not lines:
        raise ValueError("This subscription has no active billing lines.")

    period_start = subscription["next_billing_date"] or invoice_date
    period_end = invoice_date

    due_date = (
        date.fromisoformat(invoice_date)
        + timedelta(days=subscription["payment_terms_days"])
    ).isoformat()

    subtotal = 0
    tax_total = 0
    prepared_lines = []

    for line in lines:
        base = line["quantity"] * line["unit_price"]
        tax_rate = Decimal(str(line["tax_rate"] or 0))
        tax_amount = _round_paise(
            Decimal(base) * tax_rate / Decimal("100")
        )
        line_total = base + tax_amount

        subtotal += base
        tax_total += tax_amount

        prepared_lines.append({
            "product_id": line["product_id"],
            "description": line["description"],
            "quantity": line["quantity"],
            "unit_price": line["unit_price"],
            "tax_name": line["tax_name"],
            "tax_rate": float(tax_rate),
            "tax_amount": tax_amount,
            "line_total": line_total,
        })

    total = subtotal + tax_total

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
        VALUES (?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        """,
        (
            subscription["customer_id"],
            subscription_id,
            invoice_date,
            due_date,
            period_start,
            period_end,
            subscription["customer_name"],
            subscription["customer_address"],
            subscription["customer_tax_number"],
            subtotal,
            tax_total,
            total,
        ),
    )

    invoice_id = cursor.lastrowid
    invoice_number = f"INV-{invoice_id:05d}"

    db.execute(
        "UPDATE invoices SET invoice_number = ? WHERE id = ?",
        (invoice_number, invoice_id),
    )

    for line in prepared_lines:
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
            VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
            """,
            (
                invoice_id,
                line["product_id"],
                line["description"],
                line["quantity"],
                line["unit_price"],
                line["tax_name"],
                line["tax_rate"],
                line["tax_amount"],
                line["line_total"],
            ),
        )

    return invoice_id


@invoices_bp.route("/")
@login_required
@role_required("admin", "staff")
def index():
    invoices = get_db().execute(
        """
        SELECT
            i.*,
            c.name AS linked_customer_name,
            COALESCE(i.total_amount - i.amount_paid, 0) AS balance_due
        FROM invoices i
        JOIN customers c ON c.id = i.customer_id
        ORDER BY i.created_at DESC, i.id DESC
        """
    ).fetchall()

    return render_template("invoices/index.html", invoices=invoices)


@invoices_bp.route("/create", methods=["GET", "POST"])
@login_required
@role_required("admin", "staff")
def create():
    db = get_db()

    subscriptions = db.execute(
        """
        SELECT
            s.id,
            s.subscription_number,
            s.next_billing_date,
            c.name AS customer_name,
            p.name AS plan_name
        FROM subscriptions s
        JOIN customers c ON c.id = s.customer_id
        JOIN plans p ON p.id = s.plan_id
        WHERE s.status = 'active'
        ORDER BY c.name
        """
    ).fetchall()

    if request.method == "POST":
        try:
            subscription_id = int(request.form.get("subscription_id", ""))
            invoice_date = request.form.get("invoice_date", "").strip()

            date.fromisoformat(invoice_date)

            db.execute("BEGIN")
            invoice_id = _create_invoice(subscription_id, invoice_date)
            db.commit()

            flash("Draft invoice created successfully.", "success")
            return redirect(
                url_for("invoices.detail", invoice_id=invoice_id)
            )

        except (ValueError, TypeError) as exc:
            db.rollback()
            flash(str(exc) or "Please check the submitted values.", "error")
        except Exception:
            db.rollback()
            flash("Could not create the invoice. Check the subscription and try again.", "error")

    return render_template(
        "invoices/create.html",
        subscriptions=subscriptions,
        today=date.today().isoformat(),
    )


@invoices_bp.route("/<int:invoice_id>")
@login_required
@role_required("admin", "staff")
def detail(invoice_id):
    db = get_db()

    invoice = db.execute(
        """
        SELECT i.*, c.name AS linked_customer_name
        FROM invoices i
        JOIN customers c ON c.id = i.customer_id
        WHERE i.id = ?
        """,
        (invoice_id,),
    ).fetchone()

    if not invoice:
        flash("Invoice not found.", "error")
        return redirect(url_for("invoices.index"))

    lines = db.execute(
        """
        SELECT * FROM invoice_lines
        WHERE invoice_id = ?
        ORDER BY id
        """,
        (invoice_id,),
    ).fetchall()

    payments = db.execute(
        """
        SELECT * FROM payments
        WHERE invoice_id = ?
        ORDER BY payment_date DESC, id DESC
        """,
        (invoice_id,),
    ).fetchall()

    return render_template(
        "invoices/detail.html",
        invoice=invoice,
        lines=lines,
        payments=payments,
    )


@invoices_bp.route("/<int:invoice_id>/confirm", methods=["POST"])
@login_required
@role_required("admin", "staff")
def confirm(invoice_id):
    db = get_db()

    invoice = db.execute(
        "SELECT status FROM invoices WHERE id = ?",
        (invoice_id,),
    ).fetchone()

    if not invoice:
        flash("Invoice not found.", "error")
    elif invoice["status"] != "draft":
        flash("Only draft invoices can be confirmed.", "error")
    else:
        try:
            db.execute(
                """
                UPDATE invoices
                SET status = 'confirmed',
                    sent_at = strftime('%Y-%m-%d %H:%M:%S', 'now')
                WHERE id = ?
                """,
                (invoice_id,),
            )
            db.commit()
            flash("Invoice confirmed successfully.", "success")
        except Exception:
            db.rollback()
            flash("Could not confirm invoice.", "error")

    return redirect(url_for("invoices.detail", invoice_id=invoice_id))


@invoices_bp.route("/<int:invoice_id>/cancel", methods=["POST"])
@login_required
@role_required("admin")
def cancel(invoice_id):
    db = get_db()

    invoice = db.execute(
        "SELECT status FROM invoices WHERE id = ?",
        (invoice_id,),
    ).fetchone()

    if not invoice:
        flash("Invoice not found.", "error")
    elif invoice["status"] not in ("draft", "confirmed"):
        flash("This invoice cannot be cancelled.", "error")
    else:
        try:
            db.execute(
                """
                UPDATE invoices
                SET status = 'cancelled',
                    cancelled_at = strftime('%Y-%m-%d %H:%M:%S', 'now')
                WHERE id = ?
                """,
                (invoice_id,),
            )
            db.commit()
            flash("Invoice cancelled.", "success")
        except Exception:
            db.rollback()
            flash("Could not cancel invoice.", "error")

    return redirect(url_for("invoices.detail", invoice_id=invoice_id))

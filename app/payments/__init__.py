
from datetime import date
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

from flask import Blueprint, flash, redirect, render_template, request, url_for

from app.db import get_db
from app.security import current_user, login_required, role_required

payments_bp = Blueprint("payments", __name__, url_prefix="/payments")

PAYMENT_METHODS = {
    "cash",
    "bank_transfer",
    "card",
    "upi",
    "cheque",
    "other",
}


def rupees_to_paise(value):
    try:
        amount = Decimal(str(value).strip())
    except (InvalidOperation, AttributeError):
        raise ValueError("Enter a valid payment amount.")

    if not amount.is_finite() or amount <= 0:
        raise ValueError("Payment amount must be greater than zero.")

    return int(
        (amount * 100).quantize(
            Decimal("1"),
            rounding=ROUND_HALF_UP,
        )
    )


def record_payment(invoice_id, method, amount_paise, payment_date, note=None):
    db = get_db()

    invoice = db.execute(
        """
        SELECT id, customer_id, status, total_amount, amount_paid
        FROM invoices
        WHERE id = ?
        """,
        (invoice_id,),
    ).fetchone()

    if not invoice:
        raise ValueError("Invoice not found.")

    if invoice["status"] != "confirmed":
        raise ValueError("Only confirmed invoices can receive payments.")

    if method not in PAYMENT_METHODS:
        raise ValueError("Select a valid payment method.")

    if amount_paise <= 0:
        raise ValueError("Payment amount must be greater than zero.")

    balance = invoice["total_amount"] - invoice["amount_paid"]

    if amount_paise > balance:
        raise ValueError("Payment cannot exceed the outstanding balance.")

    try:
        date.fromisoformat(payment_date)
    except (TypeError, ValueError):
        raise ValueError("Enter a valid payment date.")

    user = current_user()
    recorded_by = user["id"] if user else None

    try:
        cursor = db.execute(
            """
            INSERT INTO payments (
                invoice_id,
                customer_id,
                method,
                amount,
                payment_date,
                note,
                recorded_by
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                invoice_id,
                invoice["customer_id"],
                method,
                amount_paise,
                payment_date,
                (note or "").strip() or None,
                recorded_by,
            ),
        )

        payment_id = cursor.lastrowid
        payment_number = f"PAY-{payment_id:05d}"

        db.execute(
            "UPDATE payments SET payment_number = ? WHERE id = ?",
            (payment_number, payment_id),
        )

        db.commit()
        return payment_id

    except Exception:
        db.rollback()
        raise


@payments_bp.route("/")
@login_required
@role_required("admin", "staff", "finance_lead")
def index():
    payments = get_db().execute(
        """
        SELECT
            p.*,
            i.invoice_number,
            c.name AS customer_name
        FROM payments p
        JOIN invoices i ON i.id = p.invoice_id
        JOIN customers c ON c.id = p.customer_id
        ORDER BY p.payment_date DESC, p.id DESC
        """
    ).fetchall()

    return render_template("payments/index.html", payments=payments)


@payments_bp.route("/create/<int:invoice_id>", methods=["GET", "POST"])
@login_required
@role_required("admin", "staff", "finance_lead")
def create(invoice_id):
    db = get_db()

    invoice = db.execute(
        """
        SELECT
            i.*,
            c.name AS linked_customer_name,
            i.total_amount - i.amount_paid AS balance_due
        FROM invoices i
        JOIN customers c ON c.id = i.customer_id
        WHERE i.id = ?
        """,
        (invoice_id,),
    ).fetchone()

    if not invoice:
        flash("Invoice not found.", "error")
        return redirect(url_for("invoices.index"))

    if invoice["status"] != "confirmed":
        flash("Only confirmed invoices can receive payments.", "error")
        return redirect(
            url_for("invoices.detail", invoice_id=invoice_id)
        )

    if request.method == "POST":
        try:
            method = request.form.get("method", "").strip()
            amount_paise = rupees_to_paise(
                request.form.get("amount", "")
            )
            payment_date = request.form.get("payment_date", "").strip()
            note = request.form.get("note", "")

            payment_id = record_payment(
                invoice_id=invoice_id,
                method=method,
                amount_paise=amount_paise,
                payment_date=payment_date,
                note=note,
            )

            flash(
                f"Payment PAY-{payment_id:05d} recorded successfully.",
                "success",
            )
            return redirect(
                url_for("invoices.detail", invoice_id=invoice_id)
            )

        except ValueError as exc:
            flash(str(exc), "error")
        except Exception:
            db.rollback()
            flash(
                "Payment could not be recorded. Check the invoice balance and try again.",
                "error",
            )

    return render_template(
        "payments/create.html",
        invoice=invoice,
        methods=sorted(PAYMENT_METHODS),
        today=date.today().isoformat(),
    )
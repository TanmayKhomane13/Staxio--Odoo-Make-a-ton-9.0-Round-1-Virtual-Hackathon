
from flask import (
    Blueprint,
    render_template,
    request,
    redirect,
    url_for,
    flash,
)

from app.db import get_db
from app.security import login_required, role_required


customers_bp = Blueprint(
    "customers",
    __name__,
    url_prefix="/customers"
)


@customers_bp.route("/")
@login_required
@role_required("admin", "staff")
def index():
    db = get_db()

    customers = db.execute(
        """
        SELECT
            c.*,
            COUNT(DISTINCT s.id) AS subscription_count,
            COUNT(DISTINCT i.id) AS invoice_count
        FROM customers c
        LEFT JOIN subscriptions s ON s.customer_id = c.id
        LEFT JOIN invoices i ON i.customer_id = c.id
        GROUP BY c.id
        ORDER BY c.created_at DESC, c.id DESC
        """
    ).fetchall()

    return render_template(
        "customers/index.html",
        customers=customers,
    )


@customers_bp.route("/create", methods=["POST"])
@login_required
@role_required("admin", "staff")
def create_customer():
    db = get_db()

    name = request.form.get("name", "").strip()
    company_name = request.form.get("company_name", "").strip() or None
    email = request.form.get("email", "").strip().lower()
    phone = request.form.get("phone", "").strip() or None
    tax_number = request.form.get("tax_number", "").strip() or None
    address = request.form.get("address", "").strip() or None

    if not name or not email or "@" not in email:
        flash("Enter a customer name and valid email address.", "danger")
        return redirect(url_for("customers.index"))

    try:
        payment_terms_days = int(
            request.form.get("payment_terms_days", "30")
        )

        if payment_terms_days < 0:
            raise ValueError

        db.execute(
            """
            INSERT INTO customers (
                name,
                company_name,
                email,
                phone,
                tax_number,
                address,
                payment_terms_days
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                name,
                company_name,
                email,
                phone,
                tax_number,
                address,
                payment_terms_days,
            )
        )

        db.commit()
        flash("Customer created successfully.", "success")

    except ValueError:
        db.rollback()
        flash("Payment terms must be zero or greater.", "danger")

    except Exception:
        db.rollback()
        flash("Could not create customer. Check the customer details.", "danger")

    return redirect(url_for("customers.index"))


@customers_bp.route("/<int:customer_id>/update", methods=["POST"])
@login_required
@role_required("admin", "staff")
def update_customer(customer_id):
    db = get_db()

    customer = db.execute(
        "SELECT id FROM customers WHERE id = ?",
        (customer_id,)
    ).fetchone()

    if not customer:
        flash("Customer not found.", "danger")
        return redirect(url_for("customers.index"))

    name = request.form.get("name", "").strip()
    company_name = request.form.get("company_name", "").strip() or None
    email = request.form.get("email", "").strip().lower()
    phone = request.form.get("phone", "").strip() or None
    tax_number = request.form.get("tax_number", "").strip() or None
    address = request.form.get("address", "").strip() or None

    try:
        payment_terms_days = int(
            request.form.get("payment_terms_days", "30")
        )

        if not name or not email or "@" not in email:
            raise ValueError

        if payment_terms_days < 0:
            raise ValueError

        db.execute(
            """
            UPDATE customers
            SET name = ?,
                company_name = ?,
                email = ?,
                phone = ?,
                tax_number = ?,
                address = ?,
                payment_terms_days = ?
            WHERE id = ?
            """,
            (
                name,
                company_name,
                email,
                phone,
                tax_number,
                address,
                payment_terms_days,
                customer_id,
            )
        )

        db.commit()
        flash("Customer updated successfully.", "success")

    except ValueError:
        db.rollback()
        flash("Enter valid customer details and payment terms.", "danger")

    except Exception:
        db.rollback()
        flash("Could not update customer. Check the email address.", "danger")

    return redirect(url_for("customers.index"))


@customers_bp.route("/<int:customer_id>")
@login_required
@role_required("admin", "staff")
def detail(customer_id):
    db = get_db()

    customer = db.execute(
        "SELECT * FROM customers WHERE id = ?",
        (customer_id,)
    ).fetchone()

    if not customer:
        flash("Customer not found.", "danger")
        return redirect(url_for("customers.index"))

    subscriptions = db.execute(
        """
        SELECT
            s.*,
            p.name AS plan_name,
            p.billing_frequency,
            p.billing_interval
        FROM subscriptions s
        JOIN plans p ON p.id = s.plan_id
        WHERE s.customer_id = ?
        ORDER BY s.id DESC
        """,
        (customer_id,)
    ).fetchall()

    invoices = db.execute(
        """
        SELECT *
        FROM invoices
        WHERE customer_id = ?
        ORDER BY invoice_date DESC, id DESC
        """,
        (customer_id,)
    ).fetchall()

    return render_template(
        "customers/detail.html",
        customer=customer,
        subscriptions=subscriptions,
        invoices=invoices,
    )


from datetime import date
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

from flask import Blueprint, flash, redirect, render_template, request, url_for

from app.db import get_db
from app.security import current_user, login_required, role_required


discounts_bp = Blueprint(
    "discounts",
    __name__,
    url_prefix="/discounts"
)


VALID_TYPES = {"fixed", "percentage"}


def rupees_to_paise(value):
    """Convert an INR form value to integer paise."""
    try:
        amount = Decimal(str(value).strip())
    except (InvalidOperation, ValueError, TypeError):
        raise ValueError("Enter a valid monetary amount.")

    if not amount.is_finite() or amount < 0:
        raise ValueError("Amount cannot be negative.")

    return int(
        (amount * 100).quantize(
            Decimal("1"),
            rounding=ROUND_HALF_UP
        )
    )


def parse_optional_int(value, field_name, minimum=0):
    value = (value or "").strip()

    if not value:
        return None

    try:
        number = int(value)
    except ValueError:
        raise ValueError(f"{field_name} must be a whole number.")

    if number < minimum:
        raise ValueError(f"{field_name} must be at least {minimum}.")

    return number


def parse_discount_form(form):
    name = (form.get("name") or "").strip()
    code = (form.get("code") or "").strip().upper()
    discount_type = (form.get("discount_type") or "").strip()
    discount_value_raw = (form.get("discount_value") or "").strip()

    if not name:
        raise ValueError("Discount name is required.")

    if not code:
        raise ValueError("Discount code is required.")

    if discount_type not in VALID_TYPES:
        raise ValueError("Select a valid discount type.")

    try:
        value = Decimal(discount_value_raw)
    except (InvalidOperation, ValueError):
        raise ValueError("Enter a valid discount value.")

    if not value.is_finite() or value <= 0:
        raise ValueError("Discount value must be greater than zero.")

    if discount_type == "percentage":
        if value > 100:
            raise ValueError("Percentage discount cannot exceed 100.")
        stored_value = float(value)
    else:
        stored_value = rupees_to_paise(discount_value_raw)

        if stored_value <= 0:
            raise ValueError("Fixed discount must be greater than zero.")

    minimum_purchase = rupees_to_paise(
        form.get("minimum_purchase") or "0"
    )

    minimum_quantity = parse_optional_int(
        form.get("minimum_quantity"),
        "Minimum quantity",
        minimum=1
    )

    usage_limit = parse_optional_int(
        form.get("usage_limit"),
        "Usage limit",
        minimum=1
    )

    product_id = parse_optional_int(
        form.get("product_id"),
        "Product ID",
        minimum=1
    )

    valid_from = (form.get("valid_from") or "").strip() or None
    valid_until = (form.get("valid_until") or "").strip() or None

    for field_name, value_date in (
        ("Start date", valid_from),
        ("End date", valid_until)
    ):
        if value_date:
            try:
                date.fromisoformat(value_date)
            except ValueError:
                raise ValueError(f"{field_name} must be a valid date.")

    if valid_from and valid_until and valid_until < valid_from:
        raise ValueError("End date cannot be before start date.")

    return {
        "name": name,
        "code": code,
        "discount_type": discount_type,
        "discount_value": stored_value,
        "minimum_purchase": minimum_purchase,
        "minimum_quantity": minimum_quantity,
        "product_id": product_id,
        "valid_from": valid_from,
        "valid_until": valid_until,
        "usage_limit": usage_limit,
    }


@discounts_bp.route("/")
@login_required
@role_required("admin", "staff","finance_lead")
def index():
    db = get_db()

    discounts = db.execute("""
        SELECT
            d.*,
            p.name AS product_name
        FROM discounts d
        LEFT JOIN products p ON p.id = d.product_id
        ORDER BY d.created_by DESC, d.id DESC
    """).fetchall()

    products = db.execute("""
        SELECT id, name
        FROM products
        WHERE is_active = 1
        ORDER BY name
    """).fetchall()

    subscriptions = db.execute("""
        SELECT
            s.id,
            s.subscription_number,
            c.name AS customer_name
        FROM subscriptions s
        JOIN customers c ON c.id = s.customer_id
        WHERE s.status IN ('confirmed', 'active', 'paused')
        ORDER BY s.id DESC
    """).fetchall()

    return render_template(
        "discounts/index.html",
        discounts=discounts,
        products=products,
        subscriptions=subscriptions
    )


@discounts_bp.route("/create", methods=["GET", "POST"])
@login_required
@role_required("admin")
def create():
    db = get_db()

    products = db.execute("""
        SELECT id, name
        FROM products
        WHERE is_active = 1
        ORDER BY name
    """).fetchall()

    if request.method == "POST":
        try:
            data = parse_discount_form(request.form)

            existing = db.execute(
                "SELECT id FROM discounts WHERE code = ?",
                (data["code"],)
            ).fetchone()

            if existing:
                raise ValueError("A discount with this code already exists.")

            user = current_user()

            db.execute("""
                INSERT INTO discounts (
                    name,
                    code,
                    discount_type,
                    discount_value,
                    minimum_purchase,
                    minimum_quantity,
                    product_id,
                    valid_from,
                    valid_until,
                    usage_limit,
                    usage_count,
                    is_active,
                    created_by
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?)
            """, (
                data["name"],
                data["code"],
                data["discount_type"],
                data["discount_value"],
                data["minimum_purchase"],
                data["minimum_quantity"],
                data["product_id"],
                data["valid_from"],
                data["valid_until"],
                data["usage_limit"],
                user["id"] if user else None
            ))

            db.commit()
            flash("Discount created successfully.", "success")
            return redirect(url_for("discounts.index"))

        except ValueError as exc:
            db.rollback()
            flash(str(exc), "error")
        except Exception:
            db.rollback()
            flash("Could not create the discount.", "error")

    return render_template(
        "discounts/create.html",
        products=products
    )


@discounts_bp.route("/<int:discount_id>/edit", methods=["GET", "POST"])
@login_required
@role_required("admin")
def edit(discount_id):
    db = get_db()

    discount = db.execute(
        "SELECT * FROM discounts WHERE id = ?",
        (discount_id,)
    ).fetchone()

    if not discount:
        flash("Discount not found.", "error")
        return redirect(url_for("discounts.index"))

    products = db.execute("""
        SELECT id, name
        FROM products
        WHERE is_active = 1
        ORDER BY name
    """).fetchall()

    if request.method == "POST":
        try:
            data = parse_discount_form(request.form)

            duplicate = db.execute("""
                SELECT id
                FROM discounts
                WHERE code = ? AND id != ?
            """, (data["code"], discount_id)).fetchone()

            if duplicate:
                raise ValueError("Another discount already uses this code.")

            db.execute("""
                UPDATE discounts
                SET
                    name = ?,
                    code = ?,
                    discount_type = ?,
                    discount_value = ?,
                    minimum_purchase = ?,
                    minimum_quantity = ?,
                    product_id = ?,
                    valid_from = ?,
                    valid_until = ?,
                    usage_limit = ?
                WHERE id = ?
            """, (
                data["name"],
                data["code"],
                data["discount_type"],
                data["discount_value"],
                data["minimum_purchase"],
                data["minimum_quantity"],
                data["product_id"],
                data["valid_from"],
                data["valid_until"],
                data["usage_limit"],
                discount_id
            ))

            db.commit()
            flash("Discount updated successfully.", "success")
            return redirect(url_for("discounts.index"))

        except ValueError as exc:
            db.rollback()
            flash(str(exc), "error")
        except Exception:
            db.rollback()
            flash("Could not update the discount.", "error")

    return render_template(
        "discounts/edit.html",
        discount=discount,
        products=products
    )


@discounts_bp.post("/<int:discount_id>/toggle")
@login_required
@role_required("admin")
def toggle(discount_id):
    db = get_db()

    discount = db.execute(
        "SELECT id, is_active FROM discounts WHERE id = ?",
        (discount_id,)
    ).fetchone()

    if not discount:
        flash("Discount not found.", "error")
        return redirect(url_for("discounts.index"))

    db.execute("""
        UPDATE discounts
        SET is_active = ?
        WHERE id = ?
    """, (0 if discount["is_active"] else 1, discount_id))

    db.commit()

    flash(
        "Discount activated." if not discount["is_active"]
        else "Discount deactivated.",
        "success"
    )

    return redirect(url_for("discounts.index"))


@discounts_bp.post("/attach")
@login_required
@role_required("admin")
def attach():
    db = get_db()

    try:
        subscription_id = int(request.form.get("subscription_id", ""))
        discount_id = int(request.form.get("discount_id", ""))

        subscription = db.execute("""
            SELECT id, status
            FROM subscriptions
            WHERE id = ?
        """, (subscription_id,)).fetchone()

        discount = db.execute("""
            SELECT id, is_active
            FROM discounts
            WHERE id = ?
        """, (discount_id,)).fetchone()

        if not subscription:
            raise ValueError("Subscription not found.")

        if subscription["status"] not in ("confirmed", "active", "paused"):
            raise ValueError("Discounts can only be attached to confirmed, active or paused subscriptions.")

        if not discount or not discount["is_active"]:
            raise ValueError("Select an active discount.")

        existing = db.execute("""
            SELECT id
            FROM subscription_discounts
            WHERE subscription_id = ? AND discount_id = ?
        """, (subscription_id, discount_id)).fetchone()

        if existing:
            raise ValueError("This discount is already attached to the subscription.")

        db.execute("""
            INSERT INTO subscription_discounts (
                subscription_id,
                discount_id
            )
            VALUES (?, ?)
        """, (subscription_id, discount_id))

        db.commit()
        flash("Discount attached to subscription.", "success")

    except (ValueError, TypeError) as exc:
        db.rollback()
        flash(str(exc) or "Invalid selection.", "error")
    except Exception:
        db.rollback()
        flash("Could not attach the discount.", "error")

    return redirect(url_for("discounts.index"))


@discounts_bp.post("/detach")
@login_required
@role_required("admin")
def detach():
    db = get_db()

    try:
        subscription_id = int(request.form.get("subscription_id", ""))
        discount_id = int(request.form.get("discount_id", ""))

        db.execute("""
            DELETE FROM subscription_discounts
            WHERE subscription_id = ? AND discount_id = ?
        """, (subscription_id, discount_id))

        db.commit()
        flash("Discount removed from subscription.", "success")

    except (ValueError, TypeError):
        db.rollback()
        flash("Invalid subscription or discount.", "error")
    except Exception:
        db.rollback()
        flash("Could not remove the discount.", "error")

    return redirect(url_for("discounts.index"))


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
from decimal import Decimal, ROUND_HALF_UP


catalog_bp = Blueprint("catalog", __name__, url_prefix="/catalog")

def rupees_to_paise(value):
    return int(
        (Decimal(str(value)) * 100).quantize(
            Decimal("1"),
            rounding=ROUND_HALF_UP
        )
    )

@catalog_bp.route("/")
@login_required
@role_required("admin", "staff")
def index():
    db = get_db()

    products = db.execute(
        """
        SELECT
            p.*,
            tr.name AS tax_name,
            tr.rate AS tax_rate,
            (
                SELECT COUNT(*)
                FROM product_variants pv
                WHERE pv.product_id = p.id
            ) AS variant_count
        FROM products p
        LEFT JOIN tax_rates tr ON tr.id = p.tax_rate_id
        ORDER BY p.created_at DESC, p.id DESC
        """
    ).fetchall()

    tax_rates = db.execute(
        """
        SELECT *
        FROM tax_rates
        WHERE is_active = 1
        ORDER BY rate DESC
        """
    ).fetchall()

    return render_template(
        "catalog/index.html",
        products=products,
        tax_rates=tax_rates,
    )


@catalog_bp.route("/products/create", methods=["POST"])
@login_required
@role_required("admin", "staff")
def create_product():
    db = get_db()

    name = request.form.get("name", "").strip()
    product_type = request.form.get("product_type", "").strip()
    notes = request.form.get("notes", "").strip() or None

    valid_types = {"software", "service", "add-on", "other"}

    if not name:
        flash("Product name is required.", "danger")
        return redirect(url_for("catalog.index"))

    if product_type not in valid_types:
        flash("Select a valid product type.", "danger")
        return redirect(url_for("catalog.index"))

    try:
        sales_price = int(request.form.get("sales_price", "0"))
        cost_price = int(request.form.get("cost_price", "0"))
        tax_rate_id = request.form.get("tax_rate_id") or None

        if sales_price < 0 or cost_price < 0:
            raise ValueError

        if tax_rate_id:
            tax_rate_id = int(tax_rate_id)
            exists = db.execute(
                "SELECT id FROM tax_rates WHERE id = ? AND is_active = 1",
                (tax_rate_id,)
            ).fetchone()

            if not exists:
                raise ValueError

        db.execute(
            """
            INSERT INTO products (
                name,
                product_type,
                sales_price,
                cost_price,
                tax_rate_id,
                notes
            )
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                name,
                product_type,
                sales_price,
                cost_price,
                tax_rate_id,
                notes,
            )
        )

        db.commit()
        flash("Product created successfully.", "success")

    except (ValueError, TypeError):
        db.rollback()
        flash("Enter valid product prices and tax rate.", "danger")

    return redirect(url_for("catalog.index"))


@catalog_bp.route("/products/<int:product_id>/update", methods=["POST"])
@login_required
@role_required("admin", "staff")
def update_product(product_id):
    db = get_db()

    product = db.execute(
        "SELECT id FROM products WHERE id = ?",
        (product_id,)
    ).fetchone()

    if not product:
        flash("Product not found.", "danger")
        return redirect(url_for("catalog.index"))

    name = request.form.get("name", "").strip()
    product_type = request.form.get("product_type", "").strip()
    notes = request.form.get("notes", "").strip() or None

    if not name or product_type not in {
        "software", "service", "add-on", "other"
    }:
        flash("Enter valid product details.", "danger")
        return redirect(url_for("catalog.index"))

    try:
        sales_price = int(request.form.get("sales_price", "0"))
        cost_price = int(request.form.get("cost_price", "0"))
        tax_rate_id = request.form.get("tax_rate_id") or None

        if sales_price < 0 or cost_price < 0:
            raise ValueError

        if tax_rate_id:
            tax_rate_id = int(tax_rate_id)

            if not db.execute(
                "SELECT id FROM tax_rates WHERE id = ?",
                (tax_rate_id,)
            ).fetchone():
                raise ValueError

        db.execute(
            """
            UPDATE products
            SET name = ?,
                product_type = ?,
                sales_price = ?,
                cost_price = ?,
                tax_rate_id = ?,
                notes = ?
            WHERE id = ?
            """,
            (
                name,
                product_type,
                sales_price,
                cost_price,
                tax_rate_id,
                notes,
                product_id,
            )
        )

        db.commit()
        flash("Product updated.", "success")

    except (ValueError, TypeError):
        db.rollback()
        flash("Invalid price or tax rate.", "danger")

    return redirect(url_for("catalog.index"))


@catalog_bp.route("/products/<int:product_id>/toggle", methods=["POST"])
@login_required
@role_required("admin", "staff")
def toggle_product(product_id):
    db = get_db()

    db.execute(
        """
        UPDATE products
        SET is_active = CASE WHEN is_active = 1 THEN 0 ELSE 1 END
        WHERE id = ?
        """,
        (product_id,)
    )

    db.commit()
    flash("Product status updated.", "success")

    return redirect(url_for("catalog.index"))


@catalog_bp.route("/products/<int:product_id>/variants", methods=["POST"])
@login_required
@role_required("admin", "staff")
def create_variant(product_id):
    db = get_db()

    product = db.execute(
        "SELECT id FROM products WHERE id = ?",
        (product_id,)
    ).fetchone()

    if not product:
        flash("Product not found.", "danger")
        return redirect(url_for("catalog.index"))

    attribute_name = request.form.get("attribute_name", "").strip()
    attribute_value = request.form.get("attribute_value", "").strip()

    try:
        price_adjustment = int(
            request.form.get("price_adjustment", "0")
        )

        if not attribute_name or not attribute_value:
            raise ValueError

        db.execute(
            """
            INSERT INTO product_variants (
                product_id,
                attribute_name,
                attribute_value,
                price_adjustment
            )
            VALUES (?, ?, ?, ?)
            """,
            (
                product_id,
                attribute_name,
                attribute_value,
                price_adjustment,
            )
        )

        db.commit()
        flash("Product variant added.", "success")

    except ValueError:
        db.rollback()
        flash("Enter valid variant details.", "danger")

    except Exception:
        db.rollback()
        flash("Could not add variant. It may already exist.", "danger")

    return redirect(url_for("catalog.index"))


@catalog_bp.route("/tax-rates/create", methods=["POST"])
@login_required
@role_required("admin")
def create_tax_rate():
    db = get_db()

    name = request.form.get("name", "").strip()

    try:
        rate = float(request.form.get("rate", ""))

        if not name or not 0 <= rate <= 100:
            raise ValueError

        db.execute(
            """
            INSERT INTO tax_rates (name, rate)
            VALUES (?, ?)
            """,
            (name, rate)
        )

        db.commit()
        flash("Tax rate created.", "success")

    except ValueError:
        db.rollback()
        flash("Enter a valid tax rate between 0 and 100.", "danger")

    return redirect(url_for("catalog.index"))


@catalog_bp.route("/tax-rates/<int:tax_id>/toggle", methods=["POST"])
@login_required
@role_required("admin")
def toggle_tax_rate(tax_id):
    db = get_db()

    db.execute(
        """
        UPDATE tax_rates
        SET is_active = CASE WHEN is_active = 1 THEN 0 ELSE 1 END
        WHERE id = ?
        """,
        (tax_id,)
    )

    db.commit()
    flash("Tax rate status updated.", "success")

    return redirect(url_for("catalog.index"))

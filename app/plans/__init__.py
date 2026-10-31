
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

plans_bp = Blueprint("plans", __name__, url_prefix="/plans")

def rupees_to_paise(value):
    return int(
        (Decimal(str(value)) * 100).quantize(
            Decimal("1"),
            rounding=ROUND_HALF_UP
        )
    )

FREQUENCIES = {"daily", "weekly", "monthly", "yearly"}


@plans_bp.route("/")
@login_required
@role_required("admin", "staff","finance_lead")
def index():
    db = get_db()

    plans = db.execute(
        """
        SELECT
            p.*,
            COUNT(pl.id) AS line_count
        FROM plans p
        LEFT JOIN plan_lines pl ON pl.plan_id = p.id
        GROUP BY p.id
        ORDER BY p.id DESC
        """
    ).fetchall()

    products = db.execute(
        """
        SELECT id, name, sales_price
        FROM products
        WHERE is_active = 1
        ORDER BY name
        """
    ).fetchall()

    templates = db.execute(
        """
        SELECT
            qt.*,
            p.name AS plan_name,
            COUNT(qtl.id) AS line_count
        FROM quotation_templates qt
        JOIN plans p ON p.id = qt.plan_id
        LEFT JOIN quotation_template_lines qtl
            ON qtl.template_id = qt.id
        GROUP BY qt.id
        ORDER BY qt.id DESC
        """
    ).fetchall()

    return render_template(
        "plans/index.html",
        plans=plans,
        products=products,
        templates=templates,
    )


@plans_bp.route("/create", methods=["POST"])
@login_required
@role_required("admin")
def create_plan():
    db = get_db()

    name = request.form.get("name", "").strip()
    frequency = request.form.get("billing_frequency", "").strip()

    if not name or frequency not in FREQUENCIES:
        flash("Enter a valid plan name and billing frequency.", "danger")
        return redirect(url_for("plans.index"))

    try:
        interval = int(request.form.get("billing_interval", "1"))
        price = int(request.form.get("price", "0"))
        minimum_quantity = int(
            request.form.get("minimum_quantity", "1")
        )

        if interval <= 0 or price < 0 or minimum_quantity <= 0:
            raise ValueError

        available_from = request.form.get("available_from") or None
        available_until = request.form.get("available_until") or None

        if (
            available_from
            and available_until
            and available_until < available_from
        ):
            raise ValueError

        db.execute(
            """
            INSERT INTO plans (
                name,
                billing_frequency,
                billing_interval,
                price,
                minimum_quantity,
                available_from,
                available_until,
                auto_close_on_expiry,
                allow_early_cancellation,
                allow_pause,
                allow_renewal
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                name,
                frequency,
                interval,
                price,
                minimum_quantity,
                available_from,
                available_until,
                int(request.form.get("auto_close_on_expiry") == "on"),
                int(request.form.get("allow_early_cancellation") == "on"),
                int(request.form.get("allow_pause") == "on"),
                int(request.form.get("allow_renewal") == "on"),
            )
        )

        db.commit()
        flash("Plan created successfully.", "success")

    except ValueError:
        db.rollback()
        flash("Check the plan prices, dates and quantities.", "danger")

    return redirect(url_for("plans.index"))


@plans_bp.route("/<int:plan_id>/lines/create", methods=["POST"])
@login_required
@role_required("admin")
def create_plan_line(plan_id):
    db = get_db()

    if not db.execute(
        "SELECT id FROM plans WHERE id = ?",
        (plan_id,)
    ).fetchone():
        flash("Plan not found.", "danger")
        return redirect(url_for("plans.index"))

    try:
        product_id = int(request.form.get("product_id", ""))
        quantity = int(request.form.get("quantity", "1"))
        unit_price = int(request.form.get("unit_price", ""))

        if quantity <= 0 or unit_price < 0:
            raise ValueError

        product = db.execute(
            """
            SELECT id
            FROM products
            WHERE id = ? AND is_active = 1
            """,
            (product_id,)
        ).fetchone()

        if not product:
            raise ValueError

        variant_id = request.form.get("variant_id") or None

        if variant_id:
            variant_id = int(variant_id)

            valid_variant = db.execute(
                """
                SELECT id
                FROM product_variants
                WHERE id = ? AND product_id = ?
                """,
                (variant_id, product_id)
            ).fetchone()

            if not valid_variant:
                raise ValueError

        db.execute(
            """
            INSERT INTO plan_lines (
                plan_id,
                product_id,
                variant_id,
                quantity,
                unit_price
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            (plan_id, product_id, variant_id, quantity, unit_price)
        )

        db.commit()
        flash("Plan line added.", "success")

    except (ValueError, TypeError):
        db.rollback()
        flash("Enter valid plan line details.", "danger")

    return redirect(url_for("plans.index"))


@plans_bp.route("/lines/<int:line_id>/delete", methods=["POST"])
@login_required
@role_required("admin")
def delete_plan_line(line_id):
    db = get_db()

    db.execute(
        "DELETE FROM plan_lines WHERE id = ?",
        (line_id,)
    )

    db.commit()
    flash("Plan line removed.", "success")

    return redirect(url_for("plans.index"))


@plans_bp.route("/<int:plan_id>/toggle", methods=["POST"])
@login_required
@role_required("admin")
def toggle_plan(plan_id):
    db = get_db()

    db.execute(
        """
        UPDATE plans
        SET is_active = CASE WHEN is_active = 1 THEN 0 ELSE 1 END
        WHERE id = ?
        """,
        (plan_id,)
    )

    db.commit()
    flash("Plan status updated.", "success")

    return redirect(url_for("plans.index"))


@plans_bp.route("/templates/create", methods=["POST"])
@login_required
@role_required("admin")
def create_template():
    db = get_db()

    name = request.form.get("name", "").strip()

    try:
        plan_id = int(request.form.get("plan_id", ""))
        validity_days = int(request.form.get("validity_days", "30"))

        if not name or validity_days <= 0:
            raise ValueError

        plan = db.execute(
            "SELECT id FROM plans WHERE id = ?",
            (plan_id,)
        ).fetchone()

        if not plan:
            raise ValueError

        cursor = db.execute(
            """
            INSERT INTO quotation_templates (
                name,
                plan_id,
                validity_days
            )
            VALUES (?, ?, ?)
            """,
            (name, plan_id, validity_days)
        )

        template_id = cursor.lastrowid

        # Copy the plan's current lines into the quotation template.
        db.execute(
            """
            INSERT INTO quotation_template_lines (
                template_id,
                product_id,
                variant_id,
                quantity,
                unit_price
            )
            SELECT ?, product_id, variant_id, quantity, unit_price
            FROM plan_lines
            WHERE plan_id = ?
            """,
            (template_id, plan_id)
        )

        db.commit()
        flash("Quotation template created.", "success")

    except (ValueError, TypeError):
        db.rollback()
        flash("Enter valid quotation template details.", "danger")

    return redirect(url_for("plans.index"))


@plans_bp.route("/templates/<int:template_id>/toggle", methods=["POST"])
@login_required
@role_required("admin")
def toggle_template(template_id):
    db = get_db()

    db.execute(
        """
        UPDATE quotation_templates
        SET is_active = CASE WHEN is_active = 1 THEN 0 ELSE 1 END
        WHERE id = ?
        """,
        (template_id,)
    )

    db.commit()
    flash("Quotation template status updated.", "success")

    return redirect(url_for("plans.index"))

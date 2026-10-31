import hashlib
import secrets
from datetime import datetime, timedelta

from flask import (
    Blueprint, current_app, flash, redirect, render_template,
    request, session, url_for
)

from app.db import get_db
from app.mail import send_email
from app.security import (
    current_user, login_required, normalize_email,
    password_hasher, validate_password
)

auth_bp = Blueprint("auth", __name__)


@auth_bp.route("/")
def landing():
    if current_user():
        return redirect(url_for("dashboard.index"))
    return render_template("landing.html")


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user():
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        email = normalize_email(request.form.get("email", ""))
        password = request.form.get("password", "")

        user = get_db().execute(
            """
            SELECT id, full_name, email, password_hash, role, is_active
            FROM users
            WHERE email = ?
            """,
            (email,)
        ).fetchone()

        if (
            not user
            or not user["is_active"]
            or not password_hasher.verify(user["password_hash"], password)
        ):
            flash("Invalid email or password.", "error")
            return render_template("auth/login.html")

        session.clear()
        session["user_id"] = user["id"]
        session["role"] = user["role"]

        flash(f"Welcome back, {user['full_name']}.", "success")

        destination = request.args.get("next", "")
        if destination.startswith("/") and not destination.startswith("//"):
            return redirect(destination)

        return redirect(url_for("dashboard.index"))

    return render_template("auth/login.html")


@auth_bp.route("/logout", methods=["POST"])
@login_required
def logout():
    session.clear()
    flash("You have been logged out.", "success")
    return redirect(url_for("auth.login"))


@auth_bp.route("/signup", methods=["GET", "POST"])
def signup():
    if current_user():
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        name = request.form.get("full_name", "").strip()
        email = normalize_email(request.form.get("email", ""))
        password = request.form.get("password", "")
        confirm = request.form.get("confirm_password", "")
        company = request.form.get("company_name", "").strip()
        phone = request.form.get("phone", "").strip()

        if not name or not email:
            flash("Name and email are required.", "error")
        elif password != confirm:
            flash("Passwords do not match.", "error")
        else:
            valid, message = validate_password(password)

            if not valid:
                flash(message, "error")
            else:
                db = get_db()

                try:
                    with db:
                        cursor = db.execute(
                            """
                            INSERT INTO users (
                                full_name, email, password_hash, role
                            )
                            VALUES (?, ?, ?, 'customer')
                            """,
                            (
                                name,
                                email,
                                password_hasher.hash(password),
                            )
                        )

                        user_id = cursor.lastrowid

                        db.execute(
                            """
                            INSERT INTO customers (
                                user_id, name, company_name, email, phone
                            )
                            VALUES (?, ?, ?, ?, ?)
                            """,
                            (user_id, name, company or None, email, phone or None)
                        )

                    flash(
                        "Your account has been created. You can now sign in.",
                        "success"
                    )
                    return redirect(url_for("auth.login"))

                except Exception:
                    current_app.logger.exception("Signup failed")
                    flash(
                        "An account with this email may already exist.",
                        "error"
                    )

    return render_template("auth/signup.html")


@auth_bp.route("/forgot-password", methods=["GET", "POST"])
def forgot_password():
    if request.method == "POST":
        email = normalize_email(request.form.get("email", ""))
        db = get_db()

        user = db.execute(
            """
            SELECT id, full_name, email
            FROM users
            WHERE email = ? AND is_active = 1
            """,
            (email,)
        ).fetchone()

        # Always show the same response to avoid revealing registered emails.
        flash(
            "If an active account exists for that email, reset instructions "
            "have been generated.",
            "success"
        )

        if user:
            raw_token = secrets.token_urlsafe(32)
            token_hash = hashlib.sha256(
                raw_token.encode("utf-8")
            ).hexdigest()

            expires = (
                datetime.utcnow() + timedelta(minutes=30)
            ).strftime("%Y-%m-%d %H:%M:%S")

            with db:
                db.execute(
                    """
                    UPDATE users
                    SET reset_token_hash = ?, reset_expires_at = ?
                    WHERE id = ?
                    """,
                    (token_hash, expires, user["id"])
                )

            reset_url = url_for(
                "auth.reset_password",
                token=raw_token,
                _external=True
            )
            body = (
                f"Hello {user['full_name']},\n\n"
                f"Use this link to reset your Staxio password:\n{reset_url}\n\n"
                "This link expires in 30 minutes."
            )
            sent = send_email(
                user["email"],
                "Reset your Staxio password",
                body
            )
            if not sent:
                current_app.logger.info(
                    "DEMO PASSWORD RESET LINK for %s: %s",
                    user["email"],
                    reset_url
                )
                flash("Demo mode: check the Flask terminal for the reset link.","info")
        return redirect(url_for("auth.forgot_password"))

    return render_template("auth/forgot_password.html")


@auth_bp.route("/reset-password/<token>", methods=["GET", "POST"])
def reset_password(token):
    token_hash = hashlib.sha256(
        token.encode("utf-8")
    ).hexdigest()

    db = get_db()

    user = db.execute(
        """
        SELECT id
        FROM users
        WHERE reset_token_hash = ?
          AND reset_expires_at >= datetime('now')
          AND is_active = 1
        """,
        (token_hash,)
    ).fetchone()

    if not user:
        flash("This password-reset link is invalid or has expired.", "error")
        return redirect(url_for("auth.forgot_password"))

    if request.method == "POST":
        password = request.form.get("password", "")
        confirm = request.form.get("confirm_password", "")

        if password != confirm:
            flash("Passwords do not match.", "error")
        else:
            valid, message = validate_password(password)

            if not valid:
                flash(message, "error")
            else:
                with db:
                    db.execute(
                        """
                        UPDATE users
                        SET password_hash = ?,
                            reset_token_hash = NULL,
                            reset_expires_at = NULL
                        WHERE id = ?
                        """,
                        (password_hasher.hash(password), user["id"])
                    )
                flash("Password updated. Please sign in.", "success")
                return redirect(url_for("auth.login"))

    return render_template("auth/reset_password.html")
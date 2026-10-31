import re
import secrets
from functools import wraps
from flask import (session,request,abort,redirect,url_for,flash,jsonify)
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, VerificationError

from app.db import get_db


password_hasher = PasswordHasher()

def hash_password(password):
    validate_password(password)
    return password_hasher.hash(password)


def verify_password(password_hash, password):
    try:
        return password_hasher.verify(password_hash, password)
    except (VerifyMismatchError, VerificationError):
        return False

def validate_password(password):
    if len(password) <= 8:
        return False, "Password must be longer than 8 characters."

    if not any(char.isupper() for char in password):
        return False, "Password must contain an uppercase letter."

    if not any(char.islower() for char in password):
        return False, "Password must contain a lowercase letter."

    if not any(not char.isalnum() for char in password):
        return False, "Password must contain a special character."

    return True, "Password is valid."


def normalize_email(email):
    return email.strip().lower()


# def generate_csrf_token():
#     if "_csrf_token" not in session:
#         session["_csrf_token"] = secrets.token_urlsafe(32)

#     return session["_csrf_token"]


# def validate_csrf():
#     if request.method != "POST":
#         return
#     expected = session.get("_csrf_token")

#     supplied = (
#         request.headers.get("X-CSRF-Token")
#         or request.form.get("csrf_token")
#     )
#     import hmac
#     if (
#         not expected
#         or not supplied
#         or not hmac.compare_digest(expected, supplied)
#     ):
#         abort(400, description="Invalid or expired CSRF token.")


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("user_id"):
            flash("Please log in to continue.", "warning")
            return redirect(url_for("auth.login"))

        db = get_db()

        user = db.execute(
            """
            SELECT id, full_name, email, role, is_active
            FROM users
            WHERE id = ?
            """,
            (session["user_id"],)
        ).fetchone()

        if not user or not user["is_active"]:
            session.clear()
            flash("Your session is no longer valid.", "warning")
            return redirect(url_for("auth.login"))

        return view(*args, **kwargs)
    return wrapped


def role_required(*roles):
    def decorator(view):
        @wraps(view)
        @login_required
        def wrapped(*args, **kwargs):
            db = get_db()
            user = db.execute("SELECT role FROM users WHERE id = ? AND is_active = 1",(session["user_id"],)).fetchone()
            if not user or user["role"] not in roles:
                abort(403)

            return view(*args, **kwargs)
        return wrapped
    return decorator


def current_user():
    if not session.get("user_id"):
        return None

    return get_db().execute(
        """
        SELECT id, full_name, email, role
        FROM users
        WHERE id = ? AND is_active = 1
        """,
        (session["user_id"],)
    ).fetchone()
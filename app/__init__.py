import os

from datetime import timedelta
from decimal import Decimal, ROUND_HALF_UP

from flask import Flask, current_app, request, jsonify
from app.security import current_user, login_required
from datetime import date

from app.config import Config
from app.db import init_app
from app.errors import register_error_handlers

from app.StaxioAI import handle_message

def create_app(test_config=None):
    app = Flask(__name__)
    app.config.from_object(Config)

    app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'dev-key-placeholder')

    if test_config:
        app.config.update(test_config)
    os.makedirs(
        os.path.dirname(app.config["DATABASE"]) or ".",
        exist_ok=True
    )

    app.permanent_session_lifetime = timedelta(hours=1)
    init_app(app)

    @app.context_processor
    def inject_globals():
        return {
            "company_name": app.config["COMPANY_NAME"],
            "current_user": current_user(),
            "current_year": date.today().year,
            "available_endpoints": set(current_app.view_functions.keys()),
        }

    @app.template_filter("rupees")
    def rupees(paise):
        paise = int(paise or 0)
        return f"₹{paise // 100:,}.{paise % 100:02d}"

    @app.template_filter("percentage")
    def percentage(value):
        return f"{Decimal(str(value or 0)):.2f}%"

    register_error_handlers(app)

    # Register blueprints here as they are implemented.
    from app.auth import auth_bp
    from app.catalog import catalog_bp
    from app.plans import plans_bp
    from app.customers import customers_bp
    from app.subscriptions import subscriptions_bp
    from app.invoices import invoices_bp
    from app.payments import payments_bp
    from app.discounts import discounts_bp
    from app.dashboard import dashboard_bp
    from app.portal import portal_bp
    from app.staff import staff_bp
    from app.finance import finance_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(catalog_bp)
    app.register_blueprint(plans_bp)
    app.register_blueprint(customers_bp)
    app.register_blueprint(subscriptions_bp)
    app.register_blueprint(invoices_bp)
    app.register_blueprint(payments_bp)
    app.register_blueprint(discounts_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(portal_bp)
    app.register_blueprint(staff_bp)
    app.register_blueprint(finance_bp)

    # StaxioAI Chat API
    @app.route("/api/ai/chat", methods=["POST"])
    @login_required
    def ai_chat():
        user = current_user()

        if not user:
            return jsonify({"error": "Authentication required"}), 401

        user_role = user["role"]

        if user_role not in ["admin", "finance_lead", "staff"]:
            return jsonify({"error": "Unauthorized role"}), 403

        data = request.get_json(silent=True) or {}
        message = str(data.get("message", "")).strip()

        if not message:
            return jsonify({"error": "Message is required"}), 400

        try:
            result = handle_message(message, user_role=user_role)

        except Exception:
            import traceback
            traceback.print_exc()

            return jsonify({
                "error": "AI service temporarily unavailable"
            }), 500

        if result.get("intent") == "ERROR":
            return jsonify({
                "error": result.get("answer", "AI service temporarily unavailable")
            }), 500

        return jsonify({
            "reply": result.get("answer", "No response received."),
            "intent": result.get("intent"),
            "tool": result.get("tool")
        })

    return app
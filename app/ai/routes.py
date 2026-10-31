# app/blueprints/ai_chat.py : minimal endpoint the sidebar calls. Replace the reply with your LLM call.
from flask import Blueprint, jsonify, request, session
from app.security import login_required   # your existing decorator

bp = Blueprint("ai", __name__, url_prefix="/ai")

@bp.post("/chat")
@login_required
def message():
    data = request.get_json(silent=True) or {}
    text = (data.get("message") or "").strip()[:1000]
    if not text:
        return jsonify(error="Please type a message."), 400
    # Call your LLM here. Scope any data lookups to the user's role/customer:
    #   customers may only see their own subscriptions and invoices.
    reply = f"(demo) You asked: {text}"
    return jsonify(reply=reply)
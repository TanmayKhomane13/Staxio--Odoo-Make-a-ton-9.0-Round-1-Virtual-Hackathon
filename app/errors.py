import sqlite3

from flask import (
    flash,
    redirect,
    request,
    jsonify,
    render_template
)


def handle_database_error(error):
    message = str(error)

    if isinstance(error, sqlite3.IntegrityError):
        return message

    if isinstance(error, sqlite3.DatabaseError):
        return message

    return "Something went wrong. Please try again."


def database_error_response(error):
    message = handle_database_error(error)

    if request.is_json or request.headers.get(
        "X-Requested-With"
    ) == "fetch":
        return jsonify({
            "success": False,
            "error": message
        }), 400

    flash(message, "danger")
    return redirect(request.referrer or "/")


def register_error_handlers(app):

    @app.errorhandler(403)
    def forbidden(error):
        return render_template("errors/403.html"), 403

    @app.errorhandler(404)
    def not_found(error):
        return render_template("errors/404.html"), 404

    @app.errorhandler(500)
    def server_error(error):
        app.logger.exception("Internal server error")
        return render_template("errors/500.html"), 500
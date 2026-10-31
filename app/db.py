import sqlite3
from pathlib import Path

from flask import current_app, g


def get_db():
    if "db" not in g:
        database = current_app.config["DATABASE"]

        Path(database).parent.mkdir(
            parents=True,
            exist_ok=True
        )

        db = sqlite3.connect(
            database,
            detect_types=sqlite3.PARSE_DECLTYPES,
            timeout=10
        )

        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys = ON")
        db.execute("PRAGMA busy_timeout = 10000")

        g.db = db

    return g.db


def close_db(error=None):
    db = g.pop("db", None)

    if db is not None:
        if error is not None:
            db.rollback()

        db.close()


def init_db():
    db = get_db()

    schema_path = (
        Path(current_app.root_path).parent
        / "schema_lite.sql"
    )

    with open(schema_path, "r", encoding="utf-8") as file:
        schema = file.read()

    db.executescript(schema)


def init_app(app):
    app.teardown_appcontext(close_db)
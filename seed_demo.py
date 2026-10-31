from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

try:
    from argon2 import PasswordHasher
    from argon2.exceptions import VerifyMismatchError
except ImportError:
    print(
        "ERROR: argon2-cffi is required for password hashing.\n"
        "  pip install argon2-cffi",
        file=sys.stderr,
    )
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR

DEFAULT_DB = PROJECT_ROOT / "instance" / "staxio.db"

CANDIDATE_SCHEMA = [
    SCRIPT_DIR / "schema.sql",
    PROJECT_ROOT / "schema.sql",
    PROJECT_ROOT / "schema.sql",
    PROJECT_ROOT / "attachments" / "schema.sql",
    Path("/home/workdir/artifacts/schema.sql"),
    Path("/home/workdir/attachments/schema.sql"),
]

CANDIDATE_SEED = [
    SCRIPT_DIR / "demo_seed.sql",
    SCRIPT_DIR / "demo_seed.sql",
    PROJECT_ROOT / "demo_seed.sql",
    PROJECT_ROOT / "demo_seed.sql",
    PROJECT_ROOT / "artifacts" / "demo_seed.sql",
    Path("/home/workdir/artifacts/demo_seed.sql"),
]

# Demo accounts → plaintext passwords (hashed at seed time with argon2)
DEMO_PASSWORDS = {
    "admin@staxio.example": "Admin@12345",
    "anita@staxio.example": "Staff@12345",
    "ravi@acme.example": "Customer@123",
    "priya@example.com": "Customer@123",
}

# Same defaults Flask's PasswordHasher typically uses
password_hasher = PasswordHasher()


def find_file(candidates: list[Path], label: str) -> Path:
    for p in candidates:
        if p.is_file():
            return p
    print(f"ERROR: could not find {label}. Looked in:", file=sys.stderr)
    for p in candidates:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), timeout=30.0)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 30000")
    return conn


def table_count(conn: sqlite3.Connection) -> int:
    row = conn.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchone()
    return row[0] if row else 0


def apply_script(conn: sqlite3.Connection, path: Path, label: str) -> None:
    print(f"→ Applying {label}: {path}")
    sql = path.read_text(encoding="utf-8")
    try:
        conn.executescript(sql)
    except sqlite3.Error as exc:
        print(f"ERROR while applying {label}: {exc}", file=sys.stderr)
        raise


def set_demo_passwords(conn: sqlite3.Connection) -> None:
    """Replace placeholder password hashes with real argon2 hashes."""
    print("→ Setting demo user password hashes (argon2) …")
    updated = 0
    for email, plain in DEMO_PASSWORDS.items():
        pw_hash = password_hasher.hash(plain)
        cur = conn.execute(
            "UPDATE users SET password_hash = ? WHERE email = ?",
            (pw_hash, email),
        )
        if cur.rowcount:
            # sanity-check verify
            try:
                password_hasher.verify(pw_hash, plain)
                ok = "verified"
            except VerifyMismatchError:
                ok = "VERIFY FAILED"
            print(f"   {email:30s}  →  {plain}  ({ok})")
            updated += 1
        else:
            print(f"   {email:30s}  (user not found – skipped)")
    if updated == 0:
        print("   WARNING: no users updated – check emails in demo_seed.sql")
    conn.commit()


def verify(conn: sqlite3.Connection) -> None:
    print("\n── Verification ─────────────────────────────────────────")
    checks = [
        ("users", "SELECT COUNT(*) FROM users"),
        ("customers", "SELECT COUNT(*) FROM customers"),
        ("products", "SELECT COUNT(*) FROM products"),
        ("plans", "SELECT COUNT(*) FROM plans"),
        ("subscriptions", "SELECT COUNT(*) FROM subscriptions"),
        ("invoices", "SELECT COUNT(*) FROM invoices"),
        ("payments", "SELECT COUNT(*) FROM payments"),
        ("discounts", "SELECT COUNT(*) FROM discounts"),
    ]
    for name, sql in checks:
        try:
            n = conn.execute(sql).fetchone()[0]
            print(f"  {name:18s} {n}")
        except sqlite3.Error as exc:
            print(f"  {name:18s} ERROR: {exc}")

    fk = conn.execute("PRAGMA foreign_key_check").fetchall()
    print(f"  foreign_key_check  {'OK' if not fk else fk}")
    print(f"  integrity_check    {conn.execute('PRAGMA integrity_check').fetchone()[0]}")

    print("\n── Demo logins (argon2) ─────────────────────────────────")
    for email, plain in DEMO_PASSWORDS.items():
        row = conn.execute(
            "SELECT role, password_hash FROM users WHERE email = ?", (email,)
        ).fetchone()
        if row:
            role, h = row
            try:
                password_hasher.verify(h, plain)
                status = "OK"
            except Exception as exc:
                status = f"FAIL ({exc})"
            print(f"  {role:10s}  {email:30s}  {plain:15s}  {status}")
            print(f"             hash: {h[:50]}...")
        else:
            print(f"  (missing)  {email}")

    print("\n── Sample data ──────────────────────────────────────────")
    try:
        for row in conn.execute(
            "SELECT subscription_number, status FROM subscriptions ORDER BY id"
        ):
            print(f"  sub  {row[0]:12s}  {row[1]}")
        for row in conn.execute(
            "SELECT invoice_number, status, "
            "ROUND(amount_paid/100.0,2), ROUND((total_amount-amount_paid)/100.0,2) "
            "FROM invoices ORDER BY id"
        ):
            print(f"  inv  {row[0]:12s}  {row[1]:12s}  paid=₹{row[2]}  due=₹{row[3]}")
        for row in conn.execute("SELECT * FROM v_dashboard"):
            print(
                f"  dash active={row[0]}  revenue_month=₹{row[1]/100:.2f}  "
                f"outstanding=₹{row[3]/100:.2f}  overdue={row[4]}"
            )
    except sqlite3.Error as exc:
        print(f"  (sample query skipped: {exc})")


def main() -> int:
    parser = argparse.ArgumentParser(description="Seed instance/staxio.db (schema)")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="Database path")
    parser.add_argument("--schema", type=Path, help="Path to schema.sql")
    parser.add_argument("--seed", type=Path, help="Path to demo_seed.sql")
    parser.add_argument("--force", action="store_true", help="Delete existing DB and recreate")
    parser.add_argument("--seed-only", action="store_true", help="Only run seed (skip schema)")
    parser.add_argument("--no-verify", action="store_true", help="Skip verification")
    args = parser.parse_args()

    db_path: Path = args.db.resolve()
    schema_path = args.schema or find_file(CANDIDATE_SCHEMA, "schema.sql")
    seed_path = args.seed or find_file(CANDIDATE_SEED, "demo_seed.sql")

    print(f"Database : {db_path}")
    print(f"Schema   : {schema_path}")
    print(f"Seed     : {seed_path}")
    print()

    if args.force and db_path.exists():
        print("→ Removing existing database (--force)")
        db_path.unlink()
        for suffix in ("-wal", "-shm"):
            p = Path(str(db_path) + suffix)
            if p.exists():
                p.unlink()

    conn = connect(db_path)
    try:
        existing = table_count(conn)

        if not args.seed_only:
            if existing > 0 and not args.force:
                print(f"→ Database already has {existing} tables – skipping schema")
                print("  (use --force to recreate, or --seed-only to just re-seed)")
            else:
                apply_script(conn, schema_path, "schema")
                conn.commit()
                print(f"  tables after schema: {table_count(conn)}")
        else:
            if existing == 0:
                print("ERROR: --seed-only but database has no tables.", file=sys.stderr)
                return 1

        apply_script(conn, seed_path, "demo seed")
        conn.commit()

        # Always set real argon2 password hashes after seed
        set_demo_passwords(conn)

        if not args.no_verify:
            verify(conn)

        print(f"\nDone. Database ready at: {db_path}")
        return 0
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
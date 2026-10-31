import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

class Config:
    SECRET_KEY = os.getenv("SECRET_KEY")

    DATABASE = os.getenv(
        "DATABASE",
        str(BASE_DIR / "instance" / "staxio.db")
    )
    COMPANY_NAME = os.getenv("COMPANY_NAME","Brightloop Software")
    COMPANY_EMAIL = os.getenv("COMPANY_EMAIL","billing@brightloop.example")

    MAIL_SERVER = os.getenv("MAIL_SERVER")
    MAIL_PORT = int(os.getenv("MAIL_PORT", 587))
    MAIL_USERNAME = os.getenv("MAIL_USERNAME")
    MAIL_PASSWORD = os.getenv("MAIL_PASSWORD")
    MAIL_USE_TLS = (os.getenv("MAIL_USE_TLS", "true").lower() == "true")
    MAIL_DEFAULT_SENDER = os.getenv("MAIL_DEFAULT_SENDER",COMPANY_EMAIL)

    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    SESSION_COOKIE_SECURE = (os.getenv("COOKIE_SECURE", "false").lower() == "true")

    PERMANENT_SESSION_LIFETIME = 3600
    MAX_CONTENT_LENGTH = 2 * 1024 * 1024
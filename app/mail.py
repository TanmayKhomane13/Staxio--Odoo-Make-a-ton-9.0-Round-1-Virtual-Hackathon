import smtplib
from email.message import EmailMessage

from flask import current_app


def send_email(to, subject, body):

    server = current_app.config.get("MAIL_SERVER")

    if not server:
        print("\n" + "=" * 60)
        print("STAXIO EMAIL")
        print("To:", to)
        print("Subject:", subject)
        print(body)
        print("=" * 60 + "\n")
        return True

    message = EmailMessage()

    message["Subject"] = subject
    message["From"] = current_app.config["MAIL_DEFAULT_SENDER"]
    message["To"] = to
    message.set_content(body)

    try:
        with smtplib.SMTP(
            server,
            current_app.config["MAIL_PORT"],
            timeout=15
        ) as smtp:

            if current_app.config["MAIL_USE_TLS"]:
                smtp.starttls()

            username = current_app.config.get("MAIL_USERNAME")
            password = current_app.config.get("MAIL_PASSWORD")

            if username and password:
                smtp.login(username, password)

            smtp.send_message(message)

        return True

    except Exception:
        current_app.logger.exception("Email delivery failed")
        return False
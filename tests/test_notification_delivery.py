#!/usr/bin/env python3
"""Exercise notification delivery without contacting external services."""

from __future__ import annotations

import io
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from tests import smtp_sink


REPO_ROOT = Path(__file__).resolve().parents[1]
SMTP_TO = "secret-recipient@example.invalid"
SMTP_PASSWORD = "smtp-password-must-not-leak"
TELEGRAM_TOKEN = "123456789:telegram-token-must-not-leak"
TELEGRAM_CHAT_ID = "@notification_selftest"


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_notify_test(
    *,
    smtp_to: str = SMTP_TO,
    telegram_token: str = TELEGRAM_TOKEN,
    telegram_chat_id: str = TELEGRAM_CHAT_ID,
    mail_exit: int = 0,
    mail_stderr: str = "",
    curl_status: str = "200",
    curl_body: str = '{"ok":true}',
    curl_exit: int = 0,
) -> tuple[subprocess.CompletedProcess[str], tuple[str, ...], str, tuple[str, ...]]:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        bin_dir = root / "bin"
        tmp_dir = root / "tmp"
        log_dir = root / "logs"
        bin_dir.mkdir()
        tmp_dir.mkdir()
        log_dir.mkdir()
        mail_args_file = root / "mail-args"
        mail_body_file = root / "mail-body"
        curl_args_file = root / "curl-args"

        write_executable(
            bin_dir / "timeout",
            """#!/bin/sh
shift
exec "$@"
""",
        )
        write_executable(
            bin_dir / "mail",
            """#!/bin/sh
printf '%s\n' "$@" > "$MAIL_ARGS_FILE"
cat > "$MAIL_BODY_FILE"
printf '%s' "$MAIL_STDERR" >&2
exit "$MAIL_EXIT"
""",
        )
        write_executable(
            bin_dir / "curl",
            """#!/bin/sh
printf '%s\n' "$*" > "$CURL_ARGS_FILE"
printf '%s\n%s\n' "$CURL_BODY" "$CURL_STATUS"
exit "$CURL_EXIT"
""",
        )

        environment = os.environ.copy()
        for name in (
            "SMTP_TO",
            "SMTP_PASSWORD",
            "TELEGRAM_BOT_TOKEN",
            "TELEGRAM_CHAT_ID",
            "TMPDIR",
        ):
            environment.pop(name, None)
        environment.update(
            {
                "MAIL_ARGS_FILE": str(mail_args_file),
                "MAIL_BODY_FILE": str(mail_body_file),
                "MAIL_EXIT": str(mail_exit),
                "MAIL_STDERR": mail_stderr,
                "CURL_ARGS_FILE": str(curl_args_file),
                "CURL_BODY": curl_body,
                "CURL_EXIT": str(curl_exit),
                "CURL_STATUS": curl_status,
                "FLY_APP_NAME": "notification-test-app",
                "PATH": f"{bin_dir}:{environment['PATH']}",
                "RESTIC_LOG_DIR": str(log_dir),
                "SMTP_HOST": "smtp.example.invalid",
                "SMTP_PASSWORD": SMTP_PASSWORD,
                "SMTP_TO": smtp_to,
                "SMTP_USERNAME": "smtp-user@example.invalid",
                "TMPDIR": str(tmp_dir),
                "TELEGRAM_BOT_TOKEN": telegram_token,
                "TELEGRAM_CHAT_ID": telegram_chat_id,
            }
        )
        result = subprocess.run(
            ["bash", "scripts/restic.sh", "notify-test"],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        mail_args = (
            tuple(mail_args_file.read_text(encoding="utf-8").splitlines())
            if mail_args_file.exists()
            else ()
        )
        curl_args = (
            curl_args_file.read_text(encoding="utf-8").strip()
            if curl_args_file.exists()
            else ""
        )
        leftovers = tuple(str(path.relative_to(tmp_dir)) for path in tmp_dir.iterdir())
        return result, mail_args, curl_args, leftovers


class NotificationDeliveryTest(unittest.TestCase):
    def test_notify_test_delivers_both_channels_and_cleans_scratch_files(self) -> None:
        result, mail_args, curl_args, leftovers = run_notify_test()

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue(
            any("Notification test" in argument for argument in mail_args), mail_args
        )
        self.assertIn("--data-urlencode", curl_args)
        self.assertIn("disable_web_page_preview=true", curl_args)
        self.assertIn("https://api.telegram.org/", curl_args)
        self.assertIn("Alert email sent", result.stderr + result.stdout)
        self.assertIn("Telegram notification sent", result.stderr + result.stdout)
        self.assertIn("Notification test passed", result.stderr + result.stdout)
        self.assertEqual(leftovers, ())

    def test_notify_test_fails_when_either_channel_is_not_configured(self) -> None:
        result, mail_args, curl_args, leftovers = run_notify_test(
            smtp_to="", telegram_token="", telegram_chat_id=""
        )

        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertEqual(mail_args, ())
        self.assertEqual(curl_args, "")
        self.assertIn("SMTP_TO is not configured", result.stderr + result.stdout)
        self.assertIn("must both be configured", result.stderr + result.stdout)
        self.assertEqual(leftovers, ())

    def test_mail_failure_fails_the_command_and_redacts_secrets(self) -> None:
        result, mail_args, curl_args, leftovers = run_notify_test(
            mail_exit=47,
            mail_stderr=f"relay rejected {SMTP_PASSWORD} for {SMTP_TO}\n",
        )
        output = result.stderr + result.stdout

        self.assertEqual(result.returncode, 1, output)
        self.assertIn("Alert email failed (exit 47)", output)
        self.assertIn("Telegram notification sent", output)
        self.assertIn("Notification test failed", output)
        self.assertTrue(
            any("Notification test" in argument for argument in mail_args), mail_args
        )
        self.assertIn("https://api.telegram.org/", curl_args)
        self.assertNotIn(SMTP_PASSWORD, output)
        self.assertNotIn(SMTP_TO, output)
        self.assertEqual(leftovers, ())

    def test_telegram_rejection_fails_the_command_and_redacts_secrets(self) -> None:
        result, mail_args, curl_args, leftovers = run_notify_test(
            curl_status="500",
            curl_body=(
                f'{{"ok":false,"description":"rejected {TELEGRAM_TOKEN} '
                f'for {TELEGRAM_CHAT_ID}"}}'
            ),
        )
        output = result.stderr + result.stdout

        self.assertEqual(result.returncode, 1, output)
        self.assertIn("Alert email sent", output)
        self.assertIn("Telegram notification failed (HTTP 500)", output)
        self.assertIn("Notification test failed", output)
        self.assertTrue(
            any("Notification test" in argument for argument in mail_args), mail_args
        )
        self.assertIn(TELEGRAM_TOKEN, curl_args)
        self.assertNotIn(TELEGRAM_TOKEN, output)
        self.assertNotIn(TELEGRAM_CHAT_ID, output)
        self.assertEqual(leftovers, ())

    def test_nested_telegram_success_is_not_top_level_success(self) -> None:
        result, _, _, leftovers = run_notify_test(
            curl_status="200",
            curl_body='{"ok":false,"result":{"ok":true}}',
        )
        output = result.stderr + result.stdout

        self.assertEqual(result.returncode, 1, output)
        self.assertIn("Telegram notification failed (HTTP 200)", output)
        self.assertNotIn("Telegram notification sent", output)
        self.assertEqual(leftovers, ())


class SmtpSinkBindingTest(unittest.TestCase):
    def test_the_test_sink_binds_to_loopback_by_default(self) -> None:
        args = smtp_sink.parse_args(
            [
                "--cert",
                "cert.pem",
                "--key",
                "key.pem",
                "--out",
                "message.txt",
                "--ready",
                "port.txt",
            ]
        )

        self.assertEqual(args.bind, "127.0.0.1")

    def test_message_terminator_and_exact_limits_are_accepted(self) -> None:
        self.assertEqual(smtp_sink.read_message(io.BytesIO(b".\r\n")), "")

        line = b"x" * (smtp_sink.MAX_LINE_BYTES - 2) + b"\r\n"
        message = smtp_sink.read_message(
            io.BytesIO(line * (smtp_sink.MAX_MESSAGE_BYTES // len(line)) + b".\r\n")
        )
        self.assertEqual(message.count("\n") + 1, smtp_sink.MAX_MESSAGE_BYTES // len(line))

    def test_incomplete_lines_are_rejected(self) -> None:
        for reader in (io.BytesIO(b""), io.BytesIO(b"x")):
            with self.subTest(reader=reader.getvalue()), self.assertRaises(EOFError):
                smtp_sink.read_message(reader)

    def test_message_limits_reject_oversized_data(self) -> None:
        cases = (
            (
                b"x" * (smtp_sink.MAX_LINE_BYTES + 1) + b"\r\n.\r\n",
                "line exceeds",
            ),
            (
                (b"x" * 1024 + b"\r\n")
                * (smtp_sink.MAX_MESSAGE_BYTES // 1026 + 1)
                + b".\r\n",
                "message exceeds",
            ),
            (
                b"x\r\n" * (smtp_sink.MAX_MESSAGE_LINES + 1) + b".\r\n",
                "too many lines",
            ),
        )

        for payload, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(
                ValueError, message
            ):
                smtp_sink.read_message(io.BytesIO(payload))


if __name__ == "__main__":
    unittest.main()

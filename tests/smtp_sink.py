#!/usr/bin/env python3
"""Minimal STARTTLS SMTP sink for the alert-path test.

Speaks just enough SMTP for msmtp: EHLO, STARTTLS, AUTH PLAIN, MAIL, RCPT and
DATA. The first accepted message is written to --out and the process exits 0,
so the caller can assert on what actually reached the wire. It uses only the
standard library, so the same script runs on a developer machine and on the CI
runner without pulling another image.
"""

import argparse
import socket
import ssl
import sys


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bind", default="127.0.0.1", help="interface to listen on (default: loopback)"
    )
    parser.add_argument("--cert", required=True, help="PEM certificate chain")
    parser.add_argument("--key", required=True, help="PEM private key")
    parser.add_argument("--out", required=True, help="where to write the message")
    parser.add_argument("--ready", required=True, help="file holding the bound port")
    parser.add_argument("--port", type=int, default=0, help="0 picks a free port")
    parser.add_argument("--timeout", type=float, default=90.0)
    return parser.parse_args(argv)


def main():
    args = parse_args()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(1)
    server.settimeout(args.timeout)
    with open(args.ready, "w", encoding="utf-8") as handle:
        handle.write(str(server.getsockname()[1]))

    try:
        conn, _ = server.accept()
    except socket.timeout:
        sys.exit("smtp sink: no connection within %.0fs" % args.timeout)
    conn.settimeout(args.timeout)
    reader = conn.makefile("rb")

    def send(line):
        conn.sendall(line.encode() + b"\r\n")

    def readline():
        raw = reader.readline()
        if not raw:
            raise EOFError("client closed the connection")
        return raw.decode("utf-8", "replace").rstrip("\r\n")

    message = None
    send("220 sink ESMTP ready")
    try:
        while True:
            line = readline()
            verb = line.split(" ", 1)[0].upper()
            if verb in ("EHLO", "HELO"):
                send("250-sink")
                send("250-STARTTLS")
                send("250 AUTH PLAIN")
            elif verb == "STARTTLS":
                send("220 Ready to start TLS")
                conn = context.wrap_socket(conn, server_side=True)
                conn.settimeout(args.timeout)
                reader = conn.makefile("rb")
            elif verb == "AUTH":
                if len(line.split()) > 2:
                    send("235 Authentication succeeded")
                else:
                    send("334 ")
                    readline()
                    send("235 Authentication succeeded")
            elif verb in ("MAIL", "RCPT", "RSET", "NOOP"):
                send("250 OK")
            elif verb == "DATA":
                send("354 End data with <CR><LF>.<CR><LF>")
                lines = []
                while True:
                    data_line = readline()
                    if data_line == ".":
                        break
                    lines.append(data_line)
                message = "\n".join(lines)
                send("250 OK queued")
            elif verb == "QUIT":
                send("221 Bye")
                break
            else:
                send("502 Command not implemented")
    except (EOFError, OSError, ssl.SSLError) as exc:
        if message is None:
            sys.exit("smtp sink: no message arrived (%s)" % exc)

    if message is None:
        sys.exit("smtp sink: the client left without sending a message")
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(message + "\n")
    print("smtp sink: message received")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import argparse
import json
import os
import sqlite3
import sys
import time


def _load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return {}


def _write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def cmd_write_omp(args):
    data = json.dumps({
        "access": args.access,
        "refresh": args.refresh,
        "expires": int(args.expires),
        "accountId": args.account_id,
        "email": args.email,
    })
    identity_key = f"email:{args.email}"
    now = int(time.time())

    with sqlite3.connect(args.db) as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE auth_credentials "
            "SET disabled_cause = ?, updated_at = ? "
            "WHERE provider = 'openai-codex' AND disabled_cause IS NULL",
            (f"replaced by {args.replaced_by}", now),
        )
        cur.execute(
            "INSERT INTO auth_credentials "
            "(provider, credential_type, data, identity_key, created_at, updated_at) "
            "VALUES ('openai-codex', 'oauth', ?, ?, ?, ?)",
            (data, identity_key, now, now),
        )
        conn.commit()


def cmd_write_pi(args):
    existing = _load_json(args.path)
    existing["openai-codex"] = {
        "type": "oauth",
        "access": args.access,
        "refresh": args.refresh,
        "expires": int(args.expires),
        "accountId": args.account_id,
    }
    _write_json(args.path, existing)


def cmd_write_opencode(args):
    existing = _load_json(args.path)
    existing["openai"] = {
        "access": args.access,
        "refresh": args.refresh,
        "expires": int(args.expires),
        "accountId": args.account_id,
        "type": "oauth",
    }
    _write_json(args.path, existing)


def cmd_write_codex(args):
    existing = _load_json(args.path)
    if "tokens" not in existing:
        existing["tokens"] = {}
    existing["tokens"]["access_token"] = args.access
    existing["tokens"]["refresh_token"] = args.refresh
    existing["tokens"]["account_id"] = args.account_id
    _write_json(args.path, existing)


def cmd_write_meta(args):
    meta = {
        "name": args.name,
        "email": args.email,
        "saved_at": int(time.time()),
    }
    path = os.path.join(args.dir, f"{args.name}.meta.json")
    _write_json(path, meta)


def cmd_update_cockpit_current(args):
    existing = _load_json(args.path)
    if "current_accounts" not in existing:
        existing["current_accounts"] = {}
    existing["current_accounts"][args.provider] = args.account_id
    _write_json(args.path, existing)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p_omp = sub.add_parser("write-omp")
    p_omp.add_argument("--db", required=True)
    p_omp.add_argument("--access", required=True)
    p_omp.add_argument("--refresh", required=True)
    p_omp.add_argument("--expires", required=True)
    p_omp.add_argument("--account-id", required=True)
    p_omp.add_argument("--email", required=True)
    p_omp.add_argument("--replaced-by", required=True)
    p_omp.set_defaults(func=cmd_write_omp)

    p_pi = sub.add_parser("write-pi")
    p_pi.add_argument("--path", required=True)
    p_pi.add_argument("--access", required=True)
    p_pi.add_argument("--refresh", required=True)
    p_pi.add_argument("--expires", required=True)
    p_pi.add_argument("--account-id", required=True)
    p_pi.set_defaults(func=cmd_write_pi)

    p_opencode = sub.add_parser("write-opencode")
    p_opencode.add_argument("--path", required=True)
    p_opencode.add_argument("--access", required=True)
    p_opencode.add_argument("--refresh", required=True)
    p_opencode.add_argument("--expires", required=True)
    p_opencode.add_argument("--account-id", required=True)
    p_opencode.set_defaults(func=cmd_write_opencode)

    p_codex = sub.add_parser("write-codex")
    p_codex.add_argument("--path", required=True)
    p_codex.add_argument("--access", required=True)
    p_codex.add_argument("--refresh", required=True)
    p_codex.add_argument("--expires", required=True)
    p_codex.add_argument("--account-id", required=True)
    p_codex.set_defaults(func=cmd_write_codex)

    p_meta = sub.add_parser("write-meta")
    p_meta.add_argument("--dir", required=True)
    p_meta.add_argument("--name", required=True)
    p_meta.add_argument("--email", required=True)
    p_meta.set_defaults(func=cmd_write_meta)

    p_cockpit = sub.add_parser("update-cockpit-current")
    p_cockpit.add_argument("--path", required=True)
    p_cockpit.add_argument("--provider", required=True)
    p_cockpit.add_argument("--account-id", required=True)
    p_cockpit.set_defaults(func=cmd_update_cockpit_current)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(e, file=sys.stderr)
        sys.exit(1)

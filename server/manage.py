#!/usr/bin/env python3
"""Create a team and print its enrolment code. At ten customers this is the
whole provisioning story — no self-serve signup to build."""
import os
import secrets
import sys
import uuid
from datetime import datetime, timezone

import db
from app import sha256, sign

PUBLIC_URL = os.environ.get(
    "OBSERVER_PUBLIC_URL", "https://local-observer-hub.vercel.app").rstrip("/")


def require_secret() -> None:
    """Checked before anything is written, so a refused command leaves no org
    behind for someone to wonder about."""
    if os.environ.get("OBSERVER_SECRET", "") in ("", "dev-secret-change-me"):
        sys.exit("OBSERVER_SECRET is not set. Pull it first:\n"
                 "  vercel env pull .env.production.local\n"
                 "then pass it through envrun.py alongside OBSERVER_DB_URL.")


def admin_link(org_id: str) -> str:
    """The same link the sign-in form emails, minted here instead.

    Signed with OBSERVER_SECRET, so a link made with the dev default would not
    open the deployed hub — and if the deployed hub were still using that
    default, anyone could mint one. Refusing to sign with it covers both.
    """
    require_secret()
    return f"{PUBLIC_URL}/admin?t={sign(org_id)}"

# No 0/O or 1/I: someone reads this off a wiki and types it.
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def new_code() -> str:
    part = lambda: "".join(secrets.choice(ALPHABET) for _ in range(4))
    return f"OBS-{part()}-{part()}"


def create_org(name: str, domain: str, seats: int = 10) -> None:
    require_secret()
    code = new_code()
    org_id = str(uuid.uuid4())
    with db.connect() as conn:
        conn.execute(
            "INSERT INTO orgs (id, name, email_domain, code_hash, seat_cap, created_at)"
            " VALUES (%s,%s,%s,%s,%s,%s)",
            (org_id, name, domain.lower(), sha256(code), seats,
             datetime.now(timezone.utc).isoformat()),
        )
    print(f"team:      {name}")
    print(f"domain:    {domain}   (only these addresses may enrol)")
    print(f"seats:     {seats}")
    print(f"code:      {code}")
    print("\nThis code is shown once. It is stored hashed, so it cannot be recovered —")
    print("re-run with a rotate command to issue a new one.")
    print(f"\nadmin link: {admin_link(org_id)}")
    print("Give the code to the team and the link to whoever runs it.")


def rotate(domain: str) -> None:
    code = new_code()
    with db.connect() as conn:
        cur = conn.execute("UPDATE orgs SET code_hash = %s WHERE email_domain = %s",
                           (sha256(code), domain.lower()))
        if cur.rowcount == 0:
            sys.exit(f"no team with domain {domain}")
    print(f"new code for {domain}: {code}")
    print("Existing installs keep working — rotation only stops new enrolments.")


def link(domain: str) -> None:
    """Hand an admin their way in without waiting for them to use the form."""
    with db.connect() as conn:
        org = conn.execute("SELECT id, name FROM orgs WHERE email_domain = %s",
                           (domain.lower(),)).fetchone()
    if org is None:
        sys.exit(f"no team with domain {domain}")
    print(f"{org['name']}: {admin_link(org['id'])}")


def listing() -> None:
    with db.connect() as conn:
        for org in conn.execute("SELECT * FROM orgs ORDER BY created_at").fetchall():
            people = conn.execute(
                "SELECT COUNT(DISTINCT email) n FROM installs"
                " WHERE org_id=%s AND revoked_at IS NULL", (org["id"],)).fetchone()["n"]
            shared = conn.execute(
                "SELECT COUNT(*) n FROM workflows WHERE org_id=%s AND retracted_at IS NULL",
                (org["id"],)).fetchone()["n"]
            print(f"{org['name']:24} {org['email_domain']:22} "
                  f"{people}/{org['seat_cap']} seats   {shared} shared")


def init() -> None:
    """Run once per deploy. Creating the schema is no longer a startup hook:
    on serverless that would fire concurrent DDL on every cold start."""
    db.init()
    print(f"schema applied to {db.DB_URL.rsplit('@', 1)[-1]}")


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["init"]:                            init()
        case ["create", name, domain]:            create_org(name, domain)
        case ["create", name, domain, seats]:     create_org(name, domain, int(seats))
        case ["rotate", domain]:                  rotate(domain)
        case ["link", domain]:                    link(domain)
        case ["list"]:                            listing()
        case _:
            print("usage: manage.py init")
            print("       manage.py create <name> <domain> [seats]")
            print("       manage.py rotate <domain>")
            print("       manage.py link <domain>")
            print("       manage.py list")

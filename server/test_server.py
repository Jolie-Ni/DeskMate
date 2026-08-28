"""Tests for the rules that matter: org isolation, domain binding, seat caps,
idempotency, rate limiting, and that a retraction actually hides the row.

These run against a real Postgres, not a stand-in. The whole reason the hub
moved off SQLite is that production is Postgres, and a suite that passes on a
different engine is the one that lets dialect bugs through.

    ./devdb.sh                     # starts one in Docker on :55432
    python test_server.py
"""
import os
import sys

DEFAULT_URL = "postgresql://postgres:postgres@localhost:55432/observer_test"
DB_URL = os.environ.get("OBSERVER_DB_URL", DEFAULT_URL)

# A guard rail, not a convention: this suite drops the schema on every run, and
# the cost of pointing it at the wrong database once is the whole hub.
if not DB_URL.rsplit("/", 1)[-1].split("?")[0].endswith("_test"):
    sys.exit("refusing to run: OBSERVER_DB_URL must name a database ending in _test")
os.environ["OBSERVER_DB_URL"] = DB_URL

from fastapi.testclient import TestClient  # noqa: E402
import app as srv  # noqa: E402
import db  # noqa: E402
import manage  # noqa: E402

client = TestClient(srv.app)


def reset() -> None:
    with db.connect() as conn:
        conn.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
    db.init()


def setup_org(name, domain, seats=10):
    """Create a team and recover its code by re-hashing candidates is not
    possible, so create it here where we still hold the plaintext."""
    code = manage.new_code()
    import uuid
    from datetime import datetime, timezone
    with db.connect() as conn:
        conn.execute(
            "INSERT INTO orgs (id,name,email_domain,code_hash,seat_cap,created_at)"
            " VALUES (%s,%s,%s,%s,%s,%s)",
            (str(uuid.uuid4()), name, domain, srv.sha256(code), seats,
             datetime.now(timezone.utc).isoformat()))
    return code


def payload(key="k1", title="Prospect research"):
    return {"idempotency_key": key, "title": title, "summary": "s",
            "trigger": "when a lead arrives",
            "sop_steps": [{"order": 1, "action": "Open", "detail": "d", "location": "linkedin.com"}],
            "automation": {"summary": "a", "approach": "b", "steps": [], "tools": [],
                           "human_in_the_loop": None, "risks": None},
            "locations": ["linkedin.com"]}


def enroll(code, email, name="Ana"):
    r = client.post("/v1/enroll", json={"code": code, "email": email, "name": name})
    assert r.status_code == 200, r.text
    return r.json()["install_token"]


def auth(tok):
    return {"Authorization": f"Bearer {tok}"}


def run():
    reset()
    results = []

    def check(label, cond):
        results.append((label, bool(cond)))

    code_a = setup_org("Acme", "acme.com", seats=2)
    code_b = setup_org("Beta", "beta.io", seats=5)

    tok_a = enroll(code_a, "ana@acme.com")
    tok_b = enroll(code_b, "ben@beta.io", "Ben")

    # domain binding
    r = client.post("/v1/enroll", json={"code": code_a, "email": "someone@gmail.com"})
    check("outside domain is rejected", r.status_code == 403)

    # bad code
    r = client.post("/v1/enroll", json={"code": "OBS-ZZZZ-ZZZZ", "email": "ana@acme.com"})
    check("unknown code is rejected", r.status_code == 403)

    # seat cap (Acme has 2, ana used 1)
    enroll(code_a, "amy@acme.com", "Amy")
    r = client.post("/v1/enroll", json={"code": code_a, "email": "third@acme.com"})
    check("seat cap enforced", r.status_code == 403)

    # share + idempotency
    r1 = client.post("/v1/workflows", json=payload(), headers=auth(tok_a))
    r2 = client.post("/v1/workflows", json=payload(), headers=auth(tok_a))
    check("first share creates", r1.status_code == 201)
    check("replay does not duplicate", r2.status_code == 200 and r2.json()["id"] == r1.json()["id"])

    # org isolation
    client.post("/v1/workflows", json=payload("k-beta", "Beta thing"), headers=auth(tok_b))
    mine_a = client.get("/v1/workflows/mine", headers=auth(tok_a)).json()["workflows"]
    check("only my org's rows are visible", all(w["title"] != "Beta thing" for w in mine_a))

    # no token
    check("unauthenticated share refused",
          client.post("/v1/workflows", json=payload("x")).status_code == 401)

    # retraction hides it from the admin too
    client.delete("/v1/workflows/k1", headers=auth(tok_a))
    mine_after = client.get("/v1/workflows/mine", headers=auth(tok_a)).json()["workflows"]
    check("retracted row leaves my list", all(w["idempotency_key"] != "k1" for w in mine_after))
    with db.connect() as conn:
        org = conn.execute("SELECT id FROM orgs WHERE email_domain='acme.com'").fetchone()
        visible = conn.execute(
            "SELECT COUNT(*) n FROM workflows WHERE org_id=%s AND retracted_at IS NULL",
            (org["id"],)).fetchone()["n"]
    check("retracted row leaves the admin view", visible == 0)

    # revoked install cannot write
    with db.connect() as conn:
        conn.execute("UPDATE installs SET revoked_at = '2026-01-01' WHERE email='ana@acme.com'")
    check("revoked install refused",
          client.post("/v1/workflows", json=payload("k2"), headers=auth(tok_a)).status_code == 401)

    # Sign-in. The response must not differ between a customer's domain and a
    # stranger's, or the form becomes a way to ask who the customers are.
    known = client.post("/admin/login", data={"email": "boss@acme.com"})
    unknown = client.post("/admin/login", data={"email": "boss@not-a-customer.test"})
    check("sign-in does not reveal whether a domain is a customer",
          known.status_code == unknown.status_code and known.text == unknown.text)

    with db.connect() as conn:
        org_a = conn.execute("SELECT id FROM orgs WHERE email_domain='acme.com'").fetchone()["id"]
        org_b = conn.execute("SELECT id FROM orgs WHERE email_domain='beta.io'").fetchone()["id"]
    page_a = client.get(f"/admin?t={srv.sign(org_a)}")
    check("a valid link opens that org's workflows",
          page_a.status_code == 200 and "Acme" in page_a.text and "Beta thing" not in page_a.text)
    page_b = client.get(f"/admin?t={srv.sign(org_b)}")
    check("each org's link opens only its own workflows",
          "Beta thing" in page_b.text and "Prospect research" not in page_b.text)
    check("an unsigned org id is refused",
          client.get(f"/admin?t={org_a}").status_code == 401)
    check("a forged signature is refused",
          client.get(f"/admin?t={org_a}.{'0' * 32}").status_code == 401)

    # Rate limiting. The point of the table is that it survives the process
    # boundary serverless puts between one request and the next, so the check
    # is that the count lives in Postgres and that emptying it restores service.
    with db.connect() as conn:
        conn.execute("DELETE FROM enrol_attempts")
    guess = {"code": "OBS-BAD1-BAD1", "email": "x@acme.com"}
    for _ in range(srv.RATE_MAX):
        client.post("/v1/enroll", json=guess)
    check("code guessing is rate limited",
          client.post("/v1/enroll", json=guess).status_code == 429)
    with db.connect() as conn:
        n = conn.execute("SELECT COUNT(*) AS n FROM enrol_attempts").fetchone()["n"]
    check("attempts are counted in the database, not in memory", n > 0)
    with db.connect() as conn:
        conn.execute("DELETE FROM enrol_attempts")
    check("an expired window restores service",
          client.post("/v1/enroll", json=guess).status_code == 403)

    # A rejected enrolment must still cost an attempt — if the rollback that
    # follows a 403 took the attempt row with it, the limiter would be free.
    with db.connect() as conn:
        after = conn.execute(
            "SELECT COUNT(*) AS n FROM enrol_attempts WHERE bucket = %s",
            ("code:OBS-BAD1-BAD1",)).fetchone()["n"]
    check("a refused attempt is not refunded", after == 1)

    width = max(len(l) for l, _ in results)
    for label, ok in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {label.ljust(width)}")
    failed = [l for l, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(run())

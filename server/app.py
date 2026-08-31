"""DeskMate hub — shares saved workflows to a company portal.

Scoped for teams under ten people. Four client endpoints, one admin page.
See the design brief for what was deliberately left out.

Security rules this file must keep:
  * tokens are stored hashed; the plaintext exists only on the client
  * every query is scoped by org_id taken from the token, never from a field
    the client supplied
  * enrolment is rate limited, because the enrolment code is short enough to
    guess offline
  * request bodies are never logged; they are the customer's work content
"""
import hashlib
import hmac
import html
import json
import os
import secrets
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import Depends, FastAPI, Form, Header, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, Field

import db

app = FastAPI(title="DeskMate hub", docs_url=None, redoc_url=None)
SECRET = os.environ.get("DESKMATE_SECRET", "dev-secret-change-me")


def now() -> str:
    return iso(datetime.now(timezone.utc))


def iso(dt: datetime) -> str:
    """Fixed-width UTC ISO-8601. Always six digits of microseconds, so these
    strings sort lexicographically and a TEXT column can be range-scanned
    without casting."""
    return dt.astimezone(timezone.utc).isoformat(timespec="microseconds")


def sha256(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


# ── enrolment ────────────────────────────────────────────────────────────────
#
# The enrolment code is typed by a human, so it is short — around 40 bits. That
# is guessable offline, which is exactly why it is rate limited and why it only
# ever buys one thing: the right to create one install.

RATE_WINDOW = timedelta(minutes=5)
RATE_MAX = 10
ATTEMPT_TTL = timedelta(hours=1)


def rate_limit(conn, key: str, what: str = "enrolment attempts") -> None:
    """Counts attempts in a shared table rather than in this process.

    Two details carry the security here. The attempt is written *before* the
    request is judged, so a wrong code still costs an attempt. And it is
    committed immediately, so the rollback that follows a rejected enrolment
    cannot refund it — which would make the whole limiter free to defeat.
    """
    conn.execute("INSERT INTO enrol_attempts (bucket, attempted_at) VALUES (%s, %s)",
                 (key, now()))
    # Cheap enough to do inline at this volume, and it means no cron job.
    conn.execute("DELETE FROM enrol_attempts WHERE attempted_at < %s",
                 (iso(datetime.now(timezone.utc) - ATTEMPT_TTL),))
    conn.commit()

    hits = conn.execute(
        "SELECT COUNT(*) AS n FROM enrol_attempts WHERE bucket = %s AND attempted_at > %s",
        (key, iso(datetime.now(timezone.utc) - RATE_WINDOW)),
    ).fetchone()["n"]
    if hits > RATE_MAX:
        raise HTTPException(429, f"Too many {what}. Try again in a few minutes.")


class EnrollRequest(BaseModel):
    code: str
    email: str
    name: str = ""
    device_name: str = "Mac"


class EnrollResponse(BaseModel):
    install_token: str
    org_name: str
    author_email: str
    author_name: str


@app.post("/v1/enroll", response_model=EnrollResponse)
def enroll(body: EnrollRequest, request: Request) -> EnrollResponse:
    email = body.email.strip().lower()

    with db.connect() as conn:
        rate_limit(conn, request.client.host if request.client else "unknown")
        rate_limit(conn, f"code:{body.code}")

        if "@" not in email:
            raise HTTPException(400, "That does not look like an email address.")

        org = conn.execute(
            "SELECT * FROM orgs WHERE code_hash = %s", (sha256(body.code.strip().upper()),)
        ).fetchone()
        if org is None:
            # Same message for a bad code and a wrong domain, so the endpoint
            # does not confirm which codes are real.
            raise HTTPException(403, "That enrolment code is not valid for this address.")

        if email.split("@")[1] != org["email_domain"].lower():
            raise HTTPException(403, "That enrolment code is not valid for this address.")

        seats = conn.execute(
            "SELECT COUNT(DISTINCT email) AS n FROM installs "
            "WHERE org_id = %s AND revoked_at IS NULL",
            (org["id"],),
        ).fetchone()["n"]
        already = conn.execute(
            "SELECT 1 FROM installs WHERE org_id = %s AND email = %s AND revoked_at IS NULL",
            (org["id"], email),
        ).fetchone()
        if already is None and seats >= org["seat_cap"]:
            raise HTTPException(403, f"This team has used all {org['seat_cap']} seats.")

        token = "obs_" + secrets.token_urlsafe(32)
        install_id = str(uuid.uuid4())
        conn.execute(
            "INSERT INTO installs (id, org_id, email, name, device_name, token_hash, created_at)"
            " VALUES (%s,%s,%s,%s,%s,%s,%s)",
            (install_id, org["id"], email, body.name or email.split("@")[0],
             body.device_name, sha256(token), now()),
        )
        return EnrollResponse(
            install_token=token,
            org_name=org["name"],
            author_email=email,
            author_name=body.name or email.split("@")[0],
        )


# ── authentication ───────────────────────────────────────────────────────────

def current_install(authorization: str = Header(default="")) -> dict[str, Any]:
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "Missing install token.")
    token = authorization[7:]
    with db.connect() as conn:
        row = conn.execute(
            "SELECT * FROM installs WHERE token_hash = %s AND revoked_at IS NULL",
            (sha256(token),),
        ).fetchone()
        if row is None:
            raise HTTPException(401, "This install token is not valid. Re-enrol in Settings.")
        conn.execute("UPDATE installs SET last_seen_at = %s WHERE id = %s", (now(), row["id"]))
        return dict(row)


# ── sharing ──────────────────────────────────────────────────────────────────

class SOPStep(BaseModel):
    order: int
    action: str
    detail: str
    location: str | None = None


class SharePayload(BaseModel):
    idempotency_key: str
    title: str
    summary: str = ""
    trigger: str | None = None
    sop_steps: list[SOPStep] = Field(default_factory=list)
    automation: dict[str, Any] | None = None
    locations: list[str] = Field(default_factory=list)


@app.post("/v1/workflows", status_code=201)
def share(body: SharePayload, response: Response,
          install: dict[str, Any] = Depends(current_install)) -> dict[str, str]:
    """Upsert on (org_id, idempotency_key) so a retry after a dropped
    connection cannot create a second copy."""
    with db.connect() as conn:
        fields = (
            body.title,
            body.summary,
            body.trigger,
            json.dumps([s.model_dump() for s in body.sop_steps]),
            json.dumps(body.automation) if body.automation else None,
            json.dumps(body.locations),
            now(),
        )
        # One statement, so two retries racing each other cannot both decide
        # the row is missing and both insert it. Author and install are left
        # alone on conflict: attribution belongs to whoever shared it first.
        # `xmax = 0` is true only for a row this statement inserted, which is
        # how we tell 201-created from 200-updated.
        row = conn.execute(
            "INSERT INTO workflows (id, org_id, install_id, author_email, author_name,"
            " idempotency_key, title, summary, trigger_pattern, sop_json, automation_json,"
            " locations_json, shared_at, updated_at)"
            " VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)"
            " ON CONFLICT (org_id, idempotency_key) DO UPDATE SET"
            "   title = EXCLUDED.title, summary = EXCLUDED.summary,"
            "   trigger_pattern = EXCLUDED.trigger_pattern, sop_json = EXCLUDED.sop_json,"
            "   automation_json = EXCLUDED.automation_json,"
            "   locations_json = EXCLUDED.locations_json,"
            "   updated_at = EXCLUDED.updated_at, retracted_at = NULL"
            " RETURNING id, (xmax = 0) AS created",
            (str(uuid.uuid4()), install["org_id"], install["id"], install["email"],
             install["name"], body.idempotency_key, *fields[:6], now(), fields[6]),
        ).fetchone()
        if not row["created"]:
            response.status_code = 200
            return {"id": row["id"], "status": "updated"}
        return {"id": row["id"], "status": "shared"}


@app.delete("/v1/workflows/{key}")
def retract(key: str, install: dict[str, Any] = Depends(current_install)) -> dict[str, str]:
    """Retraction hides the row from every view, the admin's included."""
    with db.connect() as conn:
        cur = conn.execute(
            "UPDATE workflows SET retracted_at = %s WHERE org_id = %s AND idempotency_key = %s"
            " AND retracted_at IS NULL",
            (now(), install["org_id"], key),
        )
        if cur.rowcount == 0:
            raise HTTPException(404, "No shared workflow with that key.")
    return {"status": "retracted"}


@app.get("/v1/workflows/mine")
def mine(install: dict[str, Any] = Depends(current_install)) -> dict[str, Any]:
    with db.connect() as conn:
        rows = conn.execute(
            "SELECT idempotency_key, title, shared_at, updated_at FROM workflows"
            " WHERE org_id = %s AND author_email = %s AND retracted_at IS NULL"
            " ORDER BY shared_at DESC",
            (install["org_id"], install["email"]),
        ).fetchall()
    return {"workflows": [dict(r) for r in rows]}


# ── admin ────────────────────────────────────────────────────────────────────
#
# An admin uses a browser, not the desktop app, so this is a separate mechanism
# from install tokens. Magic link: the address must be on the org's domain.

STYLE = """
 body{font:16px/1.6 -apple-system,system-ui,sans-serif;max-width:60rem;margin:3rem auto;
 padding:0 1.5rem;background:#F4F8F6;color:#1C2926}
 h1{font-family:ui-serif,Georgia,serif;font-weight:500;margin-bottom:.2rem}
 p{margin:.4rem 0 1.4rem}
 .quiet{color:#7C918C}
 table{border-collapse:collapse;width:100%;background:#fff;border:1px solid #CFDED7;
 border-radius:8px;overflow:hidden}
 th{text-align:left;font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;
 color:#7C918C;padding:.7rem .9rem;border-bottom:1px solid #CFDED7}
 td{padding:.7rem .9rem;border-bottom:1px solid #E2ECE7;vertical-align:top}
 small{color:#7C918C}
 label{display:block;font-size:.8rem;color:#4A5C58;margin-bottom:.35rem}
 input{width:100%;max-width:22rem;font:inherit;padding:.6rem .75rem;border-radius:8px;
 border:1px solid #CFDED7;background:#fff;color:#1C2926}
 input:focus{outline:2px solid #6BA88F;outline-offset:1px;border-color:#6BA88F}
 button{font:inherit;margin-top:.9rem;padding:.6rem 1.1rem;border:0;border-radius:8px;
 background:#2E6152;color:#fff;cursor:pointer}
 button:hover{background:#24493E}
 form{margin:1.4rem 0}
"""


def esc(v: object) -> str:
    return html.escape(str(v))


def page(title: str, body: str, status: int = 200) -> HTMLResponse:
    """Every browser-facing response goes through here, so the landing page, the
    workflow table and an error all look like one product rather than three."""
    return HTMLResponse(
        f"<!doctype html><meta charset=utf-8>\n<title>{esc(title)}</title>\n"
        f"<style>{STYLE}</style>\n{body}", status_code=status)


def sign(value: str) -> str:
    mac = hmac.new(SECRET.encode(), value.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{value}.{mac}"


def unsign(signed: str) -> str | None:
    value, _, mac = signed.rpartition(".")
    if not value or not hmac.compare_digest(sign(value), signed):
        return None
    return value


def send_login_link(to: str, link: str, org_name: str) -> None:
    """Resend when it is configured, the log when it is not.

    A send failure is swallowed on purpose. The response to a sign-in request
    must not differ between an address we can reach and one we cannot, or the
    form becomes a way to ask which companies are customers.
    """
    key, sender = os.environ.get("RESEND_API_KEY"), os.environ.get("EMAIL_FROM")
    if not (key and sender):
        print(f"[admin login] {to} -> {link}", flush=True)
        return
    body = json.dumps({
        "from": sender,
        "to": [to],
        "subject": f"Sign in to {org_name} on DeskMate",
        "html": (f"<p>Here is your sign-in link for <b>{esc(org_name)}</b>.</p>"
                 f'<p><a href="{esc(link)}">See what your team has shared</a></p>'
                 "<p>If you did not ask for this, nothing has happened — ignore it.</p>"),
    }).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(
            "https://api.resend.com/emails", data=body,
            headers={"Authorization": f"Bearer {key}",
                     "Content-Type": "application/json"}), timeout=10).read()
    except Exception as exc:
        print(f"[admin login] could not send to {to}: {exc}", flush=True)


# Identical whether or not the domain belongs to a customer. Saying "no such
# team" here would turn the form into a customer list.
SENT = ("<h1>Check your email</h1>"
        "<p>If that address belongs to a team on DeskMate, a sign-in link "
        "is on its way. The link opens your team's shared workflows.</p>"
        '<p class=quiet><a href="/">Use a different address</a></p>')


@app.post("/admin/login", response_class=HTMLResponse)
def admin_login(request: Request, email: str = Form(...)) -> HTMLResponse:
    email = email.strip().lower()
    with db.connect() as conn:
        rate_limit(conn, f"login:{request.client.host if request.client else '?'}",
                   what="sign-in requests")
        org = conn.execute("SELECT * FROM orgs WHERE email_domain = %s",
                           (email.rpartition("@")[2],)).fetchone()
    if org is not None:
        send_login_link(email, f"{request.base_url}admin?t={sign(org['id'])}", org["name"])
    return page("Check your email", SENT)


@app.get("/admin", response_class=HTMLResponse)
def admin(t: str = "") -> HTMLResponse:
    org_id = unsign(t) if t else None
    if not org_id:
        return page("Sign in", "<h1>Sign in</h1><p class=quiet>This sign-in link is not "
                    "valid. Ask whoever set your team up for a new one.</p>", 401)
    with db.connect() as conn:
        org = conn.execute("SELECT * FROM orgs WHERE id = %s", (org_id,)).fetchone()
        rows = conn.execute(
            "SELECT title, author_name, author_email, shared_at, locations_json"
            " FROM workflows WHERE org_id = %s AND retracted_at IS NULL"
            " ORDER BY shared_at DESC",
            (org_id,),
        ).fetchall()

    # Titles and author names arrive from the desktop client and are written by
    # a model reading someone's screen. None of it is trustworthy markup, and an
    # admin is exactly the person you would target with it.
    items = "".join(
        f"<tr><td>{esc(r['title'])}</td>"
        f"<td>{esc(r['author_name'])}<br><small>{esc(r['author_email'])}</small></td>"
        f"<td>{esc(', '.join(json.loads(r['locations_json'])))}</td>"
        f"<td>{esc(r['shared_at'][:10])}</td></tr>"
        for r in rows
    ) or "<tr><td colspan=4>Nobody has shared a workflow yet.</td></tr>"

    return page(f"{org['name']} — shared workflows", f"""
<h1>{esc(org['name'])}</h1>
<p>Workflows people on your team chose to share.</p>
<table><tr><th>Workflow</th><th>Shared by</th><th>Apps</th><th>When</th></tr>{items}</table>""")


@app.get("/", response_class=HTMLResponse)
def signin() -> HTMLResponse:
    """Sign-in is a link sent to the address, not the address itself.

    Matching an email domain proves nothing — anyone can type a company's
    domain. The link is what proves the person actually holds an address there,
    and it is the only way into a team's workflows.
    """
    return page("Sign in — DeskMate", """
<h1>DeskMate</h1>
<p>See the workflows your team has chosen to share.</p>
<form method=post action="/admin/login">
  <label for=email>Work email</label>
  <input id=email name=email type=email required autocomplete=email
         placeholder="you@yourcompany.com" autofocus>
  <button type=submit>Email me a sign-in link</button>
</form>
<p class=quiet>We email you a link rather than asking for a password. Only
addresses at a team's own domain can open that team's workflows.</p>
<p class=quiet>Everyone runs DeskMate on their own Mac, and what they see
stays there. This holds only the procedures they explicitly chose to share.</p>""")


@app.exception_handler(404)
async def not_found(request: Request, exc: Exception) -> Response:
    """The desktop client parses JSON and a browser does not, so the two get
    different bodies for the same 404."""
    detail = getattr(exc, "detail", "Not Found")
    if request.url.path.startswith("/v1/"):
        return JSONResponse({"detail": detail}, status_code=404)
    return page("Not found",
                "<h1>Not found</h1><p class=quiet>There is no page at this address.</p>", 404)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}

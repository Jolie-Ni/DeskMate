# DeskMate hub

The shared half of DeskMate. Employees keep everything locally; when
someone explicitly shares a workflow, its title, SOP and automation plan land
here, where their team admin can read them. Captures, screenshots and OCR text
never reach this service — see `SharePayload` on the client for the exact wire
format.

FastAPI over Postgres. Plain SQL, no ORM, four tables.

## Running it locally

```sh
./devdb.sh                                  # Postgres in Docker on :55432
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt

export DESKMATE_DB_URL=postgresql://postgres:postgres@localhost:55432/deskmate_dev
.venv/bin/python manage.py init             # apply schema.sql
.venv/bin/python manage.py create "Acme Research" acme.test 5
.venv/bin/python -m uvicorn app:app --port 8788
```

`manage.py create` prints the enrolment code once. It is stored only as a
hash, so a lost code is rotated, never recovered.

Point the desktop app at it with `DESKMATE_HUB_URL=http://localhost:8788`, and
`DESKMATE_STORAGE_DIR=/some/scratch` if you would rather not enrol the database
you actually use.

## Tests

```sh
./devdb.sh
.venv/bin/python test_server.py
```

They run against a real Postgres rather than a stand-in — production is
Postgres, and a suite that passes on a different engine is the one that lets
dialect bugs through. The suite drops and recreates the schema on every run, so
it refuses to start unless `DESKMATE_DB_URL` names a database ending in
`_test`.

## Signing in

`/` is a sign-in page. Someone types a work email; if the domain belongs to an
onboarded org, a signed link is emailed to them; the link opens that org's
shared workflows.

The link, not the address, is the credential. Matching a domain proves nothing
— anyone can type a company's domain — so a form that let you straight in would
mean any stranger could read a customer's shared workflows. The response is
also identical whether or not the domain is a customer, otherwise the form
doubles as a customer list.

Links do not expire (see Known gaps). `DESKMATE_SECRET` signs them, which is
why it has to be set before any org exists.

### Getting an admin their link

Mint it yourself — no need to wait for them to use the form:

```sh
vercel env pull .env.production.local          # once; gitignored

.venv/bin/python envrun.py .env.production.local \
  DESKMATE_DB_URL=DATABASE_URL,DESKMATE_SECRET=DESKMATE_SECRET \
  .venv/bin/python manage.py link theirco.com
```

`manage.py create` prints the same link, so onboarding hands over two things:
the enrolment code for the team, and the admin link for whoever runs it.

Both refuse to run if `DESKMATE_SECRET` is unset or still the dev default — a
link signed with that would not open the deployed hub, and if the hub were
using it, anyone could mint one.

The sign-in form works too; without `RESEND_API_KEY` its link goes to the
function log rather than an inbox:

```sh
vercel logs deskmate-hub.vercel.app --json > /tmp/logs.json   # ^C after a few seconds
grep -o 'admin?t=[A-Za-z0-9._-]*' /tmp/logs.json | tail -1
```

`.env.production.local` holds the production database password and the signing
secret in plaintext. It is gitignored; keep it that way.

## Deploying to Vercel

Zero config. Vercel detects FastAPI, finds the `app` in `app.py`, and routes
every path to it — there is no `vercel.json` and no `api/` entrypoint, and
adding either makes it worse. The first attempt here did add both, and a
hand-written `rewrites` rule overwrote the path before FastAPI saw it, so every
route 404'd while looking like the app was down.

Deploys are run from this directory, which makes it the project root:

```sh
cd server
vercel link --yes --project deskmate-hub
vercel deploy --prod
curl https://<deployment>/healthz            # {"status":"ok"}
```

`/healthz` is the check that matters: no database, no token, so an `ok` means
the app itself is up and routing is right.

If you connect the Git repo later, set the project's **Root Directory** to
`server` — that setting is what CLI deploys get for free by running from here.

### Environment

| Variable | Notes |
|---|---|
| `DATABASE_URL` | Injected by Vercel's Neon integration, already pooled. `db.py` reads it directly, so the connection string is never copied by hand. |
| `DESKMATE_DB_URL` | Overrides `DATABASE_URL`. Used for local development and for pointing `manage.py` at production. |
| `DESKMATE_SECRET` | Signs admin sign-in links. **Set this before creating any org** — the default is a public dev value, and anyone who knows it can forge a sign-in link. |
| `RESEND_API_KEY` | Sends the sign-in email. Without it, links are printed to the function log instead — workable for one customer you onboarded yourself, and nothing more. |
| `EMAIL_FROM` | Sender address, on a domain verified with Resend. Both this and the key must be set before any email is sent. |

Set the secret without it passing through a shell history or a transcript:

```sh
python3 -c "import secrets;print(secrets.token_urlsafe(32))" | vercel env add DESKMATE_SECRET production
```

### Running commands against production

Connection strings contain `&` and `?`, so `. .env` fails in zsh and, worse,
half-succeeds in bash. `envrun.py` reads the file directly and hands the value
to the child process, so no shell ever sees the credential:

```sh
# schema changes and other DDL want the UNPOOLED url — a transaction pooler
# does not reliably accept a multi-statement script
.venv/bin/python envrun.py ../.env DESKMATE_DB_URL=DATABASE_URL_UNPOOLED \
  .venv/bin/python manage.py init

# everything else can use the pooled one
.venv/bin/python envrun.py ../.env DESKMATE_DB_URL=DATABASE_URL \
  .venv/bin/python manage.py create "Their Co" theirco.com 10
```

`../.env` comes from `vercel env pull` and holds the production database
password in plaintext. It is gitignored; keep it that way.

### The desktop client

`Config.hubURL` is `https://deskmate-hub.vercel.app`. As of the DeskMate
rebrand this host does **not** resolve yet — the Vercel project is still named
`local-observer-hub`, and until it is renamed the Team tab fails. Rename the
project in Vercel (Settings → General → Project Name) to make the constant
true; until then run against the old host with
`DESKMATE_HUB_URL=https://local-observer-hub.vercel.app`.

A default that does not resolve fails as "a server with this host name can't be
found", which reads like a network problem rather than a wrong constant — so
close this gap rather than living with it.

If you register a real domain later, add it in the Vercel project and change
that one line. `DESKMATE_HUB_URL` overrides it per run.

### Two things worth knowing about Vercel here

- **Hobby is not licensed for commercial use.** If this is sold to companies,
  the project belongs on Pro.
- **Cold starts don't matter for this app.** Every client call is queued and
  retryable, so nobody waits on one.

## Known gaps

- **Admin sign-in links do not expire.** `sign()`/`unsign()` carry no
  timestamp, so a link stays valid forever. Accepted for now — revisit when
  there are customers who did not set this up themselves.
- **No email delivery until `RESEND_API_KEY` and `EMAIL_FROM` are set.** The
  sign-in page works, but the link goes to `vercel logs` rather than an inbox,
  so nobody can sign in without you fetching it for them.
- **`current_install` opens its own connection**, so an authenticated request
  makes two. Harmless at this size; worth a request-scoped connection if the
  hub ever gets busy.

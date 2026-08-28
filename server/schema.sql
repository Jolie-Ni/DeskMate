-- Three tables. See the design brief for why there is no `members` table:
-- at ten people, grouping installs by email is enough, and copying the author
-- onto each workflow means a departing employee needs no lifecycle handling.

CREATE TABLE IF NOT EXISTS orgs (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    email_domain  TEXT NOT NULL,          -- only addresses here may enrol
    code_hash     TEXT NOT NULL,          -- sha256 of the enrolment code
    seat_cap      INTEGER NOT NULL DEFAULT 10,
    created_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS installs (
    id            TEXT PRIMARY KEY,
    org_id        TEXT NOT NULL REFERENCES orgs(id),
    email         TEXT NOT NULL,
    name          TEXT NOT NULL,
    device_name   TEXT NOT NULL,
    token_hash    TEXT NOT NULL UNIQUE,   -- sha256; the plaintext lives only on the client
    created_at    TEXT NOT NULL,
    last_seen_at  TEXT,
    revoked_at    TEXT
);
CREATE INDEX IF NOT EXISTS installs_by_token ON installs(token_hash);
CREATE INDEX IF NOT EXISTS installs_by_org   ON installs(org_id);

CREATE TABLE IF NOT EXISTS workflows (
    id               TEXT PRIMARY KEY,
    org_id           TEXT NOT NULL REFERENCES orgs(id),
    install_id       TEXT NOT NULL REFERENCES installs(id),
    -- Denormalised on purpose: a workflow keeps its author after the person
    -- leaves, with no member record to maintain.
    author_email     TEXT NOT NULL,
    author_name      TEXT NOT NULL,
    idempotency_key  TEXT NOT NULL,
    title            TEXT NOT NULL,
    summary          TEXT NOT NULL DEFAULT '',
    trigger_pattern  TEXT,
    sop_json         TEXT NOT NULL DEFAULT '[]',
    automation_json  TEXT,
    locations_json   TEXT NOT NULL DEFAULT '[]',
    shared_at        TEXT NOT NULL,
    updated_at       TEXT NOT NULL,
    retracted_at     TEXT,
    UNIQUE (org_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS workflows_by_org ON workflows(org_id, retracted_at);

-- Enrolment attempts, for rate limiting.
--
-- This has to be shared state. The process serving the next request is often
-- not the one that served the last, so an in-memory counter protects nothing —
-- an attacker parallelising requests just gets a fresh budget per instance.
-- That matters here specifically: the enrolment code is short enough to type,
-- which means short enough to guess.
CREATE TABLE IF NOT EXISTS enrol_attempts (
    bucket        TEXT NOT NULL,   -- 'code:OBS-…' or a client address
    attempted_at  TEXT NOT NULL    -- ISO-8601 UTC, fixed width: compares as text
);
CREATE INDEX IF NOT EXISTS enrol_attempts_by_bucket
    ON enrol_attempts(bucket, attempted_at);

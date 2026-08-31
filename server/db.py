"""Postgres access. Plain SQL, no ORM — the schema is four small tables, and
staying close to it keeps this file the only thing that knows about the driver.

Every request opens and closes its own connection. That is the right shape for
serverless: a process can be frozen between requests, and a connection held
across that boundary is a leaked backend slot. Point DESKMATE_DB_URL at a
*pooled* endpoint (on Neon, the host with `-pooler` in it) so a burst of cold
starts cannot exhaust Postgres' connection limit.
"""
import os
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

# `DATABASE_URL` is what Vercel's Neon integration injects, and it is already
# the pooled endpoint. Reading it directly means the connection string is never
# copied by hand — the one place a production password would otherwise get
# pasted, logged, or committed.
DB_URL = (os.environ.get("DESKMATE_DB_URL")
          or os.environ.get("DATABASE_URL")
          or "postgresql://localhost/deskmate_hub")


def connect() -> psycopg.Connection:
    """Commits on a clean exit, rolls back on an exception, closes either way."""
    return psycopg.connect(DB_URL, row_factory=dict_row)


def init() -> None:
    """Applies schema.sql.

    Deliberately not run on startup: on serverless that fires concurrent DDL on
    every cold start. It is a deploy step — `python manage.py init`.
    """
    schema = (Path(__file__).parent / "schema.sql").read_text()
    with connect() as conn:
        conn.execute(schema)

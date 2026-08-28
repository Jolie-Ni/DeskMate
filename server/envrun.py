#!/usr/bin/env python3
"""Run a command with variables from a .env file, without a shell touching it.

Connection strings carry `&` and `?`, which a shell will happily interpret if
the file is sourced. Reading it here keeps the credential out of the shell
entirely — it goes straight from the file into the child process.
"""
import os
import subprocess
import sys
from pathlib import Path

env_path, mapping, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
values = {}
for line in Path(env_path).read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, _, v = line.partition("=")
    v = v.strip()
    # dotenv quoting: a double-quoted value carries escapes, a single-quoted one
    # is literal. Getting this wrong is silent — you sign with `\n` where the
    # server signed with a newline, and every signature simply fails to verify.
    if len(v) >= 2 and v[0] == v[-1] == '"':
        v = (v[1:-1].replace("\\n", "\n").replace("\\r", "\r")
             .replace("\\t", "\t").replace('\\"', '"').replace("\\\\", "\\"))
    elif len(v) >= 2 and v[0] == v[-1] == "'":
        v = v[1:-1]
    values[k.strip()] = v

env = os.environ.copy()
for pair in mapping.split(","):           # e.g. OBSERVER_DB_URL=DATABASE_URL
    dest, _, src = pair.partition("=")
    if src not in values:
        sys.exit(f"{src} is not in {env_path}")
    env[dest] = values[src]

sys.exit(subprocess.call(cmd, env=env))

#!/usr/bin/env python3
"""
newsletter_voice.py - turn the daily brief into an audio version saved to Google Drive.

Install:  pip install openai
Env:      OPENAI_API_KEY   (required)
          BRIEF_DIR        (optional) path to your synced top_of_your_mind folder

Usage:    python newsletter_voice.py brief.html              # full issue
          python newsletter_voice.py brief.html --highlights # ~4 min version
          python newsletter_voice.py --latest                # newest brief in Drive

Writes:   <BRIEF_DIR>/audio/newsletter-YYYY-MM-DD.mp3
"""

import os
import re
import sys
import html as htmllib
import datetime
import pathlib

from openai import OpenAI

VOICE = "alloy"
MODEL = "gpt-4o-mini-tts"   # 'instructions' only works on this model, NOT tts-1
CHUNK = 3500                # hard cap; the API rejects input over 4096 chars
WPM = 150

# Your Drive-synced notes folder. Same folder the brief and activity files live in.
# Override with:  export BRIEF_DIR="/Users/you/Library/CloudStorage/GoogleDrive-.../top_of_your_mind"
DEFAULT_BRIEF_DIR = pathlib.Path.home() / "Google Drive" / "My Drive" / "top_of_your_mind"


def brief_dir() -> pathlib.Path:
    d = pathlib.Path(os.environ.get("BRIEF_DIR", DEFAULT_BRIEF_DIR)).expanduser()
    if not d.is_dir():
        sys.exit(
            f"Drive folder not found: {d}\n"
            "Set BRIEF_DIR to your synced top_of_your_mind folder, e.g.\n"
            '  export BRIEF_DIR="$HOME/Library/CloudStorage/'
            'GoogleDrive-jolieni@hconsult.ai/My Drive/top_of_your_mind"'
        )
    return d


# ---------------------------------------------------------------- cleaning

def clean(text: str) -> str:
    """Handle HTML and Markdown. Produces speakable plain text."""
    looks_like_html = bool(re.search(r"<(p|div|h[1-6]|br|table)\b", text, re.I))

    if looks_like_html:
        text = re.sub(r"(?is)<(script|style|head)\b.*?</\1>", "", text)
        text = re.sub(r"(?is)<!--.*?-->", "", text)
        text = re.sub(r"(?is)<a\b[^>]*>(.*?)</a>", r"\1", text)   # keep label, drop URL
        text = re.sub(r"(?i)</(p|div|h[1-6]|li|tr|table|blockquote)>", "\n\n", text)
        text = re.sub(r"(?i)<(br|hr)\s*/?>", "\n", text)
        text = re.sub(r"(?s)<[^>]+>", "", text)
        text = htmllib.unescape(text)
    else:
        text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
        text = re.sub(r"^\s{0,3}#{1,6}\s*", "", text, flags=re.M)
        text = re.sub(r"[*_`>]", "", text)

    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"\bwww\.\S+", "", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n[ \t]+", "\n", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def highlights(text: str, keep: int = 6) -> str:
    paras = [p for p in text.split("\n\n") if len(p.split()) > 12]
    return "\n\n".join(paras[:keep])


# ---------------------------------------------------------------- chunking

def chunks(text: str, size: int = CHUNK):
    """Paragraphs, then sentences, then hard cut. Never exceeds size."""
    def hard_split(s):
        while len(s) > size:
            cut = s.rfind(" ", 0, size)
            cut = cut if cut > size // 2 else size
            yield s[:cut]
            s = s[cut:].lstrip()
        if s:
            yield s

    def units(t):
        for para in t.split("\n\n"):
            para = para.strip()
            if not para:
                continue
            if len(para) <= size:
                yield para
                continue
            cur = ""
            for s in re.split(r"(?<=[.!?])\s+", para):
                if len(cur) + len(s) + 1 > size and cur:
                    yield cur.strip()
                    cur = ""
                if len(s) > size:
                    if cur:
                        yield cur.strip()
                        cur = ""
                    yield from hard_split(s)
                else:
                    cur += s + " "
            if cur.strip():
                yield cur.strip()

    buf = ""
    for u in units(text):
        if buf and len(buf) + len(u) + 2 > size:
            yield buf.strip()
            buf = ""
        buf += u + "\n\n"
    if buf.strip():
        yield buf.strip()


# ---------------------------------------------------------------- synthesis

def _strip_id3(data: bytes) -> bytes:
    """Drop a leading ID3v2 tag so concatenated MP3s decode without errors."""
    if data[:3] == b"ID3":
        sz = data[6] << 21 | data[7] << 14 | data[8] << 7 | data[9]
        return data[10 + sz:]
    return data


def synthesize(text: str, path: pathlib.Path) -> pathlib.Path:
    if not os.environ.get("OPENAI_API_KEY"):
        sys.exit("OPENAI_API_KEY is not set.")
    client = OpenAI()
    parts = list(chunks(text))
    tmp = path.with_suffix(".part")          # write aside so Drive never syncs a half file
    with open(tmp, "wb") as f:
        for i, part in enumerate(parts):
            print(f"  chunk {i+1}/{len(parts)} ({len(part)} chars)", flush=True)
            resp = client.audio.speech.create(
                model=MODEL,
                voice=VOICE,
                input=part,
                instructions="Read like a warm, brisk morning-briefing host. "
                             "Natural pacing, short pauses between stories.",
                response_format="mp3",
            )
            audio = resp.content
            f.write(audio if i == 0 else _strip_id3(audio))
    tmp.replace(path)                        # atomic; Drive sees one complete file
    return path


# ---------------------------------------------------------------- input

def newest_brief(root: pathlib.Path) -> pathlib.Path:
    """Most recent YYYY-MM-DD-brief.* by FILENAME date, never mtime."""
    pat = re.compile(r"(\d{4}-\d{2}-\d{2})-brief\.(html|md|txt)$", re.I)
    found = [(pat.search(p.name).group(1), p)
             for p in root.rglob("*") if p.is_file() and pat.search(p.name)]
    if not found:
        sys.exit(f"No YYYY-MM-DD-brief.(html|md|txt) found under {root}")
    return max(found)[1]


def main():
    argv = sys.argv[1:]
    short = "--highlights" in argv
    latest = "--latest" in argv
    files = [a for a in argv if not a.startswith("-")]

    root = brief_dir()
    if latest or not files:
        src = newest_brief(root)
        print(f"reading {src.name}")
    else:
        src = pathlib.Path(files[0])

    text = clean(src.read_text(encoding="utf-8"))
    if short:
        text = highlights(text)

    out_dir = root / "audio"
    out_dir.mkdir(exist_ok=True)

    m = re.search(r"(\d{4}-\d{2}-\d{2})", src.name)
    day = m.group(1) if m else datetime.date.today().isoformat()
    mp3 = out_dir / f"newsletter-{day}{'-highlights' if short else ''}.mp3"

    minutes = max(1, round(len(text.split()) / WPM))
    print(f"{len(text)} chars, ~{minutes} min of audio")
    synthesize(text, mp3)
    print(f"saved: {mp3}")
    print("It will appear in Drive, and in the Drive app on your phone, once sync catches up.")


if __name__ == "__main__":
    main()
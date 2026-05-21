#!/usr/bin/env python3
"""Daily scrape of r/Rivian — last 24h of new posts.

Uses Reddit's public JSON endpoint (no auth needed for read-only). The
unauthenticated rate limit (~60 req/min) is plenty for a once-a-day
fetch of /new.json?limit=100. Moving to PRAW + a client_id would unlock
higher limits and the search API; tracked as a follow-up if the daily
cadence ever needs to widen.

Usage:
    python3 scrape_reddit.py <output.json>

The output file is a JSON array of slim post records — exactly what
the downstream `summarize` agent task reads as its context.
"""

from __future__ import annotations

import json
import sys
import time
from typing import Any

import requests

# User-Agent is the only thing Reddit's public endpoint actually
# enforces — anonymous calls with no UA get 429'd within a few requests.
# Stable, identifiable UA per their API guidelines.
USER_AGENT = "cronicle-rivian-monitor/1.0 (run via cronicle.io)"
SUBREDDIT = "Rivian"
LIMIT = 100  # max per call without pagination
WINDOW_SECONDS = 24 * 3600


def fetch_new_posts() -> list[dict[str, Any]]:
    """Pull the newest LIMIT posts from /r/<SUBREDDIT>/new.json.

    Single roundtrip, 30s timeout. We don't paginate because the 24h
    window almost always fits in 100 posts for a sub of this size; on
    the day it doesn't, the oldest entries silently fall off the
    bottom — acceptable.
    """
    url = f"https://www.reddit.com/r/{SUBREDDIT}/new.json"
    resp = requests.get(
        url,
        params={"limit": LIMIT},
        headers={"User-Agent": USER_AGENT},
        timeout=30,
    )
    resp.raise_for_status()
    children = resp.json()["data"]["children"]
    return [c["data"] for c in children]


def filter_last_24h(posts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    cutoff = time.time() - WINDOW_SECONDS
    return [p for p in posts if (p.get("created_utc") or 0) >= cutoff]


def to_slim_record(p: dict[str, Any]) -> dict[str, Any]:
    """Trim the Reddit blob to just what the summarizer needs.

    The full /new.json payload carries ~70 fields per post including
    awards, modlog hints, gallery media URLs, etc. — none of which the
    agent uses. Keeping the JSON minimal keeps the agent's input
    window small and the summary tight.
    """
    return {
        "id": p.get("id"),
        "title": p.get("title"),
        # selftext can be long (e.g. detailed bug reports); cap at
        # 2000 chars to bound the agent's input. Truncated entries are
        # still useful — the permalink lets the agent or a reader
        # follow up for the full text.
        "selftext": (p.get("selftext") or "")[:2000],
        "score": p.get("score"),
        "num_comments": p.get("num_comments"),
        "permalink": f"https://reddit.com{p.get('permalink', '')}",
        "created_utc": p.get("created_utc"),
        "author": p.get("author"),
        "link_flair_text": p.get("link_flair_text"),
    }


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: scrape_reddit.py <output.json>", file=sys.stderr)
        return 2
    out_path = sys.argv[1]

    posts = fetch_new_posts()
    recent = filter_last_24h(posts)
    slim = [to_slim_record(p) for p in recent]

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(slim, f, indent=2, ensure_ascii=False)
    print(f"wrote {len(slim)} posts (of {len(posts)} fetched) → {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

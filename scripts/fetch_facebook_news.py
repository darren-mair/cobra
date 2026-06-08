#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen


GRAPH_BASE = "https://graph.facebook.com/v23.0"
DEFAULT_OUTPUT_DIR = "content/news"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def slugify(text: str) -> str:
    text = (text or "").lower().strip()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    text = re.sub(r"-+", "-", text).strip("-")
    return text or "post"


def toml_escape(text: str) -> str:
    return (text or "").replace("\\", "\\\\").replace('"', '\\"')


def read_json_url(url: str, params: dict) -> dict:
    query = urlencode(params)
    with urlopen(f"{url}?{query}", timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def resolve_page_id(page_ref: str, token: str) -> str:
    data = read_json_url(
        f"{GRAPH_BASE}/{page_ref}",
        {
            "fields": "id",
            "access_token": token,
        },
    )
    return str(data.get("id", "")).strip()


def fetch_posts(page_id: str, token: str, max_posts: int) -> list:
    posts = []
    next_url = f"{GRAPH_BASE}/{page_id}/posts"
    params = {
        "fields": "id,created_time,message,permalink_url,full_picture",
        "limit": min(max_posts, 100),
        "access_token": token,
    }

    while next_url and len(posts) < max_posts:
        if params is None:
            with urlopen(next_url, timeout=30) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        else:
            payload = read_json_url(next_url, params)

        page_data = payload.get("data", [])
        posts.extend(page_data)

        paging = payload.get("paging", {})
        next_url = paging.get("next")
        params = None

    return posts[:max_posts]


def parse_fb_datetime(value: str) -> datetime:
    # Example: 2026-06-07T19:39:01+0000
    if not value:
        return now_utc()
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return now_utc()


def post_title(message: str, fallback_id: str) -> str:
    line = (message or "").strip().splitlines()
    if line and line[0].strip():
        raw = line[0].strip()
    else:
        raw = f"Facebook update {fallback_id}"
    return raw[:90]


def write_hugo_post(output_dir: Path, post: dict) -> str:
    post_id = str(post.get("id", "")).strip() or "unknown"
    message = (post.get("message") or "").strip()
    created = parse_fb_datetime(post.get("created_time", ""))
    title = post_title(message, post_id)

    date_prefix = created.strftime("%Y-%m-%d")
    stable_id = re.sub(r"[^0-9a-zA-Z_-]", "", post_id.split("_")[-1]) or "post"
    file_name = f"{date_prefix}-facebook-{stable_id}.md"
    file_path = output_dir / file_name

    summary = message.splitlines()[0].strip() if message else "Latest update from our Facebook page."
    summary = summary[:155]
    permalink = (post.get("permalink_url") or "").strip()
    image = (post.get("full_picture") or "").strip()

    parts = [
        "+++",
        f'title = "{toml_escape(title)}"',
        f"date = {created.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f'type = "post"',
        f'tags = ["facebook"]',
        f'summary = "{toml_escape(summary)}"',
    ]

    if image:
        parts.append(f'image = "{toml_escape(image)}"')

    parts.extend(["+++", ""])

    if message:
        parts.append(message)
        parts.append("")
    else:
        parts.append("(No text content provided in this Facebook post.)")
        parts.append("")

    if permalink:
        parts.append(f"[View on Facebook]({permalink})")

    content = "\n".join(parts).rstrip() + "\n"
    file_path.write_text(content, encoding="utf-8")

    return str(file_path)


def write_status(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Facebook page posts and emit Hugo news markdown files")
    parser.add_argument("--page", default=os.getenv("FB_PAGE_USERNAME", "CobraBoxingClub"), help="Facebook page username or ID")
    parser.add_argument("--token", default=os.getenv("FB_ACCESS_TOKEN", ""), help="Facebook Graph API token")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR, help="Directory for generated Hugo news posts")
    parser.add_argument("--max-posts", type=int, default=5, help="Maximum posts to generate")
    parser.add_argument("--status-file", default="data/facebook_news_sync.json", help="Status JSON output file")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    status_path = Path(args.status_file)

    page_ref = (args.page or "").strip()
    token = (args.token or "").strip()

    if not page_ref or not token:
        write_status(
            status_path,
            {
                "ok": False,
                "reason": "missing_credentials",
                "generated": 0,
                "fetched_at": now_utc().isoformat(),
            },
        )
        print("Facebook news sync: missing FB_PAGE_USERNAME/--page or FB_ACCESS_TOKEN; skipping generation.")
        return 0

    try:
        page_id = resolve_page_id(page_ref, token)
        if not page_id:
            raise RuntimeError("page_not_resolved")
        posts = fetch_posts(page_id, token, max(1, args.max_posts))

        written = []
        for post in posts:
            written.append(write_hugo_post(output_dir, post))

        write_status(
            status_path,
            {
                "ok": True,
                "reason": "",
                "generated": len(written),
                "page": page_ref,
                "page_id": page_id,
                "files": written,
                "fetched_at": now_utc().isoformat(),
            },
        )
        print(f"Facebook news sync: wrote {len(written)} post files into {output_dir}")
        return 0
    except Exception as exc:
        write_status(
            status_path,
            {
                "ok": False,
                "reason": f"request_error:{exc.__class__.__name__}",
                "generated": 0,
                "fetched_at": now_utc().isoformat(),
            },
        )
        print(f"Facebook news sync: failed ({exc.__class__.__name__}); continuing with existing content.")
        return 0


if __name__ == "__main__":
    sys.exit(main())

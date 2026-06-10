#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
from html import unescape
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode, urljoin, urlparse
from urllib.request import Request, urlopen


GRAPH_BASE = "https://graph.facebook.com/v23.0"
DEFAULT_OUTPUT_DIR = "content/news"
DEFAULT_POSTS_FILE = "data/facebook_posts.json"
PUBLIC_FB_BASE = "https://www.facebook.com"
HTTP_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Accept-Language": "en-GB,en;q=0.9",
}


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
    req = Request(f"{url}?{query}", headers=HTTP_HEADERS)
    with urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def read_text_url(url: str) -> str:
    req = Request(url, headers=HTTP_HEADERS)
    with urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


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
        pass

    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return now_utc()


def extract_meta(html: str, key: str) -> str:
    patterns = [
        rf'<meta[^>]+property=["\']{re.escape(key)}["\'][^>]+content=["\']([^"\']*)["\']',
        rf'<meta[^>]+content=["\']([^"\']*)["\'][^>]+property=["\']{re.escape(key)}["\']',
        rf'<meta[^>]+name=["\']{re.escape(key)}["\'][^>]+content=["\']([^"\']*)["\']',
        rf'<meta[^>]+content=["\']([^"\']*)["\'][^>]+name=["\']{re.escape(key)}["\']',
    ]

    for pattern in patterns:
        match = re.search(pattern, html, flags=re.IGNORECASE)
        if match:
            return unescape(match.group(1).strip())
    return ""


def normalize_fb_url(link: str) -> str:
    link = unescape((link or "").strip())
    if not link:
        return ""

    if link.startswith("/"):
        link = urljoin(PUBLIC_FB_BASE, link)

    if link.startswith("http://"):
        link = "https://" + link[len("http://") :]

    if not link.startswith("https://"):
        return ""

    link = re.sub(r"([?&])__tn__=[^&#]+", r"\1", link)
    link = re.sub(r"([?&])refsrc=[^&#]+", r"\1", link)
    link = re.sub(r"([?&])ref=[^&#]+", r"\1", link)
    link = link.replace("?&", "?").rstrip("?&")
    return link


def normalize_page_ref(value: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return ""

    # Accept page handle/ID directly.
    if not raw.lower().startswith(("http://", "https://")):
        return raw.strip("/")

    parsed = urlparse(raw)
    host = (parsed.netloc or "").lower().replace("www.", "")
    if host not in ("facebook.com", "m.facebook.com", "mbasic.facebook.com"):
        return raw.strip("/")

    path = (parsed.path or "").strip("/")
    if not path:
        return ""

    first_segment = path.split("/")[0]
    if first_segment in {"pages", "pg", "profile.php", "story.php", "permalink.php"}:
        # Not a plain page handle URL; caller should provide handle/ID.
        return ""

    return first_segment


def extract_public_post_links(page_html: str, page_ref: str) -> list[str]:
    links = re.findall(r'href=["\']([^"\']+)["\']', page_html, flags=re.IGNORECASE)
    candidates = []

    for raw in links:
        url = normalize_fb_url(raw)
        if not url:
            continue

        is_post_like = (
            f"/{page_ref}/posts/" in url
            or "story.php?story_fbid=" in url
            or "permalink.php?story_fbid=" in url
            or "/share/p/" in url
        )
        if not is_post_like:
            continue

        if "/photo" in url or "/videos/" in url:
            continue

        candidates.append(url)

    unique = []
    seen = set()
    for url in candidates:
        if url in seen:
            continue
        seen.add(url)
        unique.append(url)
    return unique


def public_post_id(permalink: str) -> str:
    match = re.search(r"(?:posts/|story_fbid=)([0-9]+)", permalink)
    if match:
        return match.group(1)

    fallback = re.sub(r"[^0-9a-zA-Z_-]", "", permalink)
    return fallback[-20:] or str(abs(hash(permalink)))


def scrape_public_post(permalink: str) -> dict:
    html = read_text_url(permalink)

    title = extract_meta(html, "og:title")
    desc = extract_meta(html, "og:description")
    image = extract_meta(html, "og:image")
    published = extract_meta(html, "article:published_time")

    message = (desc or title or "").strip()
    if title and message and message.lower() == title.lower():
        message = title

    return {
        "id": public_post_id(permalink),
        "created_time": published,
        "message": message,
        "permalink_url": permalink,
        "full_picture": image,
    }


def fetch_posts_public(page_ref: str, max_posts: int) -> list[dict]:
    entry_points = [
        f"https://mbasic.facebook.com/{page_ref}/",
        f"https://www.facebook.com/{page_ref}/posts/",
        f"https://www.facebook.com/{page_ref}",
    ]

    links = []
    seen = set()
    for entry in entry_points:
        try:
            html = read_text_url(entry)
        except Exception:
            continue

        for link in extract_public_post_links(html, page_ref):
            if link in seen:
                continue
            seen.add(link)
            links.append(link)

        if len(links) >= max_posts:
            break

    posts = []
    for permalink in links[:max_posts]:
        try:
            posts.append(scrape_public_post(permalink))
        except Exception:
            continue

    return posts[:max_posts]


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


def normalize_post(post: dict) -> dict:
    return {
        "id": str(post.get("id", "")).strip(),
        "created_time": post.get("created_time", ""),
        "message": (post.get("message") or "").strip(),
        "permalink_url": (post.get("permalink_url") or "").strip(),
        "full_picture": (post.get("full_picture") or "").strip(),
    }


def write_posts_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Facebook page posts and emit Hugo news markdown files")
    parser.add_argument("--page", default=os.getenv("FB_PAGE_USERNAME", "CobraBoxingClub"), help="Facebook page username or ID")
    parser.add_argument("--token", default=os.getenv("FB_ACCESS_TOKEN", ""), help="Facebook Graph API token")
    parser.add_argument(
        "--public-scrape",
        action="store_true",
        help="Use public page scraping instead of Graph API token",
    )
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR, help="Directory for generated Hugo news posts")
    parser.add_argument("--max-posts", type=int, default=5, help="Maximum posts to generate")
    parser.add_argument("--status-file", default="data/facebook_news_sync.json", help="Status JSON output file")
    parser.add_argument(
        "--posts-file",
        default=DEFAULT_POSTS_FILE,
        help="Facebook posts JSON output file (for Hugo data and caching)",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    status_path = Path(args.status_file)
    posts_path = Path(args.posts_file)

    page_ref = normalize_page_ref(args.page)
    token = (args.token or "").strip()

    if not page_ref:
        posts_payload = {
            "source": "facebook",
            "ok": False,
            "reason": "missing_page",
            "mode": "",
            "page": "",
            "page_id": "",
            "generated": 0,
            "posts": [],
            "fetched_at": now_utc().isoformat(),
        }
        write_posts_json(posts_path, posts_payload)
        write_status(
            status_path,
            {
                "ok": False,
                "reason": "missing_page",
                "generated": 0,
                "fetched_at": now_utc().isoformat(),
            },
        )
        print("Facebook news sync: missing FB_PAGE_USERNAME/--page; skipping generation.")
        return 0

    try:
        mode = "graph_api"
        page_id = ""

        if args.public_scrape or not token:
            mode = "public_scrape"
            posts = fetch_posts_public(page_ref, max(1, args.max_posts))
        else:
            page_id = resolve_page_id(page_ref, token)
            if not page_id:
                raise RuntimeError("page_not_resolved")
            posts = fetch_posts(page_id, token, max(1, args.max_posts))

        if not posts:
            raise RuntimeError("no_posts_found")

        written = []
        for post in posts:
            written.append(write_hugo_post(output_dir, post))

        normalized_posts = [normalize_post(post) for post in posts]
        posts_payload = {
            "source": "facebook",
            "ok": True,
            "reason": "",
            "mode": mode,
            "page": page_ref,
            "page_id": page_id,
            "generated": len(written),
            "posts": normalized_posts,
            "fetched_at": now_utc().isoformat(),
        }
        write_posts_json(posts_path, posts_payload)

        write_status(
            status_path,
            {
                "ok": True,
                "reason": "",
                "generated": len(written),
                "mode": mode,
                "page": page_ref,
                "page_id": page_id,
                "files": written,
                "fetched_at": now_utc().isoformat(),
            },
        )
        print(f"Facebook news sync ({mode}): wrote {len(written)} post files into {output_dir}")
        return 0
    except Exception as exc:
        posts_payload = {
            "source": "facebook",
            "ok": False,
            "reason": f"request_error:{exc.__class__.__name__}",
            "mode": "",
            "page": page_ref,
            "page_id": "",
            "generated": 0,
            "posts": [],
            "fetched_at": now_utc().isoformat(),
        }
        write_posts_json(posts_path, posts_payload)
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

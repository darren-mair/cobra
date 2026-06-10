#!/usr/bin/env python3
import argparse
import base64
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen


TOKEN_URL = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token"
GRAPH_BASE = "https://graph.microsoft.com/v1.0"
DEFAULT_OUTPUT_DIR = "static/img/gallery"
DEFAULT_STATUS_FILE = "data/onedrive_gallery_sync.json"
SYNC_PREFIX = "onedrive-"
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
HTTP_HEADERS = {
    "User-Agent": "CobraGallerySync/1.0",
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def safe_name(name: str) -> str:
    name = (name or "").strip()
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", name)
    name = re.sub(r"-+", "-", name).strip("-.")
    return name or "image"


def request_json(url: str, *, headers: dict | None = None, data: bytes | None = None) -> dict:
    merged_headers = dict(HTTP_HEADERS)
    if headers:
        merged_headers.update(headers)
    req = Request(url, headers=merged_headers, data=data)
    with urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def download_file(url: str, dest: Path) -> None:
    req = Request(url, headers=HTTP_HEADERS)
    with urlopen(req, timeout=120) as resp:
        dest.write_bytes(resp.read())


def get_access_token(client_id: str, client_secret: str, refresh_token: str) -> str:
    body = urlencode(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "refresh_token": refresh_token,
            "grant_type": "refresh_token",
            "scope": "offline_access Files.Read User.Read",
        }
    ).encode("utf-8")
    payload = request_json(
        TOKEN_URL,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=body,
    )
    token = str(payload.get("access_token", "")).strip()
    if not token:
        raise RuntimeError("missing_access_token")
    return token


def share_id_from_url(share_url: str) -> str:
    encoded = base64.urlsafe_b64encode(share_url.encode("utf-8")).decode("utf-8")
    return "u!" + encoded.rstrip("=")


def list_folder_items(access_token: str, folder_share_url: str) -> list[dict]:
    share_id = share_id_from_url(folder_share_url)
    url = f"{GRAPH_BASE}/shares/{share_id}/driveItem/children?$top=200"
    payload = request_json(url, headers={"Authorization": f"Bearer {access_token}"})
    return payload.get("value", []) if isinstance(payload, dict) else []


def sync_gallery(output_dir: Path, items: list[dict]) -> list[str]:
    output_dir.mkdir(parents=True, exist_ok=True)
    written = []

    wanted_files = {}
    for item in items:
        if "file" not in item:
            continue

        original_name = str(item.get("name", "")).strip()
        ext = Path(original_name).suffix.lower()
        if ext not in ALLOWED_EXTENSIONS:
            continue

        download_url = str(item.get("@microsoft.graph.downloadUrl", "")).strip()
        if not download_url:
            continue

        base_name = safe_name(Path(original_name).stem)
        file_name = f"{SYNC_PREFIX}{base_name}{ext}"
        wanted_files[file_name] = download_url

    for file_name, download_url in wanted_files.items():
        dest = output_dir / file_name
        download_file(download_url, dest)
        written.append(str(dest))

    for existing in output_dir.iterdir():
        if existing.is_file() and existing.name.startswith(SYNC_PREFIX) and existing.name not in wanted_files:
            existing.unlink()

    return written


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync gallery images from a OneDrive folder into Hugo static assets")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR, help="Directory to store synced gallery images")
    parser.add_argument("--status-file", default=DEFAULT_STATUS_FILE, help="Status JSON output file")
    parser.add_argument("--folder-share-url", default=os.getenv("ONEDRIVE_FOLDER_SHARE_URL", ""), help="Shared OneDrive folder URL")
    parser.add_argument("--client-id", default=os.getenv("ONEDRIVE_CLIENT_ID", ""), help="Microsoft app client ID")
    parser.add_argument("--client-secret", default=os.getenv("ONEDRIVE_CLIENT_SECRET", ""), help="Microsoft app client secret")
    parser.add_argument("--refresh-token", default=os.getenv("ONEDRIVE_REFRESH_TOKEN", ""), help="Microsoft OAuth refresh token")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    status_path = Path(args.status_file)
    folder_share_url = (args.folder_share_url or "").strip()
    client_id = (args.client_id or "").strip()
    client_secret = (args.client_secret or "").strip()
    refresh_token = (args.refresh_token or "").strip()

    if not folder_share_url or not client_id or not client_secret or not refresh_token:
        write_json(
            status_path,
            {
                "ok": False,
                "reason": "missing_credentials",
                "generated": 0,
                "files": [],
                "fetched_at": now_iso(),
            },
        )
        print("OneDrive gallery sync: missing ONEDRIVE_FOLDER_SHARE_URL, ONEDRIVE_CLIENT_ID, ONEDRIVE_CLIENT_SECRET, or ONEDRIVE_REFRESH_TOKEN.")
        return 0

    try:
        access_token = get_access_token(client_id, client_secret, refresh_token)
        items = list_folder_items(access_token, folder_share_url)
        written = sync_gallery(output_dir, items)
        write_json(
            status_path,
            {
                "ok": True,
                "reason": "",
                "generated": len(written),
                "files": written,
                "fetched_at": now_iso(),
            },
        )
        print(f"OneDrive gallery sync: wrote {len(written)} image files into {output_dir}")
        return 0
    except Exception as exc:
        write_json(
            status_path,
            {
                "ok": False,
                "reason": f"request_error:{exc.__class__.__name__}:{str(exc).strip() or 'unknown'}",
                "generated": 0,
                "files": [],
                "fetched_at": now_iso(),
            },
        )
        print(f"OneDrive gallery sync: failed ({exc.__class__.__name__}: {str(exc).strip() or 'unknown'}).")
        return 0


if __name__ == "__main__":
    sys.exit(main())
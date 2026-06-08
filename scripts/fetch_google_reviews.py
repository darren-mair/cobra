#!/usr/bin/env python3
import argparse
import json
import os
import sys
from datetime import datetime, timezone
from urllib.parse import urlencode
from urllib.request import urlopen


DEFAULT_OUTPUT = "data/google_reviews.json"
PLACE_DETAILS_URL = "https://maps.googleapis.com/maps/api/place/details/json"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_payload(path: str, payload: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
        f.write("\n")


def load_existing_reviews(path: str) -> list[dict]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return []

    reviews = data.get("reviews", []) if isinstance(data, dict) else []
    if not isinstance(reviews, list):
        return []
    return [r for r in reviews if isinstance(r, dict)]


def review_key(review: dict) -> tuple:
    return (
        review.get("time") or 0,
        (review.get("author_name") or "").strip(),
        (review.get("text") or "").strip(),
    )


def merge_reviews(new_reviews: list[dict], existing_reviews: list[dict], max_reviews: int) -> list[dict]:
    deduped: dict[tuple, dict] = {}

    for review in new_reviews:
        deduped[review_key(review)] = review

    for review in existing_reviews:
        key = review_key(review)
        if key not in deduped:
            deduped[key] = review

    merged = list(deduped.values())
    merged.sort(key=lambda r: (r.get("time") or 0), reverse=True)
    return merged[:max_reviews]


def empty_payload(reason: str) -> dict:
    return {
        "source": "google_places",
        "fetched_at": now_iso(),
        "ok": False,
        "reason": reason,
        "business_name": "",
        "google_maps_url": "",
        "rating": None,
        "user_ratings_total": None,
        "reviews": [],
    }


def fetch_reviews(api_key: str, place_id: str, max_reviews: int, output_path: str) -> dict:
    params = {
        "place_id": place_id,
        "fields": "name,rating,user_ratings_total,reviews,url",
        "reviews_sort": "newest",
        "key": api_key,
    }
    url = f"{PLACE_DETAILS_URL}?{urlencode(params)}"

    with urlopen(url, timeout=30) as resp:
        raw = resp.read().decode("utf-8")
    data = json.loads(raw)

    status = data.get("status")
    if status != "OK":
        return empty_payload(f"google_api_status:{status}")

    result = data.get("result", {})
    reviews = result.get("reviews", [])

    normalized = []
    for review in reviews[:max_reviews]:
        normalized.append(
            {
                "author_name": review.get("author_name", ""),
                "author_url": review.get("author_url", ""),
                "profile_photo_url": review.get("profile_photo_url", ""),
                "rating": review.get("rating"),
                "relative_time_description": review.get("relative_time_description", ""),
                "time": review.get("time"),
                "text": review.get("text", ""),
            }
        )

    existing = load_existing_reviews(output_path)
    merged_reviews = merge_reviews(normalized, existing, max_reviews=max_reviews)

    return {
        "source": "google_places",
        "fetched_at": now_iso(),
        "ok": True,
        "reason": "",
        "business_name": result.get("name", ""),
        "google_maps_url": result.get("url", ""),
        "rating": result.get("rating"),
        "user_ratings_total": result.get("user_ratings_total"),
        "reviews": merged_reviews,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Google Place reviews into Hugo data file")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Path to output JSON file")
    parser.add_argument("--place-id", default=os.getenv("GOOGLE_PLACE_ID", ""), help="Google Place ID")
    parser.add_argument("--api-key", default=os.getenv("GOOGLE_PLACES_API_KEY", ""), help="Google Places API key")
    parser.add_argument("--max-reviews", type=int, default=20, help="Maximum number of reviews to keep")
    args = parser.parse_args()

    output = args.output
    place_id = args.place_id.strip()
    api_key = args.api_key.strip()

    if not place_id or not api_key:
        write_payload(output, empty_payload("missing_credentials"))
        print("Google reviews sync: missing GOOGLE_PLACE_ID or GOOGLE_PLACES_API_KEY; wrote empty payload.")
        return 0

    try:
        payload = fetch_reviews(
            api_key=api_key,
            place_id=place_id,
            max_reviews=max(1, args.max_reviews),
            output_path=output,
        )
    except Exception as exc:
        payload = empty_payload(f"request_error:{exc.__class__.__name__}")

    write_payload(output, payload)

    if payload.get("ok"):
        print(f"Google reviews sync: wrote {len(payload.get('reviews', []))} reviews to {output}")
    else:
        print(f"Google reviews sync: fallback payload written ({payload.get('reason')})")

    return 0


if __name__ == "__main__":
    sys.exit(main())

# cobra
Cobra Site

## Stable Commands

Use the standard Hugo commands so local and live builds use the same config and path logic.

- Local dev server:
	- `hugo server`
- Production build:
	- `hugo`

## One-Environment Workflow

Use one config for both local and live output.

- From `cobra/`:
	- `hugo server`
	- `hugo`
- From workspace root (`cobrasite/`):
	- `hugo server -s cobra`
	- `hugo -s cobra`

Avoid environment flags unless you intentionally add environment-specific overrides.

## Markdown-First Maintenance

For day-to-day updates, prefer content and data files:

- Pages: `content/`
- Homepage cards/CTA/calendar: `data/homepage.toml`, `data/class_calendar.toml`
- Carousel and feature boxes: `data/carousel/`, `data/features/`
- Images: `static/img/`

Only edit templates in `layouts/` or `themes/` when changing structure or behavior.

## Build Guardrails

CI now validates Hugo builds against:

- Hugo `0.160.1`
- Both base URLs:
	- `https://cobraboxingandfitness.com/`
	- `https://darren-mair.github.io/cobra/`

Validation workflow: `.github/workflows/hugo-validate.yml`.

## Hosting Version Alignment

Set the same Hugo version (`0.160.1`) in all hosts:

- GitHub Pages: managed in `.github/workflows/hugo-deploy.yml`
- Cloudflare Pages: set build environment variable `HUGO_VERSION=0.160.1`

## Google Reviews Automation

Google reviews are fetched at build time into `data/google_reviews.json` by:

- Script: `scripts/fetch_google_reviews.py`
- Deploy workflow: `.github/workflows/hugo-deploy.yml`
- Deploy workflow now commits refreshed `data/google_reviews.json` back to `main` so review history is persisted across builds

Required secrets/env vars:

- `GOOGLE_PLACE_ID`
- `GOOGLE_PLACES_API_KEY`

Cloudflare Pages configuration:

- Build command (recommended): `hugo`
- Optional fetch-on-build command: `python3 scripts/fetch_google_reviews.py --output data/google_reviews.json --max-reviews 20 && hugo`
- Environment variables:
	- `HUGO_VERSION=0.160.1`
	- `GOOGLE_PLACE_ID=<your_place_id>`
	- `GOOGLE_PLACES_API_KEY=<your_api_key>`

Testimonials page renders Google reviews through the shortcode in `content/testimonials.md`.

Notes:

- Google Place Details returns up to 5 reviews per request, but the script merges new results with committed `data/google_reviews.json` history.
- Persisted data in the repo allows up to `--max-reviews` (20) to render over time, including on Cloudflare's ephemeral build environment.

## Facebook Posts to News Automation

Facebook page posts can be imported into Hugo news posts at build time:

- Script: `scripts/fetch_facebook_news.py`
- Output news markdown: `content/news/`
- Sync status file: `data/facebook_news_sync.json`
- Posts cache/data file: `data/facebook_posts.json`

Modes:

- Graph API mode (requires token): use `FB_PAGE_USERNAME` and `FB_ACCESS_TOKEN`
- Public scrape mode (free, no API): pass `--public-scrape` and page handle or full page URL

Required secrets/env vars (Graph API mode only):

- `FB_PAGE_USERNAME` (for example `CobraBoxingClub` or `https://www.facebook.com/CobraBoxingClub`)
- `FB_ACCESS_TOKEN`

GitHub workflow uses these secrets in `.github/workflows/hugo-deploy.yml`.

Apify source configuration for GitHub Actions (in priority order):

- `APIFY_DATASET_ITEMS_URL`:
	- Direct dataset items endpoint (legacy mode).
	- Use only if this URL points to a stable dataset.
- `APIFY_TASK_ID` + `APIFY_TOKEN`:
	- Recommended when your Apify task creates a new unnamed dataset each run.
	- The importer reads `.../actor-tasks/{taskId}/runs/last/dataset/items`, so it always follows the latest successful run automatically.
- `APIFY_DATASET_ID` (+ optional `APIFY_TOKEN`):
	- Use a named or fixed dataset ID so the endpoint does not rotate.

If GitHub Actions misses new posts, switch from `APIFY_DATASET_ITEMS_URL` to `APIFY_TASK_ID` + `APIFY_TOKEN` or a fixed `APIFY_DATASET_ID`.

Cloudflare Pages build command should include both sync steps:

- `python3 scripts/fetch_google_reviews.py --output data/google_reviews.json --max-reviews 20 && python3 scripts/fetch_facebook_news.py --page https://www.facebook.com/CobraBoxingClub --public-scrape --output-dir content/news --max-posts 5 && hugo`

Optional: override JSON output path for posts cache:

- `--posts-file data/facebook_posts.json`

Cloudflare environment variables should include:

- `FB_PAGE_USERNAME=<your_page_username>` (only needed for Graph API mode)
- `FB_ACCESS_TOKEN=<your_facebook_access_token>` (only needed for Graph API mode)

Public scrape mode notes:

- Uses public Facebook page HTML only, no token required.
- This is unofficial and can break if Facebook markup changes.
- If it fails, existing `content/news` posts remain in place.

## OneDrive Gallery Sync

Gallery images can be synced from a shared OneDrive folder at build time:

- Script: `scripts/sync_onedrive_gallery.py`
- Output image folder: `static/img/gallery/`
- Sync status file: `data/onedrive_gallery_sync.json`

Required secrets/env vars:

- `ONEDRIVE_FOLDER_SHARE_URL`
- `ONEDRIVE_CLIENT_ID`
- `ONEDRIVE_CLIENT_SECRET`
- `ONEDRIVE_REFRESH_TOKEN`

Cloudflare Pages build command with gallery sync:

- `python3 scripts/fetch_google_reviews.py --output data/google_reviews.json --max-reviews 20 && python3 scripts/sync_onedrive_gallery.py --output-dir static/img/gallery && hugo`

Notes:

- Synced images are written into `static/img/gallery/` with the prefix `onedrive-`.
- Existing non-OneDrive gallery files are left untouched.
- The OneDrive folder should contain image files only for the cleanest results.

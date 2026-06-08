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

Required secrets/env vars:

- `GOOGLE_PLACE_ID`
- `GOOGLE_PLACES_API_KEY`

Cloudflare Pages configuration:

- Build command: `python3 scripts/fetch_google_reviews.py --output data/google_reviews.json --max-reviews 20 && hugo`
- Environment variables:
	- `HUGO_VERSION=0.160.1`
	- `GOOGLE_PLACE_ID=<your_place_id>`
	- `GOOGLE_PLACES_API_KEY=<your_api_key>`

Testimonials page renders Google reviews through the shortcode in `content/testimonials.md`.

## Facebook Posts to News Automation

Facebook page posts can be imported into Hugo news posts at build time:

- Script: `scripts/fetch_facebook_news.py`
- Output news markdown: `content/news/`
- Sync status file: `data/facebook_news_sync.json`

Required secrets/env vars:

- `FB_PAGE_USERNAME` (for example `CobraBoxingClub`)
- `FB_ACCESS_TOKEN`

GitHub workflow uses these secrets in `.github/workflows/hugo-deploy.yml`.

Cloudflare Pages build command should include both sync steps:

- `python3 scripts/fetch_google_reviews.py --output data/google_reviews.json --max-reviews 20 && python3 scripts/fetch_facebook_news.py --output-dir content/news --max-posts 5 && hugo`

Cloudflare environment variables should include:

- `FB_PAGE_USERNAME=<your_page_username>`
- `FB_ACCESS_TOKEN=<your_facebook_access_token>`

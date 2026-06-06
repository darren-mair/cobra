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

- Hugo `0.147.7` (Cloudflare-compatible)
- Hugo `0.160.1` (current local/GitHub setup)
- Both base URLs:
	- `https://cobraboxingandfitness.com/`
	- `https://darren-mair.github.io/cobra/`

Validation workflow: `.github/workflows/hugo-validate.yml`.

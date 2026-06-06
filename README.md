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

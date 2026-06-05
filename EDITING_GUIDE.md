# Cobra Site Editing Guide

This site is easiest to maintain from markdown files in `content` and data files in `data`.

## What to edit for each change

- Page text (Classes, Membership, Contact, Policies): edit files in `content/`
- Main menu links/order: edit `config/_default/hugo.toml` under `[[menu.main]]`
- Top contact bar text (phone/email line): edit `config/_default/hugo.toml` under `[params.topbar]`
- Homepage class timetable: edit `data/class_calendar.toml`
- Homepage trust strip/membership cards/final CTA: edit `data/homepage.toml`
- Homepage slider (hero carousel): edit files in `data/carousel/`
- Homepage feature boxes: edit files in `data/features/`
- Cobra Champs gallery title/subtitle: edit `data/cobra_champs.toml`
- Cobra Champs gallery images: add/remove files in `static/img/cobra-champs/`
- Menu logo image: replace image in `static/img/cobra-cropped.png`
- Site colors and spacing: edit `static/css/custom.css`

## Files you should normally edit

- `content/classes.md`
- `content/membership.md`
- `content/contact.md`
- `content/policies.md`
- `content/cobra-champs.md`
- `data/class_calendar.toml`
- `data/homepage.toml`
- `data/carousel/`
- `data/features/`
- `data/cobra_champs.toml`
- `config/_default/hugo.toml`

## Files you should usually avoid editing

- `public/` (generated output)
- `themes/hugo-universal-theme/` (theme source)
- `layouts/` unless you want to change page structure/components

## Why there is content in static

`static/` is for assets, not page copy:

- Images: `static/img/...`
- Stylesheet: `static/css/custom.css`

Hugo copies `static/` into the built site exactly as-is.

## Quick workflow (safe and simple)

1. Edit markdown in `content/` or schedule data in `data/class_calendar.toml`.
2. Add images under `static/img/`.
3. Run `hugo` to build.
4. Run `hugo server` to preview.

## Adding menu items quickly

Main nav is controlled by repeated `[[menu.main]]` blocks in `config/_default/hugo.toml`.

Copy this pattern and change `name`, `url`, and `weight`:

```toml
[[menu.main]]
name = "Gym"
url = "/gym/"
weight = 3
```

Tips:

- Lower `weight` appears earlier in the menu.
- Add a matching page file in `content/` (for example `content/gym.md`) so the link has a page.

## Editing the class calendar

Calendar data lives in `data/class_calendar.toml`.

- `headers` controls the time columns.
- each `[[table.rows]]` block is one day.
- each `slots` list must have the same number of entries as `headers` minus the day column.

Example row:

```toml
[[table.rows]]
day = "Monday"
slots = ["-", "-", "-", "-", "Cobra Squad (Kids Advanced)", "Mixed Adults"]
```

## Homepage editing (new)

Homepage promo sections are now data-driven from `data/homepage.toml`:

- `trust_strip` for the icon + text list
- `membership_cards` for plan cards and buttons
- `final_cta` for the bottom call-to-action text and links

You can now edit those homepage sections without touching `layouts/` files.

## Homepage slider and feature boxes

These were already data-driven and are edited here:

- `data/carousel/*.yaml` for the home slider cards
- `data/features/*.yaml` for the feature boxes under the slider

Each file is one card/feature. Update the text, icon, links, or image path directly in YAML.

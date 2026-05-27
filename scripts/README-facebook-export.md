# Facebook Content Export (Page Owner)

This script exports page metadata, posts, photos, videos metadata, and downloads media files.

Script: ./scripts/export-facebook-page.ps1

## Prerequisites

- You are admin/editor of the Facebook Page.
- You have a valid User/Page access token with required permissions.

Typical permissions needed:

- pages_read_engagement
- pages_read_user_content

## Usage

Option 1 (recommended): set token in environment variable.

```powershell
$env:FB_ACCESS_TOKEN = "YOUR_TOKEN_HERE"
./scripts/export-facebook-page.ps1 -PageUsername "CobraBoxingClub"
```

Option 2: pass token directly.

```powershell
./scripts/export-facebook-page.ps1 -PageUsername "CobraBoxingClub" -AccessToken "YOUR_TOKEN_HERE"
```

Optional custom output location:

```powershell
./scripts/export-facebook-page.ps1 -PageUsername "CobraBoxingClub" -OutputDir "./import/facebook"
```

## Output

The export is written under:

- ./import/facebook/<page-username>/

Files created:

- page.json
- posts.json
- photos.json
- videos.json (if permitted)
- media-manifest.json
- posts.md
- media/ (downloaded images/video files)

## Notes

- Facebook/Meta can throttle requests or block fields depending on token scope.
- Download only content you own or are authorized to reuse.

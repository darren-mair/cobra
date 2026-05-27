param(
    [int]$Port = 1313
)

$ErrorActionPreference = "Stop"

# Prevent stale Hugo instances from serving an unexpected config.
Get-Process hugo -ErrorAction SilentlyContinue | Stop-Process -Force

hugo server `
    --config hugo.toml `
    --bind 127.0.0.1 `
    --port $Port `
    --disableFastRender

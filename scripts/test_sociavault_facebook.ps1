param(
    [string]$PageUrl = $(if ($env:FB_PAGE_URL) { $env:FB_PAGE_URL } else { "https://facebook.com/CobraBoxingClub" }),
    [string]$OutputFile = "data/facebook_page.json"
)

$apiKey = $env:SOCIAVAULT_API_KEY

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host "Missing SOCIAVAULT_API_KEY environment variable."
    exit 1
}

$encodedUrl = [System.Uri]::EscapeDataString($PageUrl)
$uri = "https://api.sociavault.com/v1/scrape/facebook/profile?url=$encodedUrl"

try {
    $headers = @{ "x-api-key" = $apiKey }
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop

    $payload = [ordered]@{
        ok         = $true
        reason     = ""
        fetched_at = (Get-Date).ToUniversalTime().ToString("o")
        page_url   = $PageUrl
        data       = $response.data
        raw        = $response
    }

    $outputDir = Split-Path -Parent $OutputFile
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }

    $payload | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host "Sociavault local test: wrote $OutputFile"
}
catch {
    $payload = [ordered]@{
        ok         = $false
        reason     = "request_error"
        message    = $_.Exception.Message
        fetched_at = (Get-Date).ToUniversalTime().ToString("o")
        page_url   = $PageUrl
        data       = $null
    }

    $outputDir = Split-Path -Parent $OutputFile
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }

    $payload | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host "Sociavault local test failed: $($_.Exception.Message)"
    exit 1
}

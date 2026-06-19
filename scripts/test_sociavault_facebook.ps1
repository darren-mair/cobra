param(
    [string]$PageUrl = "",
    [string]$OutputFile = "data/facebook_page.json"
)

function Resolve-PageUrl {
    param([string]$InputValue)

    $candidate = $InputValue
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $env:FB_PAGE_URL }
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $env:FB_PAGE_USERNAME }
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = "https://www.facebook.com/CobraBoxingClub" }

    $candidate = $candidate.Trim()
    if ($candidate -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') {
        return "https://www.facebook.com/$($candidate.Trim('/'))"
    }

    try {
        $uri = [System.Uri]$candidate
        $builder = [System.UriBuilder]$uri
        if ($builder.Host -in @("facebook.com", "m.facebook.com", "mbasic.facebook.com")) {
            $builder.Scheme = "https"
            $builder.Host = "www.facebook.com"
        }
        return $builder.Uri.AbsoluteUri.TrimEnd("/")
    }
    catch {
        return $candidate.TrimEnd("/")
    }
}

$PageUrl = Resolve-PageUrl -InputValue $PageUrl

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

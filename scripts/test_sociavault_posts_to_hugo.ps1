param(
    [string]$PageUrl = "",
    [string]$OutputDir = "content/news",
    [string]$ImageDir = "static/img/posters",
    [string]$ChampsImageDir = "static/img/cobra-champs",
    [string]$FallbackImage = "img/cobra-cropped.png",
    [string]$PostsJsonOut = "data/facebook_posts.json",
    [int]$MaxPosts = 10,
    [string]$Endpoint = "https://api.sociavault.com/v1/scrape/facebook/profile/posts"
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

function New-Slug {
    param([string]$Text)
    $slug = ($Text ?? "").ToLowerInvariant()
    $slug = [regex]::Replace($slug, "[^a-z0-9]+", "-")
    $slug = [regex]::Replace($slug, "-+", "-").Trim("-")
    if ([string]::IsNullOrWhiteSpace($slug)) { return "post" }
    return $slug
}

function Escape-Toml {
    param([string]$Text)
    return ($Text ?? "").Replace("\", "\\").Replace('"', '\"')
}

function Get-PostDate {
    param($Post, [int]$Index)
    $candidates = @(
        $Post.created_time,
        $Post.createdAt,
        $Post.published_at,
        $Post.publishTime,
        $Post.published_time,
        $Post.timestamp,
        $Post.time
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($value in $candidates) {
        try {
            $stringValue = [string]$value
            if ($stringValue -match '^\d{10,13}$') {
                $epochValue = [int64]$stringValue
                if ($stringValue.Length -ge 13) {
                    return [DateTimeOffset]::FromUnixTimeMilliseconds($epochValue).ToUniversalTime()
                }
                return [DateTimeOffset]::FromUnixTimeSeconds($epochValue).ToUniversalTime()
            }

            return [DateTimeOffset]::Parse($stringValue).ToUniversalTime()
        }
        catch { }
    }

    return [DateTimeOffset]::UtcNow.AddMinutes(-1 * $Index)
}

function Get-PostText {
    param($Post)
    $candidates = @(
        $Post.message,
        $Post.text,
        $Post.caption,
        $Post.description,
        $Post.content
    )

    foreach ($candidate in $candidates) {
        $value = [string]$candidate
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    return ""
}

function Get-PostLink {
    param($Post)
    $candidates = @(
        $Post.permalink_url,
        $Post.permalink,
        $Post.url,
        $Post.postUrl,
        $Post.link
    )

    foreach ($candidate in $candidates) {
        $value = [string]$candidate
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    return ""
}

function Get-PostImageUrl {
    param($Post)

    $direct = @(
        $Post.full_picture,
        $Post.image,
        $Post.image_url,
        $Post.imageUrl,
        $Post.thumbnail,
        $Post.thumbnail_url
    )

    foreach ($candidate in $direct) {
        $value = [string]$candidate
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    if ($Post.images -is [System.Collections.IEnumerable]) {
        foreach ($img in $Post.images) {
            if ($img -is [string] -and -not [string]::IsNullOrWhiteSpace($img)) { return $img }
            if ($img.url) { return [string]$img.url }
            if ($img.src) { return [string]$img.src }
        }
    }

    if ($Post.media -is [System.Collections.IEnumerable]) {
        foreach ($m in $Post.media) {
            if ($m.url) { return [string]$m.url }
            if ($m.src) { return [string]$m.src }
        }
    }

    return ""
}

function Normalize-PostsArray {
    param($Json)

    function Convert-ObjectValuesToArray {
        param($Obj)
        if ($null -eq $Obj) { return @() }

        # Hashtable-like payloads: use values, not keys/dictionary entries.
        if ($Obj -is [System.Collections.IDictionary]) {
            return @($Obj.Values)
        }

        if ($Obj.PSObject -and $Obj.PSObject.Properties.Count -gt 0) {
            return @($Obj.PSObject.Properties | ForEach-Object { $_.Value })
        }

        if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) { return @($Obj) }
        return @($Obj)
    }

    if ($Json.data -and $Json.data.posts) { return Convert-ObjectValuesToArray -Obj $Json.data.posts }
    if ($Json.data -and $Json.data.latestPosts) { return @($Json.data.latestPosts) }
    if ($Json.data -and $Json.data.items) { return @($Json.data.items) }
    if ($Json.posts) { return Convert-ObjectValuesToArray -Obj $Json.posts }
    if ($Json.items) { return @($Json.items) }
    if ($Json.data -is [System.Collections.IEnumerable] -and -not ($Json.data -is [string])) { return @($Json.data) }
    if ($Json -is [System.Collections.IEnumerable] -and -not ($Json -is [string])) { return @($Json) }

    return @()
}

function Build-EndpointCandidates {
    param([string]$BaseEndpoint, [string]$PageUrl)

    $escaped = [System.Uri]::EscapeDataString($PageUrl)

    $candidates = @()

    if ($BaseEndpoint -match "\{url\}" -or $BaseEndpoint -match "\{raw_url\}") {
        $tmp = $BaseEndpoint -replace "\{url\}", $escaped
        $tmp = $tmp -replace "\{raw_url\}", $PageUrl
        $candidates += $tmp
    }
    elseif ($BaseEndpoint -match "url=") {
        $candidates += ($BaseEndpoint -replace "url=[^&]*", "url=$escaped")
        $candidates += ($BaseEndpoint -replace "url=[^&]*", "url=$PageUrl")
    }
    else {
        $candidates += "${BaseEndpoint}?url=$escaped&count=$MaxPosts"
        $candidates += "${BaseEndpoint}?url=$PageUrl&count=$MaxPosts"
    }

    # Common alternates seen in vendor docs.
    $candidates += "https://api.sociavault.com/v1/scrape/facebook/profile/posts?url=$escaped&count=$MaxPosts"
    $candidates += "https://api.sociavault.com/v1/scrape/facebook/posts?url=$escaped&count=$MaxPosts"
    $candidates += "https://api.sociavault.com/v1/scrape/facebook/profile?url=$escaped"

    return $candidates | Select-Object -Unique
}

$PageUrl = Resolve-PageUrl -InputValue $PageUrl

$apiKey = $env:SOCIAVAULT_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host "Missing SOCIAVAULT_API_KEY environment variable."
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $ImageDir | Out-Null
New-Item -ItemType Directory -Force -Path $ChampsImageDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PostsJsonOut) | Out-Null

$attempts = @()
$response = $null
$usedUri = ""

try {
    $headers = @{ "x-api-key" = $apiKey }

    $uris = Build-EndpointCandidates -BaseEndpoint $Endpoint -PageUrl $PageUrl
    foreach ($candidate in $uris) {
        try {
            $tmp = Invoke-RestMethod -Uri $candidate -Headers $headers -Method Get -ErrorAction Stop
            $tmpPosts = Normalize-PostsArray -Json $tmp

            $attempts += [ordered]@{
                endpoint = $candidate
                ok = $true
                posts_detected = $tmpPosts.Count
                error = ""
            }

            if ($tmpPosts.Count -gt 0) {
                $response = $tmp
                $usedUri = $candidate
                break
            }

            # Keep a valid response as fallback for diagnostics even if no posts array detected.
            if (-not $response) {
                $response = $tmp
                $usedUri = $candidate
            }
        }
        catch {
            $attempts += [ordered]@{
                endpoint = $candidate
                ok = $false
                posts_detected = 0
                error = $_.Exception.Message
            }
        }
    }

    if (-not $response) {
        throw [System.Exception]::new("all_endpoints_failed")
    }

    $posts = Normalize-PostsArray -Json $response
    if (-not $posts -or $posts.Count -eq 0) {
        $fallback = [ordered]@{
            ok         = $false
            reason     = "no_posts_in_response"
            fetched_at = (Get-Date).ToUniversalTime().ToString("o")
            page_url   = $PageUrl
            endpoint   = $usedUri
            attempts   = $attempts
            raw        = $response
        }
        $fallback | ConvertTo-Json -Depth 30 | Set-Content -Path $PostsJsonOut -Encoding UTF8
        Write-Host "Sociavault posts test: no posts found in API response."
        exit 1
    }

    $generated = @()
    $normalized = @()
    $count = [Math]::Min($MaxPosts, $posts.Count)

    for ($i = 0; $i -lt $count; $i++) {
        $post = $posts[$i]

        if ($post -is [System.Collections.DictionaryEntry]) {
            $post = $post.Value
        }

        $text = Get-PostText -Post $post
        $link = Get-PostLink -Post $post
        $imageUrl = Get-PostImageUrl -Post $post
        $dateUtc = Get-PostDate -Post $post -Index $i

        $idCandidates = @(
            $post.id,
            $post.post_id,
            $post.postId,
            $post.fb_post_id
        )

        $resolvedId = ""
        foreach ($candidate in $idCandidates) {
            $value = [string]$candidate
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $resolvedId = $value
                break
            }
        }

        $postId = if (-not [string]::IsNullOrWhiteSpace($resolvedId)) { $resolvedId } else { "post-$($i + 1)" }
        $safeId = [regex]::Replace($postId, "[^0-9A-Za-z_-]", "")
        if ([string]::IsNullOrWhiteSpace($safeId)) { $safeId = "post-$($i + 1)" }

        $line = (($text -split "`r?`n")[0]).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { $line = "Facebook update $safeId" }
        $title = if ($line.Length -gt 90) { $line.Substring(0, 90) } else { $line }

        $summary = if ([string]::IsNullOrWhiteSpace($text)) { "Latest update from our Facebook page." } else { $text }
        $summary = ($summary -replace "`r?`n", " ").Trim()
        if ($summary.Length -gt 155) { $summary = $summary.Substring(0, 155) }

        $localImagePath = ""
        $localImageFile = ""
        if (-not [string]::IsNullOrWhiteSpace($imageUrl)) {
            try {
                $ext = [IO.Path]::GetExtension(($imageUrl -split "\?", 2)[0]).ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($ext)) { $ext = ".jpg" }
                $imageFile = "sociavault-$safeId$ext"
                $imageOut = Join-Path $ImageDir $imageFile
                Invoke-WebRequest -Uri $imageUrl -OutFile $imageOut -Headers @{ "User-Agent" = "Mozilla/5.0" } -ErrorAction Stop | Out-Null
                $localImagePath = "img/posters/$imageFile"
                $localImageFile = $imageFile
            }
            catch { }
        }

        # If the post mentions champ/champs, duplicate the downloaded photo into the Cobra Champs gallery folder.
        if (
            -not [string]::IsNullOrWhiteSpace($localImageFile) -and
            -not [string]::IsNullOrWhiteSpace($text) -and
            $text -imatch "champ"
        ) {
            try {
                Copy-Item -Path (Join-Path $ImageDir $localImageFile) -Destination (Join-Path $ChampsImageDir $localImageFile) -Force
            }
            catch { }
        }

        $slug = New-Slug -Text $title
        $fileName = "{0:yyyy-MM-dd}-sociavault-{1}.md" -f $dateUtc, $safeId
        $mdPath = Join-Path $OutputDir $fileName

        $frontMatter = @(
            "+++",
            ('title = "{0}"' -f (Escape-Toml -Text $title)),
            ('date = {0:yyyy-MM-ddTHH:mm:ssZ}' -f $dateUtc),
            'type = "post"',
            'tags = ["facebook"]',
            ('summary = "{0}"' -f (Escape-Toml -Text $summary))
        )

        $postImage = if (-not [string]::IsNullOrWhiteSpace($localImagePath)) { $localImagePath } else { $FallbackImage }
        $frontMatter += ('image = "{0}"' -f $postImage)

        $frontMatter += "+++"
        $frontMatter += ""

        $body = @()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $body += $text
            $body += ""
        }
        else {
            $body += "(No text content provided in this Facebook post.)"
            $body += ""
        }

        if (-not [string]::IsNullOrWhiteSpace($link)) {
            $body += "[View on Facebook]($link)"
        }

        ($frontMatter + $body) -join "`n" | Set-Content -Path $mdPath -Encoding UTF8
        $generated += $mdPath

        $normalized += [ordered]@{
            id = $safeId
            created_time = $dateUtc.ToString("o")
            message = $text
            permalink_url = $link
            full_picture = $postImage
        }
    }

    $payload = [ordered]@{
        ok = $true
        reason = ""
        fetched_at = (Get-Date).ToUniversalTime().ToString("o")
        page_url = $PageUrl
        endpoint = $usedUri
        attempts = $attempts
        generated = $generated.Count
        files = $generated
        posts = $normalized
        raw = $response
    }

    $payload | ConvertTo-Json -Depth 30 | Set-Content -Path $PostsJsonOut -Encoding UTF8
    Write-Host "Sociavault posts test: generated $($generated.Count) Hugo posts and wrote $PostsJsonOut"
}
catch {
    $payload = [ordered]@{
        ok = $false
        reason = "request_error"
        message = $_.Exception.Message
        fetched_at = (Get-Date).ToUniversalTime().ToString("o")
        page_url = $PageUrl
        endpoint = $Endpoint
        attempts = $attempts
    }
    $payload | ConvertTo-Json -Depth 30 | Set-Content -Path $PostsJsonOut -Encoding UTF8
    Write-Host "Sociavault posts test failed: $($_.Exception.Message)"
    exit 1
}

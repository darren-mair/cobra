param(
    [string]$PageUrl = "",
    [string]$OutputDir = "content/news",
    [string]$ImageDir = "static/img/posters",
    [string]$ChampsImageDir = "static/img/cobra-champs",
    [string]$VideoDir = "static/video/posts",
    [string]$ChampsVideoDir = "static/video/cobra-champs",
    [string]$FallbackImage = "img/cobra-cropped.png",
    [string]$PostsJsonOut = "data/facebook_posts.json",
    [int]$MaxPosts = 10,
    [string]$Endpoint = $env:APIFY_DATASET_ITEMS_URL
)

if ([string]::IsNullOrWhiteSpace($Endpoint)) {
    Write-Host "Missing APIFY_DATASET_ITEMS_URL environment variable. Set it to your Apify dataset items endpoint."
    exit 1
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

    # Apify items often include a unix timestamp in seconds.
    try {
        if ($null -ne $Post.timestamp) {
            $raw = [string]$Post.timestamp
            if (-not [string]::IsNullOrWhiteSpace($raw) -and $raw -match "^\d+$") {
                return [DateTimeOffset]::FromUnixTimeSeconds([int64]$raw).ToUniversalTime()
            }
        }
    }
    catch { }

    $candidates = @(
        $Post.created_time,
        $Post.createdAt,
        $Post.time,
        $Post.published_at,
        $Post.timestamp
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($value in $candidates) {
        try {
            $stringValue = [string]$value
            if ($stringValue -match '^\d+$') {
                $epochValue = [int64]$stringValue
                if ($epochValue -ge 100000000000) {
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

function Test-ProbablyImageUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    $u = $Url.ToLowerInvariant()
    if ($u -match "\.(jpg|jpeg|png|webp|gif|bmp|avif)(\?|$)") { return $true }
    if ($u -match "fbcdn\.net" -or $u -match "scontent\.") { return $true }
    if ($u -match "/reel/" -or $u -match "/videos?/" -or $u -match "facebook\.com/.*/posts/") { return $false }
    return $false
}

function Test-ProbablyVideoUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    $u = $Url.ToLowerInvariant()
    if ($u -match "\.(mp4|m4v|mov|webm)(\?|$)") { return $true }
    if ($u -match "video\.fbcdn\.net" -or $u -match "browser_native_(hd|sd)_url") { return $true }
    return $false
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
        if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-ProbablyImageUrl -Url $value)) {
            return $value
        }
    }

    if ($Post.images -is [System.Collections.IEnumerable]) {
        foreach ($img in $Post.images) {
            if ($img -is [string] -and (Test-ProbablyImageUrl -Url ([string]$img))) { return [string]$img }
            if ($img.url -and (Test-ProbablyImageUrl -Url ([string]$img.url))) { return [string]$img.url }
            if ($img.src -and (Test-ProbablyImageUrl -Url ([string]$img.src))) { return [string]$img.src }
        }
    }

    if ($Post.media -is [System.Collections.IEnumerable]) {
        foreach ($m in $Post.media) {
            if ($m.thumbnailImage -and $m.thumbnailImage.uri -and (Test-ProbablyImageUrl -Url ([string]$m.thumbnailImage.uri))) { return [string]$m.thumbnailImage.uri }
            if ($m.thumbnail -and (Test-ProbablyImageUrl -Url ([string]$m.thumbnail))) { return [string]$m.thumbnail }
            if ($m.image -and $m.image.uri -and (Test-ProbablyImageUrl -Url ([string]$m.image.uri))) { return [string]$m.image.uri }
            if ($m.url -and (Test-ProbablyImageUrl -Url ([string]$m.url))) { return [string]$m.url }
            if ($m.src -and (Test-ProbablyImageUrl -Url ([string]$m.src))) { return [string]$m.src }
        }
    }

    return ""
}

function Get-PostMediaUrls {
    param($Post)

    $images = [System.Collections.ArrayList]::new()
    $videos = [System.Collections.ArrayList]::new()
    $seen = @{}

    function Add-MediaUrl {
        param(
            [System.Collections.ArrayList]$List,
            [string]$Url,
            [string]$Type,
            [hashtable]$Seen
        )

        $value = ([string]$Url).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return }

        if ($Type -eq "image") {
            if (-not (Test-ProbablyImageUrl -Url $value)) { return }
        }
        elseif ($Type -eq "video") {
            if (-not (Test-ProbablyVideoUrl -Url $value)) { return }
        }

        if ($Seen.ContainsKey($value)) { return }
        $Seen[$value] = $true
        [void]$List.Add($value)
    }

    Add-MediaUrl -List $images -Url $Post.full_picture -Type "image" -Seen $seen
    Add-MediaUrl -List $images -Url $Post.image -Type "image" -Seen $seen
    Add-MediaUrl -List $images -Url $Post.image_url -Type "image" -Seen $seen
    Add-MediaUrl -List $images -Url $Post.imageUrl -Type "image" -Seen $seen
    Add-MediaUrl -List $images -Url $Post.thumbnail -Type "image" -Seen $seen
    Add-MediaUrl -List $images -Url $Post.thumbnail_url -Type "image" -Seen $seen

    Add-MediaUrl -List $videos -Url $Post.video -Type "video" -Seen $seen
    Add-MediaUrl -List $videos -Url $Post.video_url -Type "video" -Seen $seen
    Add-MediaUrl -List $videos -Url $Post.videoUrl -Type "video" -Seen $seen

    if ($Post.images -is [System.Collections.IEnumerable]) {
        foreach ($img in $Post.images) {
            if ($img -is [string]) {
                Add-MediaUrl -List $images -Url ([string]$img) -Type "image" -Seen $seen
            }
            else {
                Add-MediaUrl -List $images -Url ([string]$img.url) -Type "image" -Seen $seen
                Add-MediaUrl -List $images -Url ([string]$img.src) -Type "image" -Seen $seen
            }
        }
    }

    if ($Post.media -is [System.Collections.IEnumerable]) {
        foreach ($m in $Post.media) {
            Add-MediaUrl -List $images -Url ([string]$m.thumbnailImage.uri) -Type "image" -Seen $seen
            Add-MediaUrl -List $images -Url ([string]$m.thumbnail) -Type "image" -Seen $seen
            Add-MediaUrl -List $images -Url ([string]$m.image.uri) -Type "image" -Seen $seen

            Add-MediaUrl -List $videos -Url ([string]$m.browser_native_hd_url) -Type "video" -Seen $seen
            Add-MediaUrl -List $videos -Url ([string]$m.browser_native_sd_url) -Type "video" -Seen $seen
            if ($m.videoDeliveryLegacyFields) {
                Add-MediaUrl -List $videos -Url ([string]$m.videoDeliveryLegacyFields.browser_native_hd_url) -Type "video" -Seen $seen
                Add-MediaUrl -List $videos -Url ([string]$m.videoDeliveryLegacyFields.browser_native_sd_url) -Type "video" -Seen $seen
            }
            Add-MediaUrl -List $videos -Url ([string]$m.videoUrl) -Type "video" -Seen $seen
            Add-MediaUrl -List $videos -Url ([string]$m.url) -Type "video" -Seen $seen
            Add-MediaUrl -List $videos -Url ([string]$m.src) -Type "video" -Seen $seen
        }
    }

    return [ordered]@{
        images = @($images)
        videos = @($videos)
    }
}

function Test-ImageFileSignature {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 12) { return $false }

        # JPEG
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF) { return $true }
        # PNG
        if ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) { return $true }
        # GIF
        if ($bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46) { return $true }
        # WEBP (RIFF....WEBP)
        if ($bytes[0] -eq 0x52 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x46 -and
            $bytes[8] -eq 0x57 -and $bytes[9] -eq 0x45 -and $bytes[10] -eq 0x42 -and $bytes[11] -eq 0x50) { return $true }

        return $false
    }
    catch {
        return $false
    }
}

function Test-VideoFileSignature {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 12) { return $false }

        # MP4/MOV family usually has ftyp box at offset 4.
        if ($bytes[4] -eq 0x66 -and $bytes[5] -eq 0x74 -and $bytes[6] -eq 0x79 -and $bytes[7] -eq 0x70) { return $true }
        return $false
    }
    catch {
        return $false
    }
}

function Detect-ImageExtFromUrl {
    param([string]$Url)

    $base = ($Url -split "\?", 2)[0]
    $ext = [IO.Path]::GetExtension($base).ToLowerInvariant()
    if ($ext -in @(".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".avif")) { return $ext }
    return ".jpg"
}

function Detect-VideoExtFromUrl {
    param([string]$Url)

    $base = ($Url -split "\?", 2)[0]
    $ext = [IO.Path]::GetExtension($base).ToLowerInvariant()
    if ($ext -in @(".mp4", ".m4v", ".mov", ".webm")) { return $ext }
    return ".mp4"
}

function Build-TomlStringArray {
    param([string[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return "[]"
    }

    $quoted = @($Values | ForEach-Object { '"{0}"' -f (Escape-Toml -Text $_) })
    return "[{0}]" -f ($quoted -join ", ")
}

function Normalize-PostsArray {
    param($Json)

    function Get-ObjectPropertyValue {
        param($Obj, [string]$Name)
        if ($null -eq $Obj) { return $null }

        if ($Obj -is [System.Collections.IDictionary] -and $Obj.Contains($Name)) {
            return $Obj[$Name]
        }

        if ($Obj.PSObject) {
            $prop = $Obj.PSObject.Properties[$Name]
            if ($prop) {
                return $prop.Value
            }
        }

        return $null
    }

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

    # Apify dataset items endpoint returns a direct JSON array of post objects.
    if ($Json -is [System.Collections.IEnumerable] -and -not ($Json -is [string]) -and -not ($Json -is [System.Collections.IDictionary])) {
        $arr = @($Json)
        if ($arr.Count -gt 0 -and ($arr[0] -is [System.Collections.IDictionary] -or $arr[0].PSObject)) {
            return $arr
        }
    }

    $jsonData = Get-ObjectPropertyValue -Obj $Json -Name "data"
    $jsonPosts = Get-ObjectPropertyValue -Obj $Json -Name "posts"
    $jsonItems = Get-ObjectPropertyValue -Obj $Json -Name "items"

    $dataPosts = Get-ObjectPropertyValue -Obj $jsonData -Name "posts"
    if ($dataPosts) { return Convert-ObjectValuesToArray -Obj $dataPosts }

    $dataLatestPosts = Get-ObjectPropertyValue -Obj $jsonData -Name "latestPosts"
    if ($dataLatestPosts) { return @($dataLatestPosts) }

    $dataItems = Get-ObjectPropertyValue -Obj $jsonData -Name "items"
    if ($dataItems) { return @($dataItems) }

    if ($jsonPosts) { return Convert-ObjectValuesToArray -Obj $jsonPosts }
    if ($jsonItems) { return @($jsonItems) }
    if ($jsonData -is [System.Collections.IEnumerable] -and -not ($jsonData -is [string])) { return @($jsonData) }
    if ($Json -is [System.Collections.IEnumerable] -and -not ($Json -is [string])) { return @($Json) }

    return @()
}

function Convert-PostToMap {
    param($Post)

    $map = [ordered]@{}
    if ($Post -is [System.Collections.IDictionary]) {
        foreach ($k in $Post.Keys) {
            $map[[string]$k] = $Post[$k]
        }
        return $map
    }

    if ($Post.PSObject -and $Post.PSObject.Properties.Count -gt 0) {
        foreach ($prop in $Post.PSObject.Properties) {
            $map[$prop.Name] = $prop.Value
        }
    }

    return $map
}

function Build-EndpointCandidates {
    param([string]$BaseEndpoint)

    if ([string]::IsNullOrWhiteSpace($BaseEndpoint)) {
        return @()
    }

    $trimmed = $BaseEndpoint.Trim()
    $candidates = @($trimmed)

    if ($trimmed -notmatch "[?&]limit=") {
        if ($trimmed -match "\?") {
            $candidates += "$trimmed&limit=$MaxPosts"
        }
        else {
            $candidates += "$trimmed?limit=$MaxPosts"
        }
    }

    return $candidates | Select-Object -Unique
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $ImageDir | Out-Null
New-Item -ItemType Directory -Force -Path $ChampsImageDir | Out-Null
New-Item -ItemType Directory -Force -Path $VideoDir | Out-Null
New-Item -ItemType Directory -Force -Path $ChampsVideoDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PostsJsonOut) | Out-Null

$attempts = @()
$response = $null
$usedUri = ""

try {
    $headers = @{ "Accept" = "application/json" }

    $uris = Build-EndpointCandidates -BaseEndpoint $Endpoint
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
        Write-Host "Apify posts import: no posts found in API response."
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
        $media = Get-PostMediaUrls -Post $post
        $dateUtc = Get-PostDate -Post $post -Index $i

        $idCandidates = @(
            $post.id,
            $post.postId,
            $post.post_id,
            $post.feedbackId,
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

        $localImagePaths = @()
        $localImageFiles = @()
        for ($m = 0; $m -lt $media.images.Count; $m++) {
            $imageUrl = [string]$media.images[$m]
            if ([string]::IsNullOrWhiteSpace($imageUrl)) { continue }

            try {
                $ext = Detect-ImageExtFromUrl -Url $imageUrl
                $imageFile = "apify-{0}-{1}{2}" -f $safeId, ($m + 1), $ext
                $imageOut = Join-Path $ImageDir $imageFile
                Invoke-WebRequest -Uri $imageUrl -OutFile $imageOut -Headers @{ "User-Agent" = "Mozilla/5.0" } -ErrorAction Stop | Out-Null
                if (Test-ImageFileSignature -Path $imageOut) {
                    $localImagePaths += "img/posters/$imageFile"
                    $localImageFiles += $imageFile
                }
                else {
                    Remove-Item -Path $imageOut -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }

        $localVideoPaths = @()
        $localVideoFiles = @()
        for ($v = 0; $v -lt $media.videos.Count; $v++) {
            $videoUrl = [string]$media.videos[$v]
            if ([string]::IsNullOrWhiteSpace($videoUrl)) { continue }

            try {
                $ext = Detect-VideoExtFromUrl -Url $videoUrl
                $videoFile = "apify-{0}-{1}{2}" -f $safeId, ($v + 1), $ext
                $videoOut = Join-Path $VideoDir $videoFile
                Invoke-WebRequest -Uri $videoUrl -OutFile $videoOut -Headers @{ "User-Agent" = "Mozilla/5.0" } -ErrorAction Stop | Out-Null
                if (Test-VideoFileSignature -Path $videoOut) {
                    $localVideoPaths += "video/posts/$videoFile"
                    $localVideoFiles += $videoFile
                }
                else {
                    Remove-Item -Path $videoOut -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }

        # If the post mentions champ/champs, duplicate the downloaded photo into the Cobra Champs gallery folder.
        if (
            -not [string]::IsNullOrWhiteSpace($text) -and
            $text -imatch "champ"
        ) {
            foreach ($imgFile in $localImageFiles) {
                try {
                    Copy-Item -Path (Join-Path $ImageDir $imgFile) -Destination (Join-Path $ChampsImageDir $imgFile) -Force
                }
                catch { }
            }

            foreach ($vidFile in $localVideoFiles) {
                try {
                    Copy-Item -Path (Join-Path $VideoDir $vidFile) -Destination (Join-Path $ChampsVideoDir $vidFile) -Force
                }
                catch { }
            }
        }

        $slug = New-Slug -Text $title
        $fileName = "{0:yyyy-MM-dd}-apify-{1}.md" -f $dateUtc, $safeId
        $mdPath = Join-Path $OutputDir $fileName

        $frontMatter = @(
            "+++",
            ('title = "{0}"' -f (Escape-Toml -Text $title)),
            ('date = {0:yyyy-MM-ddTHH:mm:ssZ}' -f $dateUtc),
            'type = "post"',
            'tags = ["facebook"]',
            ('summary = "{0}"' -f (Escape-Toml -Text $summary))
        )

        $postImage = if ($localImagePaths.Count -gt 0) { [string]$localImagePaths[0] } else { $FallbackImage }
        $frontMatter += ('image = "{0}"' -f $postImage)
        if ($localImagePaths.Count -gt 0) {
            $frontMatter += ('images = {0}' -f (Build-TomlStringArray -Values $localImagePaths))
        }
        if ($localVideoPaths.Count -gt 0) {
            $frontMatter += ('videos = {0}' -f (Build-TomlStringArray -Values $localVideoPaths))
        }

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
            $body += ""
        }

        if ($localVideoPaths.Count -gt 0) {
            $body += "### Video"
            $body += ""
            foreach ($videoPath in $localVideoPaths) {
                $body += ('{{{{< video src="{0}" >}}}}' -f $videoPath)
                $body += ""
            }
        }

        if ($localImagePaths.Count -gt 1) {
            $body += "### Gallery"
            $body += ""
            foreach ($galleryImage in $localImagePaths) {
                $body += ("![Facebook post image](/{0})" -f $galleryImage)
                $body += ""
            }
        }

        ($frontMatter + $body) -join "`n" | Set-Content -Path $mdPath -Encoding UTF8
        $generated += $mdPath

        $fullPost = Convert-PostToMap -Post $post
        $fullPost["id"] = $safeId
        $fullPost["created_time"] = $dateUtc.ToString("o")
        $fullPost["message"] = $text
        $fullPost["permalink_url"] = $link
        $fullPost["full_picture"] = $postImage
        $fullPost["local_images"] = $localImagePaths
        $fullPost["local_videos"] = $localVideoPaths

        $normalized += [PSCustomObject]$fullPost
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
    Write-Host "Apify posts import: generated $($generated.Count) Hugo posts and wrote $PostsJsonOut"
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
    Write-Host "Apify posts import failed: $($_.Exception.Message)"
    exit 1
}

param(
    [Parameter(Mandatory = $false)]
    [string]$PageUsername = "CobraBoxingClub",

    [Parameter(Mandatory = $false)]
    [string]$AccessToken = $env:FB_ACCESS_TOKEN,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "./import/facebook"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    throw "Missing Facebook access token. Pass -AccessToken or set FB_ACCESS_TOKEN."
}

$ApiVersion = "v23.0"
$BaseUrl = "https://graph.facebook.com/$ApiVersion"

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-Graph {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [hashtable]$Query = @{}
    )

    $queryCopy = @{}
    foreach ($k in $Query.Keys) { $queryCopy[$k] = $Query[$k] }
    $queryCopy["access_token"] = $AccessToken

    $uri = "$BaseUrl/$Path"
    return Invoke-RestMethod -Method Get -Uri $uri -Body $queryCopy
}

function Get-AllPages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [hashtable]$Query = @{}
    )

    $results = @()

    $queryCopy = @{}
    foreach ($k in $Query.Keys) { $queryCopy[$k] = $Query[$k] }
    $queryCopy["access_token"] = $AccessToken

    $firstUri = "$BaseUrl/$Path"
    $response = Invoke-RestMethod -Method Get -Uri $firstUri -Body $queryCopy

    while ($null -ne $response) {
        if ($null -ne $response.data) {
            $results += $response.data
        }

        if ($response.paging -and $response.paging.next) {
            $response = Invoke-RestMethod -Method Get -Uri $response.paging.next
        }
        else {
            $response = $null
        }
    }

    return ,$results
}

function Save-Json {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Data,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Data | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-FileExtensionFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ".bin"
    }

    $clean = $Url.Split("?")[0]
    $ext = [System.IO.Path]::GetExtension($clean)
    if ([string]::IsNullOrWhiteSpace($ext)) {
        return ".jpg"
    }

    return $ext
}

function Download-FileSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    try {
        Invoke-WebRequest -Uri $Url -OutFile $DestinationPath
        return $true
    }
    catch {
        Write-Warning "Failed download: $Url"
        return $false
    }
}

function Collect-AttachmentMediaUrls {
    param([object]$AttachmentNode)

    $urls = New-Object System.Collections.Generic.List[string]

    if ($null -eq $AttachmentNode) {
        return $urls
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push($AttachmentNode)

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }

        if ($node.PSObject.Properties.Name -contains "media") {
            $media = $node.media
            if ($media -and $media.PSObject.Properties.Name -contains "image") {
                if ($media.image -and $media.image.src) {
                    $urls.Add([string]$media.image.src)
                }
            }
            if ($media -and $media.source) {
                $urls.Add([string]$media.source)
            }
        }

        foreach ($propName in @("url", "media_url", "unshimmed_url", "source")) {
            if ($node.PSObject.Properties.Name -contains $propName) {
                $val = $node.$propName
                if ($val -is [string] -and -not [string]::IsNullOrWhiteSpace($val)) {
                    $urls.Add($val)
                }
            }
        }

        if ($node.PSObject.Properties.Name -contains "subattachments") {
            $subs = $node.subattachments
            if ($subs -and $subs.data) {
                foreach ($s in $subs.data) { $stack.Push($s) }
            }
        }

        if ($node.PSObject.Properties.Name -contains "data") {
            $data = $node.data
            if ($data -is [System.Array]) {
                foreach ($d in $data) { $stack.Push($d) }
            }
        }
    }

    return $urls
}

Ensure-Dir $OutputDir
$mediaDir = Join-Path $OutputDir "media"
Ensure-Dir $mediaDir

Write-Host "Resolving page metadata for $PageUsername ..."
$page = Get-Graph -Path $PageUsername -Query @{
    fields = "id,name,username,about,description,link,picture.type(large){url},cover,category"
}

$pageDir = Join-Path $OutputDir $page.username
Ensure-Dir $pageDir
Ensure-Dir (Join-Path $pageDir "media")

Save-Json -Data $page -Path (Join-Path $pageDir "page.json")

# Download logo + cover where available
if ($page.picture -and $page.picture.data -and $page.picture.data.url) {
    Download-FileSafe -Url $page.picture.data.url -DestinationPath (Join-Path $pageDir "media/logo.jpg") | Out-Null
}

if ($page.cover -and $page.cover.source) {
    $coverExt = Get-FileExtensionFromUrl -Url $page.cover.source
    Download-FileSafe -Url $page.cover.source -DestinationPath (Join-Path $pageDir ("media/cover" + $coverExt)) | Out-Null
}

Write-Host "Fetching posts ..."
$postFields = "id,created_time,message,permalink_url,full_picture,status_type,attachments{media_type,media,url,media_url,unshimmed_url,source,subattachments}"
$posts = Get-AllPages -Path ($page.id + "/posts") -Query @{ fields = $postFields; limit = 100 }
Save-Json -Data $posts -Path (Join-Path $pageDir "posts.json")

Write-Host "Fetching uploaded photos ..."
$photos = Get-AllPages -Path ($page.id + "/photos") -Query @{ fields = "id,created_time,name,images,link"; type = "uploaded"; limit = 100 }
Save-Json -Data $photos -Path (Join-Path $pageDir "photos.json")

Write-Host "Fetching videos metadata ..."
try {
    $videos = Get-AllPages -Path ($page.id + "/videos") -Query @{ fields = "id,created_time,description,permalink_url,source"; limit = 50 }
    Save-Json -Data $videos -Path (Join-Path $pageDir "videos.json")
}
catch {
    Write-Warning "Video endpoint unavailable for this token/permissions."
    $videos = @()
}

$allMediaUrls = New-Object System.Collections.Generic.List[string]

foreach ($post in $posts) {
    if ($post.full_picture) {
        $allMediaUrls.Add([string]$post.full_picture)
    }

    if ($post.attachments) {
        $urls = Collect-AttachmentMediaUrls -AttachmentNode $post.attachments
        foreach ($u in $urls) { $allMediaUrls.Add($u) }
    }
}

foreach ($photo in $photos) {
    if ($photo.images -and $photo.images.Count -gt 0 -and $photo.images[0].source) {
        $allMediaUrls.Add([string]$photo.images[0].source)
    }
}

foreach ($video in $videos) {
    if ($video.source) {
        $allMediaUrls.Add([string]$video.source)
    }
}

$uniqueMedia = $allMediaUrls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

Write-Host "Downloading media files: $($uniqueMedia.Count) candidates ..."
$downloadManifest = @()
$index = 1
foreach ($url in $uniqueMedia) {
    $ext = Get-FileExtensionFromUrl -Url $url
    $safeName = ("media_{0:D4}{1}" -f $index, $ext)
    $destination = Join-Path (Join-Path $pageDir "media") $safeName

    $ok = Download-FileSafe -Url $url -DestinationPath $destination
    $downloadManifest += [PSCustomObject]@{
        index = $index
        url = $url
        file = $safeName
        downloaded = $ok
    }
    $index++
}

Save-Json -Data $downloadManifest -Path (Join-Path $pageDir "media-manifest.json")

# Create a lightweight markdown summary for content migration into Hugo.
$mdPath = Join-Path $pageDir "posts.md"
"# Facebook Export: $($page.name)" | Set-Content -LiteralPath $mdPath -Encoding UTF8
"" | Add-Content -LiteralPath $mdPath
"Generated: $(Get-Date -Format o)" | Add-Content -LiteralPath $mdPath
"" | Add-Content -LiteralPath $mdPath

foreach ($post in $posts) {
    "## Post $($post.id)" | Add-Content -LiteralPath $mdPath
    "Date: $($post.created_time)" | Add-Content -LiteralPath $mdPath
    if ($post.permalink_url) { "Permalink: $($post.permalink_url)" | Add-Content -LiteralPath $mdPath }
    "" | Add-Content -LiteralPath $mdPath

    if ($post.message) {
        $msg = [string]$post.message
        $msg = $msg -replace "\r?\n", "  `n"
        $msg | Add-Content -LiteralPath $mdPath
        "" | Add-Content -LiteralPath $mdPath
    }
    else {
        "(No text content)" | Add-Content -LiteralPath $mdPath
        "" | Add-Content -LiteralPath $mdPath
    }
}

Write-Host "Done. Export saved to: $pageDir"
Write-Host "Key outputs: page.json, posts.json, photos.json, videos.json, media-manifest.json, posts.md, media/"

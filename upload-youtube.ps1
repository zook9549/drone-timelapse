param(
  # ---- OAuth creds from OAuth Playground (JSON with client_id, client_secret, refresh_token, token_uri) ----
  [Parameter(Mandatory = $true)]
  [string]$AuthFile,                           # e.g. C:\keys\youtube-oauth-token.json

  # ---- New upload ----
  [Parameter(Mandatory = $true)]
  [string]$NewVideoFile,                       # path to the video to upload
  [ValidateSet('public','unlisted','private')]
  [string]$ReplacementPrivacyStatus = 'unlisted',
  [string]$ReplacementTitle,                   # default: filename (no extension)
  [string]$ReplacementDescription = "",
  [string[]]$ReplacementTags = @(),

  # ---- Old video to delete (choose one: VideoId OR LookupTag) ----
  [string]$VideoId,                            # explicit ID of old video to delete
  [string]$LookupTag                           # if provided, we search your channel uploads for a video whose tag matches this string
)

$ErrorActionPreference = 'Stop'

# ---------- Load OAuth Playground credentials & get access token ----------
if (-not (Test-Path $AuthFile)) { throw "Auth JSON not found: $AuthFile" }
$cfg = Get-Content -Raw -LiteralPath $AuthFile | ConvertFrom-Json
foreach ($k in 'client_id','client_secret','refresh_token','token_uri') {
  if (-not $cfg.$k) { throw "Missing '$k' in $AuthFile" }
}

function Get-AccessToken {
  param($cfg)
  $body = @{
    client_id     = $cfg.client_id
    client_secret = $cfg.client_secret
    refresh_token = $cfg.refresh_token
    grant_type    = "refresh_token"
  }
  $resp = Invoke-RestMethod -Method Post -Uri $cfg.token_uri -ContentType "application/x-www-form-urlencoded" -Body $body
  return $resp.access_token
}

$accessToken = Get-AccessToken -cfg $cfg
$authHeader  = @{ Authorization = "Bearer $accessToken" }

# ---------- YouTube API helpers ----------
function Get-Video([string]$id) {
  $u = "https://www.googleapis.com/youtube/v3/videos?part=snippet,status&id=$id"
  Invoke-RestMethod -Uri $u -Headers $authHeader -Method Get
}

function Start-Resumable([hashtable]$snippet, [hashtable]$status, [string]$mime="video/mp4", [long]$size) {
  $u = "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status"
  $headers = @{
    Authorization             = "Bearer $accessToken"
    "Content-Type"            = "application/json; charset=UTF-8"
    "X-Upload-Content-Type"   = $mime
    "X-Upload-Content-Length" = $size
  }
  $body = @{ snippet=$snippet; status=$status } | ConvertTo-Json -Depth 6
  $r = Invoke-WebRequest -Uri $u -Headers $headers -Method Post -Body $body -UseBasicParsing
  $r.Headers.Location
}

function Upload-Resumable([string]$sessionUrl, [string]$filePath, [string]$mime="video/mp4") {
  $size = (Get-Item $filePath).Length
  Invoke-WebRequest -Uri $sessionUrl -Method Put -Headers @{ "Content-Type"=$mime; "Content-Length"=$size } -InFile $filePath -UseBasicParsing
}

function Find-VideoIdByTag {
  param(
    [Parameter(Mandatory=$true)][string]$AccessToken,
    [Parameter(Mandatory=$true)][string]$Tag,
    [switch]$CaseInsensitive = $true
  )
  
  $tag = $Tag.Trim()
  $headers = @{ Authorization = "Bearer $AccessToken" }
  
  try {
    # Get uploads playlist ID
    $uploadsUrl = "https://www.googleapis.com/youtube/v3/channels?part=contentDetails&mine=true"
    $channelResp = Invoke-RestMethod -Uri $uploadsUrl -Headers $headers -Method Get
    
    if (-not $channelResp.items -or $channelResp.items.Count -eq 0) {
      Write-Warning "No channel found or channel has no uploads playlist"
      return $null
    }
    
    $uploadPlaylistId = $channelResp.items[0].contentDetails.relatedPlaylists.uploads
    
    $nextPage = $null
    do {
      # Get playlist items (up to 50 per page) - only need contentDetails for video IDs
      $playlistUrl = "https://www.googleapis.com/youtube/v3/playlistItems?part=contentDetails&playlistId=$uploadPlaylistId&maxResults=50"
      if ($nextPage) { $playlistUrl += "&pageToken=$nextPage" }
      
      $resp = Invoke-RestMethod -Uri $playlistUrl -Headers $headers -Method Get
      
      if (-not $resp.items -or $resp.items.Count -eq 0) { break }
      
      # Collect all video IDs from this page
      $videoIds = $resp.items | ForEach-Object { $_.contentDetails.videoId }
      
      # Batch request: Get details for all videos at once (up to 50 IDs per call)
      $batchUrl = "https://www.googleapis.com/youtube/v3/videos?part=snippet&id=$($videoIds -join ',')"
      $batchResp = Invoke-RestMethod -Uri $batchUrl -Headers $headers -Method Get
      
      # Search through the batch results
      foreach ($video in $batchResp.items) {
        $videoTags = $video.snippet.tags
        if ($videoTags) {
          $matchFound = if ($CaseInsensitive) {
            $videoTags | Where-Object { $_.Trim() -ieq $tag }
          } else {
            $videoTags | Where-Object { $_.Trim() -ceq $tag }
          }
          
          if ($matchFound) {
            $result = [PSCustomObject]@{
              Id          = $video.id
              Title       = $video.snippet.title
              Description = $video.snippet.description
              Tags        = $videoTags
            }
            Write-Host "✅ Found by tag '$tag': $($result.Id) — $($result.Title)"
            return $result
          }
        }
      }
      
      $nextPage = $resp.nextPageToken
    } while ($nextPage)
    
    return $null
    
  } catch {
    Write-Error "Failed to search for video by tag: $($_.Exception.Message)"
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      Write-Error $_.ErrorDetails.Message
    }
    return $null
  }
}

function Remove-YouTubeVideo {
  param(
    [Parameter(Mandatory=$true)][string]$AccessToken,
    [Parameter(Mandatory=$true)][string]$VideoId
  )
  $u = "https://www.googleapis.com/youtube/v3/videos?id=$VideoId"
  try {
    $resp = Invoke-WebRequest -Uri $u -Method Delete -Headers @{ Authorization = "Bearer $AccessToken" } -UseBasicParsing
    if ($resp.StatusCode -in 200,204) {
      Write-Host "✅ Deleted old video: $VideoId"
      return $true
    } else {
      Write-Host "Unexpected status deleting $VideoId $($resp.StatusCode)"
      return $false
    }
  } catch {
    Write-Host "⚠ Failed to delete $VideoId $($_.Exception.Message)" -ForegroundColor Yellow
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    return $false
  }
}

# ---------- Resolve old VideoId (optional) ----------
if (-not $VideoId -and $LookupTag) {
  $resolved = Find-VideoIdByTag -AccessToken $accessToken -Tag $LookupTag
  if ($resolved) { 
    $VideoId = $resolved.Id
    if (-not $ReplacementTitle) { $ReplacementTitle = $resolved.Title }
    if (-not $ReplacementDescription) { $ReplacementDescription = $resolved.Description }
    
    # Merge tags: combine ReplacementTags with resolved.Tags, removing duplicates
    if ($ReplacementTags -and $ReplacementTags.Count -gt 0) {
      $allTags = $ReplacementTags + $resolved.Tags
      $ReplacementTags = @($allTags | Select-Object -Unique)
    } else {
      $ReplacementTags = $resolved.Tags
    }
    
    Write-Host "Found video: $($resolved.Title)"
    Write-Host "Description: $($resolved.Description.Substring(0, [Math]::Min(100, $resolved.Description.Length)))..."
    Write-Host "Tags: $($resolved.Tags -join ', ')"
  } else { 
    Write-Host "No video found with tag '$LookupTag'." 
  }
}

# ---------- Upload new video ----------
if (-not (Test-Path $NewVideoFile)) { throw "New video file not found: $NewVideoFile" }
$size = (Get-Item $NewVideoFile).Length

if (-not $ReplacementTitle) { $ReplacementTitle = [IO.Path]::GetFileNameWithoutExtension($NewVideoFile) }
if (-not $ReplacementTags) { $ReplacementTags = [IO.Path]::GetFileNameWithoutExtension($NewVideoFile) }

$snippet = @{
  title       = $ReplacementTitle
  description = $ReplacementDescription
  tags        = $ReplacementTags
}
$status = @{ privacyStatus = $ReplacementPrivacyStatus }

Write-Host "=== DEBUG upload JSON ==="
Write-Host (@{ snippet=$snippet; status=$status } | ConvertTo-Json -Depth 6)
Write-Host "========================="

$session = Start-Resumable -snippet $snippet -status $status -size $size
if (-not $session) { throw "Failed to start resumable session." }

Write-Host "Uploading $([math]::Round($size/1MB)) MB …"
$up = Upload-Resumable -sessionUrl $session -filePath $NewVideoFile
$newObj = $up.Content | ConvertFrom-Json
$newId  = $newObj.id

Write-Host "✅ Uploaded new video: $newId"
Write-Host "URL: https://www.youtube.com/watch?v=$newId"

# ---------- Delete old video (if we have an ID) ----------
if ($VideoId) {
  # Optional safety step (commented): make private before delete
  # $null = Invoke-RestMethod -Uri "https://www.googleapis.com/youtube/v3/videos?part=status" `
  #   -Headers (@{Authorization="Bearer $accessToken"; "Content-Type"="application/json"}) `
  #   -Method Put -Body (@{ id=$VideoId; status=@{ privacyStatus="private" } } | ConvertTo-Json -Depth 4)

  $ok = Remove-YouTubeVideo -AccessToken $accessToken -VideoId $VideoId
  if (-not $ok) { Write-Host "Old video was not deleted. (New video remains: $newId)" -ForegroundColor Yellow }
} else {
  Write-Host "No old VideoId resolved; skipping deletion."
}

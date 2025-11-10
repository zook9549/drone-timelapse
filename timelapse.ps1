# PowerShell 7+ : GPS-synced segments + robust iterative merge (xfade + append tail)
param(
  [Parameter(Mandatory = $true)][string]$InputFolder,
  [int]$ClipLengthSec = 5,
  [double]$FadeDurationSec = 1,
  [int]$Fps = 30
)

$ErrorActionPreference = 'Stop'
$ci = [System.Globalization.CultureInfo]::InvariantCulture

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "$name not found in PATH" }
}
Require-Cmd ffmpeg
Require-Cmd ffprobe

# --- helpers ---
function Convert-HmsToSeconds([string]$hms) {
  if ($hms -match '^(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2}),(?<ms>\d{3})$') {
    $h=[int]$Matches.h; $m=[int]$Matches.m; $s=[int]$Matches.s; $ms=[int]$Matches.ms
    return ($h*3600 + $m*60 + $s + ($ms/1000.0))
  }
  throw "Bad SRT time format: $hms"
}
function Get-SrtPoints([string]$srtPath) {
  if (-not (Test-Path $srtPath)) { throw "Missing SRT: $srtPath" }
  $txt = Get-Content -LiteralPath $srtPath -Raw
  $blocks = ($txt -split "(\r?\n){2,}") | Where-Object { $_.Trim() -ne '' }

  $timeLineRx = [regex]'^\s*\d+\s*\r?\n\s*(?<t1>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<t2>\d{2}:\d{2}:\d{2},\d{3})'
  $labeledCoordRegex   = [regex]'lat(?:itude)?[:=\s]*([+\-]?\d{1,3}(?:\.\d+)?)\D+lon(?:gitude)?[:=\s]*([+\-]?\d{1,3}(?:\.\d+)?)'
  $unlabeledCoordRegex = [regex]'([+\-]?\d{1,3}(?:\.\d+)?)[\s,;]+([+\-]?\d{1,3}(?:\.\d+)?)'

  $pts = New-Object System.Collections.Generic.List[object]
  foreach ($b in $blocks) {
    $m = $timeLineRx.Match($b)
    if (-not $m.Success) { continue }
    $tStart = Convert-HmsToSeconds $m.Groups['t1'].Value
    $lines = ($b -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($lines.Count -lt 2) { continue }
    $payload = ($lines | Select-Object -Skip 2) -join ' '

    $lat=[double]::NaN; $lon=[double]::NaN
    $m1 = $labeledCoordRegex.Match($payload)
    if ($m1.Success) {
      $lat=[double]::Parse($m1.Groups[1].Value,$ci)
      $lon=[double]::Parse($m1.Groups[2].Value,$ci)
    } else {
      $m2 = $unlabeledCoordRegex.Match($payload)
      if ($m2.Success) {
        $lat=[double]::Parse($m2.Groups[1].Value,$ci)
        $lon=[double]::Parse($m2.Groups[2].Value,$ci)
      }
    }
    if ([double]::IsNaN($lat) -or [double]::IsNaN($lon)) { continue }
    if ($lat -lt -90 -or $lat -gt 90) { continue }
    if ($lon -lt -180 -or $lon -gt 180) { continue }
    $pts.Add([pscustomobject]@{ t=$tStart; lat=$lat; lon=$lon })
  }
  if ($pts.Count -lt 3) { throw "Too few GPS points: $srtPath" }
  return ($pts | Sort-Object t)
}
function Haversine([double]$lat1,[double]$lon1,[double]$lat2,[double]$lon2){
  $R = 6371000.0
  $toRad = [Math]::PI/180.0
  $dLat = ($lat2-$lat1)*$toRad
  $dLon = ($lon2-$lon1)*$toRad
  $a = [Math]::Sin($dLat/2)*[Math]::Sin($dLat/2) + [Math]::Cos($lat1*$toRad)*[Math]::Cos($lat2*$toRad)*[Math]::Sin($dLon/2)*[Math]::Sin($dLon/2)
  $c = 2*[Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1-$a))
  return $R*$c
}
function Get-PositionAtTime($pts,[double]$t){
  $best=$null; $bestd=[double]::PositiveInfinity
  foreach($p in $pts){ $d=[Math]::Abs($p.t-$t); if($d -lt $bestd){$bestd=$d; $best=$p} }
  return $best
}
function FindNearestTimeByPosition($pts,[double]$lat,[double]$lon,[double]$timeWindowStart,[double]$timeWindowEnd,[double]$maxDistMeters){
  $best=$null; $bestDist=[double]::PositiveInfinity
  foreach($p in $pts){
    # Only consider points within the time window
    if ($p.t -lt $timeWindowStart -or $p.t -gt $timeWindowEnd) { continue }
    
    $d = Haversine $lat $lon $($p.lat) $($p.lon)
    if($d -lt $bestDist){ $bestDist=$d; $best=$p }
  }
  
  # Only return if within max distance threshold
  if ($best -and $bestDist -le $maxDistMeters) {
    return @{ point=$best; distance=$bestDist }
  }
  return $null
}

function FindClipSegmentByStartEndPosition($pts,[double]$startLat,[double]$startLon,[double]$endLat,[double]$endLon,[double]$clipDuration,[double]$timeWindowStart,[double]$timeWindowEnd,[double]$maxDistMeters,[double]$maxTimingErrorSec){
  # Find clip segment where both start and end GPS coordinates match within thresholds
  # Returns best match based on combined start+end distance score
  
  $bestMatch = $null
  $bestScore = [double]::PositiveInfinity
  
  foreach($startPoint in $pts){
    # Only consider start points within the time window
    if ($startPoint.t -lt $timeWindowStart -or $startPoint.t -gt $timeWindowEnd) { continue }
    
    # Check if start position matches
    $startDist = Haversine $startLat $startLon $startPoint.lat $startPoint.lon
    if ($startDist -gt $maxDistMeters) { continue }
    
    # Calculate expected end time for this clip
    $expectedEndTime = $startPoint.t + $clipDuration
    
    # Find GPS position at the expected end time (allow some timing tolerance)
    $endPoint = Get-PositionAtTime $pts $expectedEndTime
    if (-not $endPoint) { continue }
    
    # Check timing tolerance - end point should be within acceptable time range
    $timingError = [Math]::Abs($endPoint.t - $expectedEndTime)
    if ($timingError -gt $maxTimingErrorSec) { continue }
    
    # Check if end position matches
    $endDist = Haversine $endLat $endLon $endPoint.lat $endPoint.lon
    if ($endDist -gt $maxDistMeters) { continue }
    
    # Calculate combined score (weighted sum of distances and timing error)
    # Lower score is better
    $combinedScore = $startDist + $endDist + ($timingError * 5.0)  # Weight timing error more heavily
    
    if ($combinedScore -lt $bestScore) {
      $bestScore = $combinedScore
      $bestMatch = @{
        startPoint = $startPoint
        endPoint = $endPoint
        startDistance = $startDist
        endDistance = $endDist
        timingError = $timingError
        clipStart = $startPoint.t
        clipEnd = $endPoint.t
        clipDuration = $endPoint.t - $startPoint.t
        combinedScore = $combinedScore
      }
    }
  }
  
  return $bestMatch
}
function Get-FormatDur([string]$path){
  $d = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $path
  [double]::Parse(($d.Trim()), $ci)
}
function Get-StreamDur([string]$path){
  $d = ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 $path
  if ($d -and $d.Trim() -match '^\d+(\.\d+)?$'){ return [double]::Parse($d.Trim(),$ci) }
  return $null
}
function Get-ExactDur([string]$path){
  $sd = Get-StreamDur $path
  if ($sd -and $sd -gt 0) { return $sd }
  return Get-FormatDur $path
}

# -------- Merge: xfade then append B's tail (iteratively) --------
function Merge-XfadeAppend([string]$a,[double]$aDur,[string]$b,[double]$bDur,[double]$fade,[int]$fps,[string]$out) {
  # Clamp fade duration
  $localFade = [Math]::Min($fade, [Math]::Min($aDur, $bDur) - 0.05)
  if ($localFade -lt 0.05) { $localFade = 0.05 }
  $offset    = [Math]::Max(0.001, $aDur - $localFade)

  $vf = "fps=$fps,format=yuv420p,setsar=1,settb=AVTB"
  $filter = "[0:v]$vf,setpts=PTS-STARTPTS[va]; " +
            "[1:v]$vf,setpts=PTS-STARTPTS[vb]; " +
            "[va][vb]xfade=transition=fade:duration=$localFade" + ":offset=$offset[v]"

  Write-Host "Filter graph:"
  Write-Host $filter

  # Try GPU encoding first (NVENC), fall back to fast CPU preset
  $encoderArgs = @("-c:v", "h264_nvenc", "-preset", "p4", "-cq", "23")
  
  $fargs = @(
    "-y",
    "-i", $a,
    "-i", $b,
    "-filter_complex", $filter,
    "-map", "[v]"
  ) + $encoderArgs + @(
    "-pix_fmt", "yuv420p", "-movflags", "+faststart",
    "-fps_mode", "vfr",
    $out
  )
  
  # Try with GPU encoding
  $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $fargs -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\ffmpeg_err.txt" 2>$null
  
  # If GPU encoding failed, retry with fast CPU preset
  if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne $null) {
    Write-Host "GPU encoding unavailable, using fast CPU preset..."
    $encoderArgs = @("-c:v", "libx264", "-preset", "faster", "-crf", "23")
    $fargs = @(
      "-y",
      "-i", $a,
      "-i", $b,
      "-filter_complex", $filter,
      "-map", "[v]"
    ) + $encoderArgs + @(
      "-pix_fmt", "yuv420p", "-movflags", "+faststart",
      "-fps_mode", "vfr",
      $out
    )
    ffmpeg $fargs
  }
  if (-not (Test-Path $out)) {
    throw "Merge failed: $out not created. Check ffmpeg filter graph and input files."
  }
  $newDur = Get-ExactDur $out
  if (-not $newDur -or $newDur -le 0) { $newDur = $aDur + $bDur - $localFade }
  return @{ Dur = $newDur; Fade = $localFade }
}

Write-Host "Input folder: $InputFolder"
if (-not (Test-Path -Path $InputFolder -PathType Container)) { throw "Input folder not found: $InputFolder" }

# Videos (oldest→newest)
$videos = Get-ChildItem -Path $InputFolder -Filter *.mp4 -File | Sort-Object LastWriteTime
if ($videos.Count -eq 0) { throw "No MP4 files found in $InputFolder" }
Write-Host "Found $($videos.Count) video(s)"

# SRT folder
$srtFolder = Join-Path (Split-Path $InputFolder -Parent) "srt"
if (-not (Test-Path $srtFolder)) { throw "SRT folder not found: $srtFolder" }

# Load metadata
$meta = @()
foreach($v in $videos){
  $base = [IO.Path]::GetFileNameWithoutExtension($v.Name)
  $srt  = Join-Path $srtFolder ($base + ".srt")
  Write-Host "Loading SRT for $($v.Name): $(Split-Path $srt -Leaf)"
  $pts  = Get-SrtPoints $srt
  $dur  = Get-FormatDur $v.FullName
  $srtMax = ($pts | Select-Object -Last 1).t
  $meta += [pscustomobject]@{ file=$v; name=$v.Name; points=$pts; duration=$dur; effectiveMax=[Math]::Min($dur,$srtMax) }
}

# Master = first
$master = $meta[0]
Write-Host "Master reference: $($master.name)"
$totalDuration = [math]::Floor([double]$master.effectiveMax)
Write-Host "Usable synced duration (master-bound): $totalDuration seconds"

# Output path
$outputFile = Join-Path (Split-Path $InputFolder -Parent) "$(Split-Path $InputFolder -Leaf).mp4"
Write-Host "Output file: $outputFile"

# temp dirs
$tempDir  = Join-Path $InputFolder "_temp_clips"
$mergeDir = Join-Path $InputFolder "_temp_merge"
foreach($d in @($tempDir,$mergeDir)){ if(Test-Path $d){Remove-Item -Recurse -Force $d}; New-Item -ItemType Directory -Force -Path $d | Out-Null }

# -------- Extract GPS-synced segments in round-robin fashion --------
$segments = New-Object System.Collections.Generic.List[object]
$extractedClipCount = 0  # Sequential counter for extracted clips only
$nextVideoIndex = 0      # Which video to try next (round-robin)
$masterTime = 0.0        # Current position in master timeline
$videoTimes = @{}        # Track current time position in each video
$lastUsedVideoIndex = 0  # Track last successfully used video for fallback
$previousClipEndGPS = $null  # Track GPS position where previous clip ended
$previousClipVideo = $null   # Track which video the previous clip came from
$previousClipEndTime = 0.0   # Track the time where previous clip ended in its video

foreach ($vmeta in $meta) {
  $videoTimes[$vmeta.name] = 0.0
}

Write-Host "`nExtracting GPS-synced clips in round-robin order..."
# Search window: +/- 5 seconds from expected start time
$searchWindowHalfSec = 5.0
$maxDistanceMeters = 30.0
$maxTimingErrorSec = 3.0  # Allow up to 3 seconds timing error for clip duration
$segmentAttempts = 0  # Safety counter

while ($masterTime -lt $totalDuration) {
  $segmentAttempts++
  if ($segmentAttempts -ge 500) { 
    Write-Host "Safety limit reached, stopping extraction"
    break 
  }
  
  # Determine target GPS coordinates based on whether this is first clip or continuation
  if ($extractedClipCount -eq 0) {
    # First clip: use master timeline
    $targetStartTime = $masterTime
    $targetStartPos = Get-PositionAtTime $master.points $targetStartTime
    $targetEndTime = [Math]::Min($targetStartTime + $ClipLengthSec, $totalDuration)
    $targetEndPos = Get-PositionAtTime $master.points $targetEndTime
    Write-Host ("`nSegment #1 (from master): Start GPS({0:N6}, {1:N6}) End GPS({2:N6}, {3:N6})" -f $targetStartPos.lat, $targetStartPos.lon, $targetEndPos.lat, $targetEndPos.lon)
  } else {
    # Subsequent clips: use GPS from where previous clip ended
    $targetStartPos = $previousClipEndGPS
    
    # Calculate expected end position from the PREVIOUS clip's video GPS data
    # This ensures we're following the same path as if the previous clip had continued
    $expectedEndTimeInPrevVideo = $previousClipEndTime + $ClipLengthSec
    $targetEndPos = Get-PositionAtTime $previousClipVideo.points $expectedEndTimeInPrevVideo
    
    Write-Host ("`nSegment #{0} (continuing from prev {1}): Start GPS({2:N6}, {3:N6}) End GPS({4:N6}, {5:N6})" -f ($extractedClipCount + 1), $previousClipVideo.name, $targetStartPos.lat, $targetStartPos.lon, $targetEndPos.lat, $targetEndPos.lon)
  }
  
  # Try to find a viable video using round-robin, searching all videos if needed
  $foundViableVideo = $false
  $triesRemaining = $meta.Count
  $selectedVideoIndex = -1
  $extractStart = 0.0
  $extractDuration = 0.0
  $actualEndTime = 0.0
  
  while ($triesRemaining -gt 0 -and -not $foundViableVideo) {
    $currentVideoIndex = $nextVideoIndex % $meta.Count
    $vmeta = $meta[$currentVideoIndex]
    
    Write-Host ("  Trying video {0}/{1}: {2}" -f ($currentVideoIndex+1), $meta.Count, $vmeta.name)
    
    # Find clip segment matching target start and end GPS positions
    # Start search window from where we left off in this video (to avoid reusing segments)
    $videoCurrentPos = $videoTimes[$vmeta.name]
    $expectedStart = [Math]::Max($videoCurrentPos, $masterTime)
    $searchWindowStart = [Math]::Max($videoCurrentPos, $expectedStart - $searchWindowHalfSec)
    $searchWindowEnd = [Math]::Min($vmeta.effectiveMax, $expectedStart + $searchWindowHalfSec)
    
    # Use enhanced matching that validates both start and end coordinates
    $clipMatch = FindClipSegmentByStartEndPosition $vmeta.points $targetStartPos.lat $targetStartPos.lon $targetEndPos.lat $targetEndPos.lon $ClipLengthSec $searchWindowStart $searchWindowEnd $maxDistanceMeters $maxTimingErrorSec
    
    if (-not $clipMatch) {
      Write-Host ("    No viable clip segment with matching start+end GPS (within {0}m, {1}s timing)" -f $maxDistanceMeters, $maxTimingErrorSec)
      $nextVideoIndex++
      $triesRemaining--
      continue
    }
    
    $extractStart = $clipMatch.clipStart
    $extractDuration = $clipMatch.clipDuration
    $extractDuration = [Math]::Max($extractDuration, 2.0)
    $actualEndTime = $clipMatch.clipEnd
    
    # Check bounds
    if ($extractStart -ge $vmeta.effectiveMax -or $extractDuration -lt 0.5) {
      Write-Host "    Video position exhausted or insufficient duration"
      $nextVideoIndex++
      $triesRemaining--
      continue
    }
    
    $foundViableVideo = $true
    $selectedVideoIndex = $currentVideoIndex
    Write-Host ("    Matched clip: start={0:N3}s end={1:N3}s dur={2:N3}s" -f $extractStart, $actualEndTime, $extractDuration)
    Write-Host ("      Start GPS distance: {0:N1}m, End GPS distance: {1:N1}m, Timing error: {2:N2}s" -f $clipMatch.startDistance, $clipMatch.endDistance, $clipMatch.timingError)
  }
  
  # If no viable video found after round-robin, use last successful video as fallback
  if (-not $foundViableVideo) {
    Write-Host "  No viable match in any video, using fallback to last used video"
    $selectedVideoIndex = $lastUsedVideoIndex
    $vmeta = $meta[$selectedVideoIndex]
    
    # Use the current position in the fallback video
    $extractStart = $videoTimes[$vmeta.name]
    $desiredEnd = [Math]::Min($extractStart + $ClipLengthSec, $vmeta.effectiveMax)
    $extractDuration = $desiredEnd - $extractStart
    $actualEndTime = $desiredEnd
    
    if ($extractStart -ge $vmeta.effectiveMax -or $extractDuration -lt 0.5) {
      Write-Host "  Fallback video also exhausted, stopping extraction"
      break
    }
    
    Write-Host ("    Fallback to {0} at t={1:N3}s dur={2:N3}s" -f $vmeta.name, $extractStart, $extractDuration)
  } else {
    # Update next video index for round-robin (move to next video for next segment)
    $nextVideoIndex = ($selectedVideoIndex + 1) % $meta.Count
    $lastUsedVideoIndex = $selectedVideoIndex
  }
  
  # Now we have a valid video selection, proceed with extraction
  $vmeta = $meta[$selectedVideoIndex]
  
  # Account for fade overlap on subsequent clips
  if ($extractedClipCount -gt 0) {
    $extractStart = [Math]::Max(0, $extractStart - $FadeDurationSec)
    $extractDuration = $extractDuration + $FadeDurationSec
  }
  
  # Final bounds check
  if ($extractStart + $extractDuration -gt $vmeta.effectiveMax) {
    $extractDuration = [Math]::Max(0.5, $vmeta.effectiveMax - $extractStart)
  }
  
  # Increment clip counter and create clip file
  $extractedClipCount++
  $clipFile = Join-Path $tempDir "clip_$($extractedClipCount.ToString('D4')).mp4"
  
  Write-Host ("  Extracting clip #{0}: {1} t={2:N3}s dur={3:N3}s" -f $extractedClipCount, $vmeta.name, $extractStart, $extractDuration)
  
  # Extract and normalize
  ffmpeg -y -ss $extractStart -i $vmeta.file.FullName -t $extractDuration `
         -vf ("fps={0},format=yuv420p,setsar=1,settb=AVTB" -f $Fps) `
         -vsync 0 -an -c:v libx264 -preset fast -crf 23 $clipFile 2>&1 | Out-Null
  
  if (Test-Path $clipFile) {
    $dur = Get-ExactDur $clipFile
    if (-not $dur -or $dur -le 0) { $dur = $extractDuration }
    $segments.Add([pscustomobject]@{ Path=$clipFile; Dur=[double]::Parse(("{0:N3}" -f $dur),$ci); Video=$vmeta.name })
    
    # Update video time tracker with actual end position (not fade-adjusted)
    $videoTimes[$vmeta.name] = $actualEndTime
    
    # Store the GPS position where this clip ended for next clip to sync to
    $previousClipEndGPS = Get-PositionAtTime $vmeta.points $actualEndTime
    $previousClipVideo = $vmeta
    $previousClipEndTime = $actualEndTime
    Write-Host ("  Clip end GPS: ({0:N6}, {1:N6}) at t={2:N3}s in {3}" -f $previousClipEndGPS.lat, $previousClipEndGPS.lon, $actualEndTime, $vmeta.name)
    
    # Advance master timeline (account for fade overlap)
    if ($extractedClipCount -eq 1) {
      $masterTime += $ClipLengthSec
    } else {
      $masterTime += ($ClipLengthSec - $FadeDurationSec)
    }
  } else {
    Write-Host "  Failed to extract clip, stopping"
    break
  }
  
  # Safety check
  if ($masterTime -ge $totalDuration -or $extractedClipCount -ge 200) { break }
}

Write-Host "`nTotal clips extracted: $($segments.Count)"
if ($segments.Count -lt 2) { throw "Not enough clips extracted for transitions." }

Write-Host "Merging iteratively…"
$currentPath = $segments[0].Path
$currentDur  = $segments[0].Dur
Write-Host ("  start A = {0:0.3}s  ({1})" -f $currentDur,(Split-Path $currentPath -Leaf))

for ($i=1; $i -lt $segments.Count; $i++) {
  $next = $segments[$i]
  $tmpOut = Join-Path $mergeDir ("m_" + $i.ToString('D4') + ".mp4")
  $res = Merge-XfadeAppend -a $currentPath -aDur $currentDur -b $next.Path -bDur $next.Dur -fade $FadeDurationSec -fps $Fps -out $tmpOut
  $currentPath = $tmpOut
  $currentDur  = $res.Dur
  Write-Host ("  merged #{0}: +{1:0.3}s (fade={2:0.3}s) => total ≈ {3:0.3}s" -f $i, $next.Dur, $res.Fade, $currentDur)
}

# Final copy (without audio first)
$outputFileNoAudio = Join-Path (Split-Path $InputFolder -Parent) "$(Split-Path $InputFolder -Leaf)_noaudio.mp4"
Copy-Item -LiteralPath $currentPath -Destination $outputFileNoAudio -Force

# -------- Add random MP3 audio overlay with looping and fade --------
Write-Host "`nAdding audio overlay..."
$musicFolder = Join-Path (Split-Path $InputFolder -Parent) "music"
$mp3Files = Get-ChildItem -Path $musicFolder -Filter *.mp3 -File

if ($mp3Files.Count -gt 0) {
  # Select random MP3
  $randomMp3 = $mp3Files | Get-Random
  Write-Host "Selected audio: $($randomMp3.Name)"
  
  # Get audio duration
  $audioDur = Get-FormatDur $randomMp3.FullName
  Write-Host "Audio duration: $($audioDur)s, Video duration: $($currentDur)s"
  
  # Calculate how many loops needed
  $loops = [Math]::Ceiling($currentDur / $audioDur)
  Write-Host "Audio will loop $loops time(s) to cover video duration"
  
  # Final output with audio
  $outputFile = Join-Path (Split-Path $InputFolder -Parent) "$(Split-Path $InputFolder -Leaf).mp4"
  
  # Build ffmpeg command with audio looping and 2-second fade in/out
  $fadeInDur = 2.0
  $fadeOutDur = 2.0
  $fadeOutStart = [Math]::Max(0, $currentDur - $fadeOutDur)
  
  $audioArgs = @(
    "-y",
    "-i", $outputFileNoAudio,
    "-stream_loop", "-1",
    "-i", $randomMp3.FullName,
    "-filter_complex", "[1:a]aloop=loop=$loops`:size=2e+09,atrim=end=$currentDur,afade=t=in:st=0:d=$fadeInDur,afade=t=out:st=$fadeOutStart`:d=$fadeOutDur[aout]",
    "-map", "0:v:0",
    "-map", "[aout]",
    "-c:v", "copy",
    "-c:a", "aac",
    "-b:a", "192k",
    "-shortest",
    $outputFile
  )
  
  Write-Host "Applying audio with fade in/out (2s each)..."
  ffmpeg $audioArgs 2>&1 | Out-Null
  
  if (Test-Path $outputFile) {
    Write-Host ("`nDone! Output with audio: {0}  (≈ {1:0.1}s, segments={2}, fade={3}s, fps={4})" -f $outputFile, $currentDur, $segments.Count, $FadeDurationSec, $Fps)
    # Clean up intermediate file
    Remove-Item -LiteralPath $outputFileNoAudio -Force
  } else {
    Write-Host "Audio overlay failed, keeping video without audio: $outputFileNoAudio"
    Copy-Item -LiteralPath $outputFileNoAudio -Destination $outputFile -Force
  }
} else {
  Write-Host "No MP3 files found in $musicFolder, skipping audio overlay"
  $outputFile = Join-Path (Split-Path $InputFolder -Parent) "$(Split-Path $InputFolder -Leaf).mp4"
  Copy-Item -LiteralPath $outputFileNoAudio -Destination $outputFile -Force
}

Write-Host "Final merged file: $outputFile"
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $outputFile

Write-Host "`nTo upload to YouTube, use: .\upload-youtube.ps1 -VideoFile '$outputFile' -YouTubeVideoId 'YOUR_VIDEO_ID' -YouTubeAccessToken 'YOUR_TOKEN'"

# Keep temps for inspection; uncomment to clean:
# Remove-Item -Recurse -Force $tempDir,$mergeDir

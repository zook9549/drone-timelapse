<#
.SYNOPSIS
    Creates GPS-synced timelapse videos from multiple dashcam recordings with crossfade transitions.

.DESCRIPTION
    This script processes multiple MP4 video files with corresponding SRT GPS data files to create
    a synchronized timelapse video. It extracts clips from multiple videos in round-robin fashion,
    matches GPS coordinates for seamless transitions, applies crossfade effects, and adds optional
    audio overlay from a random MP3 file.

.PARAMETER InputFolder
    Path to the folder containing MP4 video files and corresponding SRT files with GPS data.

.PARAMETER ClipLengthSec
    Length of each extracted clip in seconds. Default is 5 seconds.
    Valid range: 1-60 seconds.

.PARAMETER FadeDurationSec
    Duration of crossfade transition between clips in seconds. Default is 1 second.
    Valid range: 0.1-5.0 seconds.

.PARAMETER Fps
    Target frames per second for the output video. Default is 30.
    Valid range: 15-60 fps.

.PARAMETER KeepTemps
    If specified, temporary directories will be kept after processing for debugging.

.PARAMETER MasterVideo
    Name of the video file to use as the master reference (e.g., 'video1.mp4').
    If not specified, uses the first video by date/time. The master video determines
    the GPS timeline that other videos will match against.

.EXAMPLE
    .\timelapse.ps1 -InputFolder "C:\Videos\Trip01"
    
    Creates a timelapse from videos in Trip01 folder with default settings.

.EXAMPLE
    .\timelapse.ps1 -InputFolder "C:\Videos\Trip01" -ClipLengthSec 3 -FadeDurationSec 0.5 -Fps 60
    
    Creates a timelapse with 3-second clips, 0.5-second fades, at 60fps.

.EXAMPLE
    .\timelapse.ps1 -InputFolder "C:\Videos\Trip01" -MasterVideo "GX010123.mp4"
    
    Creates a timelapse using GX010123.mp4 as the master reference video.

.NOTES
    Requires: FFmpeg and FFprobe in PATH
    PowerShell: 7.0 or higher
    Video Format: MP4 files with corresponding .srt GPS data files
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to folder containing MP4 and SRT files")]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Container)) {
            throw "Input folder not found: $_"
        }
        $true
    })]
    [string]$InputFolder,

    [Parameter(HelpMessage = "Length of each clip in seconds (1-60)")]
    [ValidateRange(1, 60)]
    [int]$ClipLengthSec = 5,

    [Parameter(HelpMessage = "Crossfade duration in seconds (0.1-5.0)")]
    [ValidateRange(0.1, 5.0)]
    [double]$FadeDurationSec = 1,

    [Parameter(HelpMessage = "Output video frame rate (15-60)")]
    [ValidateRange(15, 60)]
    [int]$Fps = 30,

    [Parameter(HelpMessage = "Keep temporary files for debugging")]
    [switch]$KeepTemps,

    [Parameter(HelpMessage = "Name of the video file to use as master reference (e.g., 'video1.mp4'). If not specified, uses the first video by date/time.")]
    [string]$MasterVideo
)

#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$ci = [System.Globalization.CultureInfo]::InvariantCulture

# Import shared GPS scoring functions
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptPath "GpsScoring.ps1")

# ============================================================================
# CONFIGURATION CONSTANTS
# ============================================================================

$Script:Config = @{
    # GPS matching thresholds
    MaxDistanceMeters     = 30.0    # Maximum distance in meters for GPS coordinate matching
    SearchWindowHalfSec   = 10.0     # Time window half-width for searching GPS points (seconds)
    MaxTimingErrorSec     = 10.0     # Maximum allowed timing error for clip duration matching
    
    # Safety limits
    MaxClipCount          = 200     # Maximum number of clips to extract
    MaxSegmentAttempts    = 500     # Maximum extraction attempts before stopping
    MinClipDuration       = 0.5     # Minimum viable clip duration (seconds)
    MinExtractDuration    = 2.0     # Minimum duration for extracted segments
    
    # Audio settings
    AudioFadeInDuration   = 2.0     # Audio fade in duration (seconds)
    AudioFadeOutDuration  = 2.0     # Audio fade out duration (seconds)
    AudioBitrate          = '192k'  # Audio encoding bitrate
    
    # Video encoding
    EncoderGPU            = 'h264_nvenc'  # NVIDIA GPU encoder
    EncoderCPU            = 'libx264'     # CPU fallback encoder
    PresetGPU             = 'p4'          # GPU encoding preset
    PresetCPU             = 'faster'      # CPU encoding preset
    CRF                   = 18            # Constant Rate Factor for quality (18 = visually lossless)
    
    # Validation
    MinGPSPoints          = 3       # Minimum GPS points required in SRT file
    MinClipsForMerge      = 2       # Minimum clips needed for merging
    
    # GPS coordinate validation
    MinLatitude           = -90.0
    MaxLatitude           = 90.0
    MinLongitude          = -180.0
    MaxLongitude          = 180.0
}

# ============================================================================
# HELPER FUNCTIONS - VALIDATION & UTILITIES
# ============================================================================

function Assert-CommandExists {
    <#
    .SYNOPSIS
        Validates that a required command is available in PATH.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )
    
    Write-Verbose "Checking for command: $CommandName"
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command not found in PATH: $CommandName. Please install it first."
    }
    Write-Verbose "  ✓ Found: $CommandName"
}

function Assert-FileExists {
    <#
    .SYNOPSIS
        Validates that a file exists, throwing descriptive error if not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$Description
    )
    
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }
}

function Invoke-FFmpegWithFallback {
    <#
    .SYNOPSIS
        Executes FFmpeg with GPU encoding, falling back to CPU if GPU unavailable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InputArgs,
        
        [Parameter(Mandatory = $false)]
        [string[]]$FilterArgs = @(),
        
        [Parameter(Mandatory = $true)]
        [string[]]$OutputArgs,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $false)]
        [string]$Description = "FFmpeg operation"
    )
    
    Write-Verbose "Starting $Description"
    
    $errorLogPath = Join-Path $env:TEMP "ffmpeg_error_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $batchFile = Join-Path $env:TEMP "ffmpeg_cmd_$(Get-Date -Format 'yyyyMMdd_HHmmss').cmd"
    
    # Try GPU encoding first
    Write-Verbose "  Attempting GPU encoding (NVENC)..."
    
    # Build command for batch file (no PowerShell escaping issues)
    $batchContent = "@echo off`r`n"
    $batchContent += "ffmpeg"
    foreach ($arg in $InputArgs) {
        # Don't quote switches, only values
        if ($arg.StartsWith('-')) {
            $batchContent += " $arg"
        } else {
            $batchContent += " `"$arg`""
        }
    }
    foreach ($arg in $FilterArgs) {
        if ($arg.StartsWith('-')) {
            $batchContent += " $arg"
        } else {
            $batchContent += " `"$arg`""
        }
    }
    $batchContent += " -c:v $($Script:Config.EncoderGPU)"
    $batchContent += " -preset $($Script:Config.PresetGPU)"
    $batchContent += " -cq $($Script:Config.CRF)"
    foreach ($arg in $OutputArgs) {
        if ($arg.StartsWith('-')) {
            $batchContent += " $arg"
        } else {
            $batchContent += " `"$arg`""
        }
    }
    $batchContent += " `"$OutputPath`""
    $batchContent += " 2> `"$errorLogPath`""
    
    Set-Content -Path $batchFile -Value $batchContent -Encoding ASCII
    Write-Verbose "  Batch file: $batchFile"
    
    try {
        & cmd /c $batchFile
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0 -and (Test-Path $OutputPath)) {
            Write-Verbose "  ✓ GPU encoding successful"
            Remove-Item $batchFile -ErrorAction SilentlyContinue
            return $true
        }
        
        # GPU encoding failed, show why
        if (Test-Path $errorLogPath) {
            $gpuError = Get-Content $errorLogPath -Raw
            Write-Warning "GPU encoding failed with exit code $exitCode"
            if ($gpuError -match "No NVENC capable devices found") {
                Write-Warning "  Reason: No NVIDIA GPU detected or NVENC not available"
                Write-Warning "  Solution: Install latest NVIDIA drivers or use a GPU that supports NVENC"
            } elseif ($gpuError -match "Cannot load nvcuda.dll") {
                Write-Warning "  Reason: NVIDIA CUDA library not found"
                Write-Warning "  Solution: Install latest NVIDIA drivers"
            } elseif ($gpuError -match "Unrecognized option") {
                Write-Warning "  Reason: Your FFmpeg build doesn't support h264_nvenc"
                Write-Warning "  Solution: Install FFmpeg with NVENC support"
            } else {
                Write-Verbose "  GPU Error details: $($gpuError.Substring(0, [Math]::Min(500, $gpuError.Length)))"
            }
        }
    } catch {
        Write-Verbose "  GPU encoding failed: $($_.Exception.Message)"
    }
    
    # Fall back to CPU encoding
    Write-Warning "Falling back to CPU encoding (this will be slower)..."
    Write-Verbose "  Attempting CPU encoding..."
    
    $batchContent = "@echo off`r`n"
    $batchContent += "ffmpeg"
    foreach ($arg in $InputArgs) {
        if ($arg.StartsWith('-')) {
            $batchContent += " $arg"
        } else {
            $batchContent += " `"$arg`""
        }
    }
    foreach ($arg in $FilterArgs) {
        if ($arg.StartsWith('-')) {
            $batchContent += " $arg"
        } else {
            $batchContent += " `"$arg`""
        }
    }
    $batchContent += " -c:v $($Script:Config.EncoderCPU)"
    $batchContent += " -preset $($Script:Config.PresetCPU)"
    $batchContent += " -crf $($Script:Config.CRF)"
    foreach ($arg in $OutputArgs) {
        if ($arg.StartsWith('-')) {
            $batchContent += " $arg"
        } else {
            $batchContent += " `"$arg`""
        }
    }
    $batchContent += " `"$OutputPath`""
    $batchContent += " 2> `"$errorLogPath`""
    
    Set-Content -Path $batchFile -Value $batchContent -Encoding ASCII
    Write-Verbose "  Batch file: $batchFile"
    
    & cmd /c $batchFile
    $exitCode = $LASTEXITCODE
    
    Remove-Item $batchFile -ErrorAction SilentlyContinue
    
    if ($exitCode -ne 0 -or -not (Test-Path $OutputPath)) {
        $errorContent = if (Test-Path $errorLogPath) { Get-Content $errorLogPath -Raw } else { "No error log available" }
        throw "$Description failed. Exit code: $exitCode`nError log: $errorLogPath`n$errorContent"
    }
    
    Write-Verbose "  ✓ CPU encoding successful"
    return $true
}

# ============================================================================
# HELPER FUNCTIONS - TIME & GPS PARSING
# ============================================================================

function Convert-HmsToSeconds {
    <#
    .SYNOPSIS
        Converts SRT timestamp (HH:MM:SS,mmm) to seconds.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Timestamp
    )
    
    if ($Timestamp -match '^(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2}),(?<ms>\d{3})$') {
        $hours = [int]$Matches.h
        $minutes = [int]$Matches.m
        $seconds = [int]$Matches.s
        $milliseconds = [int]$Matches.ms
        
        return ($hours * 3600 + $minutes * 60 + $seconds + ($milliseconds / 1000.0))
    }
    
    throw "Invalid SRT timestamp format: '$Timestamp'. Expected format: HH:MM:SS,mmm"
}

function Get-SrtGpsPoints {
    <#
    .SYNOPSIS
        Parses GPS coordinates from SRT subtitle file.
    .DESCRIPTION
        Extracts time-stamped GPS coordinates from SRT files, supporting both labeled
        (latitude:, longitude:) and unlabeled (lat, lon) coordinate formats.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SrtPath
    )
    
    Assert-FileExists -Path $SrtPath -Description "SRT file"
    
    Write-Verbose "Parsing GPS data from: $(Split-Path $SrtPath -Leaf)"
    
    try {
        $content = Get-Content -LiteralPath $SrtPath -Raw -ErrorAction Stop
        $blocks = ($content -split '(\r?\n){2,}') | Where-Object { $_.Trim() -ne '' }
        
        # Regex patterns for SRT parsing
        $timeLinePattern = [regex]'^\s*\d+\s*\r?\n\s*(?<t1>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<t2>\d{2}:\d{2}:\d{2},\d{3})'
        $labeledCoordPattern = [regex]'lat(?:itude)?[:=\s]*([+\-]?\d{1,3}(?:\.\d+)?)\D+lon(?:gitude)?[:=\s]*([+\-]?\d{1,3}(?:\.\d+)?)'
        $unlabeledCoordPattern = [regex]'([+\-]?\d{1,3}(?:\.\d+)?)[\s,;]+([+\-]?\d{1,3}(?:\.\d+)?)'
        
        $points = New-Object System.Collections.Generic.List[object]
        $skippedCount = 0
        
        foreach ($block in $blocks) {
            # Extract timestamp
            $timeMatch = $timeLinePattern.Match($block)
            if (-not $timeMatch.Success) { continue }
            
            $timestamp = Convert-HmsToSeconds $timeMatch.Groups['t1'].Value
            
            # Extract text payload
            $lines = ($block -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            if ($lines.Count -lt 2) { continue }
            
            $payload = ($lines | Select-Object -Skip 2) -join ' '
            
            # Try to parse GPS coordinates (labeled format first, then unlabeled)
            $lat = [double]::NaN
            $lon = [double]::NaN
            
            $coordMatch = $labeledCoordPattern.Match($payload)
            if ($coordMatch.Success) {
                $lat = [double]::Parse($coordMatch.Groups[1].Value, $ci)
                $lon = [double]::Parse($coordMatch.Groups[2].Value, $ci)
            } else {
                $coordMatch = $unlabeledCoordPattern.Match($payload)
                if ($coordMatch.Success) {
                    $lat = [double]::Parse($coordMatch.Groups[1].Value, $ci)
                    $lon = [double]::Parse($coordMatch.Groups[2].Value, $ci)
                }
            }
            
            # Validate coordinates
            if ([double]::IsNaN($lat) -or [double]::IsNaN($lon)) {
                $skippedCount++
                continue
            }
            
            if ($lat -lt $Script:Config.MinLatitude -or $lat -gt $Script:Config.MaxLatitude) {
                Write-Warning "Invalid latitude $lat at time $timestamp, skipping"
                $skippedCount++
                continue
            }
            
            if ($lon -lt $Script:Config.MinLongitude -or $lon -gt $Script:Config.MaxLongitude) {
                Write-Warning "Invalid longitude $lon at time $timestamp, skipping"
                $skippedCount++
                continue
            }
            
            $points.Add([pscustomobject]@{ 
                t = $timestamp
                lat = $lat
                lon = $lon
            })
        }
        
        if ($skippedCount -gt 0) {
            Write-Verbose "  Skipped $skippedCount invalid GPS entries"
        }
        
        if ($points.Count -lt $Script:Config.MinGPSPoints) {
            throw "Insufficient GPS points in SRT file: $SrtPath (found $($points.Count), need at least $($Script:Config.MinGPSPoints))"
        }
        
        $sortedPoints = $points | Sort-Object t
        Write-Verbose "  ✓ Parsed $($sortedPoints.Count) GPS points (time range: $($sortedPoints[0].t)s - $($sortedPoints[-1].t)s)"
        
        return $sortedPoints
    } catch {
        throw "Failed to parse SRT file '$SrtPath': $($_.Exception.Message)"
    }
}

# Note: GPS calculation functions (Get-HaversineDistance, Get-NearestGpsPoint, Find-GpsMatchingClipSegment)
# are now imported from GpsScoring.ps1

# ============================================================================
# HELPER FUNCTIONS - VIDEO OPERATIONS
# ============================================================================

function Get-VideoFormatDuration {
    <#
    .SYNOPSIS
        Gets video duration from format metadata using ffprobe.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath
    )
    
    try {
        $output = ffprobe -v error -show_entries format=duration `
            -of default=noprint_wrappers=1:nokey=1 $VideoPath 2>&1
        
        $durationStr = $output | Out-String
        return [double]::Parse($durationStr.Trim(), $ci)
    } catch {
        throw "Failed to get format duration for '$VideoPath': $($_.Exception.Message)"
    }
}

function Get-VideoStreamDuration {
    <#
    .SYNOPSIS
        Gets video duration from stream metadata using ffprobe.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath
    )
    
    try {
        $output = ffprobe -v error -select_streams v:0 -show_entries stream=duration `
            -of csv=p=0 $VideoPath 2>&1
        
        $durationStr = $output | Out-String
        if ($durationStr -and $durationStr.Trim() -match '^\d+(\.\d+)?$') {
            return [double]::Parse($durationStr.Trim(), $ci)
        }
        return $null
    } catch {
        Write-Verbose "Could not get stream duration for '$VideoPath': $($_.Exception.Message)"
        return $null
    }
}

function Get-VideoExactDuration {
    <#
    .SYNOPSIS
        Gets most accurate video duration, trying stream then format metadata.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath
    )
    
    $streamDuration = Get-VideoStreamDuration -VideoPath $VideoPath
    if ($streamDuration -and $streamDuration -gt 0) {
        return $streamDuration
    }
    
    return Get-VideoFormatDuration -VideoPath $VideoPath
}

function Merge-VideosWithCrossfade {
    <#
    .SYNOPSIS
        Merges two video clips with crossfade transition.
    .DESCRIPTION
        Applies crossfade transition between two videos using FFmpeg's xfade filter,
        with automatic GPU/CPU encoding fallback.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoA,
        
        [Parameter(Mandatory = $true)]
        [double]$DurationA,
        
        [Parameter(Mandatory = $true)]
        [string]$VideoB,
        
        [Parameter(Mandatory = $true)]
        [double]$DurationB,
        
        [Parameter(Mandatory = $true)]
        [double]$FadeDuration,
        
        [Parameter(Mandatory = $true)]
        [int]$Fps,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )
    
    # Clamp fade duration to safe limits
    $minDuration = [Math]::Min($DurationA, $DurationB)
    $localFade = [Math]::Min($FadeDuration, $minDuration - 0.05)
    if ($localFade -lt 0.05) {
        $localFade = 0.05
    }
    
    $offset = [Math]::Max(0.001, $DurationA - $localFade)
    
    # Build filter complex
    $videoFilter = "fps=$Fps,format=yuv420p,setsar=1,settb=AVTB"
    $filterComplex = "[0:v]$videoFilter,setpts=PTS-STARTPTS[va]; " +
                     "[1:v]$videoFilter,setpts=PTS-STARTPTS[vb]; " +
                     "[va][vb]xfade=transition=fade:duration=$localFade" + ":offset=$offset[v]"
    Write-Verbose "Merging videos with crossfade:"
    Write-Verbose "  A: $(Split-Path $VideoA -Leaf) ($($DurationA)s)"
    Write-Verbose "  B: $(Split-Path $VideoB -Leaf) ($($DurationB)s)"
    Write-Verbose "  Fade: $($localFade)s at offset $($offset)s"
    
    # Build FFmpeg arguments in separate groups
    $inputArgs = @(
        '-y',
        '-i', $VideoA,
        '-i', $VideoB
    )
    
    $filterArgs = @(
        '-filter_complex', $filterComplex,
        '-map', '[v]'
    )
    
    $outputArgs = @(
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart',
        '-fps_mode', 'vfr'
    )
    
    # For intermediate merges, use high quality encoding
    Write-Verbose "  Using high quality H.264 for intermediate merge"
    
    # Use batch file approach to avoid argument escaping issues with complex filter strings
    $batchFile = Join-Path $env:TEMP "ffmpeg_merge_$(Get-Date -Format 'yyyyMMdd_HHmmss').cmd"
    $errorLog = Join-Path $env:TEMP "ffmpeg_merge_error.txt"
    
    $batchContent = "@echo off`r`n"
    $batchContent += "ffmpeg -y"
    $batchContent += " -i `"$VideoA`""
    $batchContent += " -i `"$VideoB`""
    $batchContent += " -filter_complex `"$filterComplex`""
    $batchContent += " -map `"[v]`""
    $batchContent += " -pix_fmt yuv420p"
    $batchContent += " -c:v libx264"
    $batchContent += " -preset veryfast"
    $batchContent += " -crf 18"
    $batchContent += " -movflags +faststart"
    $batchContent += " -fps_mode vfr"
    $batchContent += " `"$OutputPath`""
    $batchContent += " 2> `"$errorLog`""
    
    Set-Content -Path $batchFile -Value $batchContent -Encoding ASCII
    
    & cmd /c $batchFile
    $exitCode = $LASTEXITCODE
    
    Remove-Item $batchFile -ErrorAction SilentlyContinue
    
    if ($exitCode -ne 0 -or -not (Test-Path $OutputPath)) {
        $errorContent = if (Test-Path $errorLog) { Get-Content $errorLog -Raw } else { "No error log" }
        throw "Video merge with crossfade failed. Exit code: $exitCode`nError: $errorContent"
    }
    
    Remove-Item $errorLog -ErrorAction SilentlyContinue
    
    # Get final duration
    $newDuration = Get-VideoExactDuration -VideoPath $OutputPath
    if (-not $newDuration -or $newDuration -le 0) {
        $newDuration = $DurationA + $DurationB - $localFade
    }
    
    Write-Verbose "  ✓ Merged video duration: $($newDuration)s"
    
    return @{
        Dur = $newDuration
        Fade = $localFade
    }
}

# ============================================================================
# MAIN SCRIPT EXECUTION
# ============================================================================

try {
    Write-Host "`n=== GPS-Synced Timelapse Creator ===" -ForegroundColor Cyan
    Write-Host "Input folder: $InputFolder"
    
    # Validate required commands
    Write-Verbose "Validating required tools..."
    Assert-CommandExists -CommandName 'ffmpeg'
    Assert-CommandExists -CommandName 'ffprobe'
    
    # Find and validate video files
    Write-Host "`nScanning for video files..."
    $videoFiles = Get-ChildItem -Path $InputFolder -Filter '*.mp4' -File | Sort-Object LastWriteTime
    
    if ($videoFiles.Count -eq 0) {
        throw "No MP4 files found in folder: $InputFolder"
    }
    
    Write-Host "Found $($videoFiles.Count) video file(s)" -ForegroundColor Green
    
    # Load video metadata and GPS data
    Write-Host "`nLoading GPS metadata..."
    $videoMetadata = New-Object System.Collections.Generic.List[object]
    
    foreach ($video in $videoFiles) {
        $videoName = $video.Name
        $baseName = [IO.Path]::GetFileNameWithoutExtension($videoName)
        $srtPath = Join-Path $InputFolder "$baseName.srt"
        
        Write-Verbose "Processing: $videoName"
        
        try {
            $gpsPoints = Get-SrtGpsPoints -SrtPath $srtPath
            $duration = Get-VideoFormatDuration -VideoPath $video.FullName
            $maxGpsTime = ($gpsPoints | Select-Object -Last 1).t
            $effectiveMax = [Math]::Min($duration, $maxGpsTime)
            
            $videoMetadata.Add([pscustomobject]@{
                File         = $video
                Name         = $videoName
                GpsPoints    = $gpsPoints
                Duration     = $duration
                EffectiveMax = $effectiveMax
            })
            
            Write-Host "  ✓ $videoName - Duration: $($duration)s, GPS points: $($gpsPoints.Count)" -ForegroundColor Gray
        } catch {
            Write-Warning "Failed to load metadata for $videoName`: $($_.Exception.Message)"
            Write-Warning "Skipping this video."
        }
    }
    
    if ($videoMetadata.Count -eq 0) {
        throw "No valid video files with GPS data found."
    }
    
    # Select master reference video
    if ($MasterVideo) {
        Write-Verbose "Looking for specified master video: $MasterVideo"
        
        # Debug: show what we're searching for
        Write-Verbose "Searching in $($videoMetadata.Count) loaded videos"
        foreach ($v in $videoMetadata) {
            Write-Verbose "  Available: '$($v.Name)'"
        }
        
        # Find the matching video using explicit loop to avoid pipeline issues
        # IMPORTANT: Use different variable name to avoid PowerShell case-insensitive collision with $MasterVideo parameter!
        $selectedMasterVideo = $null
        $searchName = $MasterVideo  # Create local copy to avoid any parameter issues
        Write-Verbose "Searching for: '$searchName'"
        
        foreach ($v in $videoMetadata) {
            Write-Verbose "  Comparing '$($v.Name)' with '$searchName'"
            if ($v.Name -eq $searchName) {
                Write-Verbose "  MATCH FOUND!"
                $selectedMasterVideo = $v
                break
            }
        }
        
        if (-not $selectedMasterVideo) {
            Write-Warning "Specified master video '$searchName' not found in the loaded videos."
            Write-Warning "Available videos:"
            foreach ($v in $videoMetadata) {
                Write-Warning "  - $($v.Name)"
            }
            throw "Master video not found: $searchName"
        }
        Write-Host "`nUsing specified master reference: $($selectedMasterVideo.Name)" -ForegroundColor Cyan
    } else {
        # Use first video (by date/time) as master reference
        $selectedMasterVideo = $videoMetadata[0]
        Write-Host "`nUsing first video as master reference: $($selectedMasterVideo.Name)" -ForegroundColor Cyan
    }
    
    # Validate master video has required data
    if (-not $selectedMasterVideo) {
        throw "Master video object is null"
    }
    
    if (-not $selectedMasterVideo.Name) {
        Write-Warning "Master video Name property is empty or null"
        Write-Warning "Master video type: $($selectedMasterVideo.GetType().FullName)"
        Write-Warning "Master video properties: $($selectedMasterVideo | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name)"
        throw "Invalid master video object - Name is empty"
    }
    
    if ($selectedMasterVideo.EffectiveMax -le 0) {
        Write-Warning "Master video '$($selectedMasterVideo.Name)' has invalid EffectiveMax: $($selectedMasterVideo.EffectiveMax)"
        Write-Warning "  Duration: $($selectedMasterVideo.Duration)"
        Write-Warning "  GPS Points: $($selectedMasterVideo.GpsPoints.Count)"
        throw "Invalid master video object - EffectiveMax is $($selectedMasterVideo.EffectiveMax)"
    }
    
    $totalDuration = [Math]::Floor($selectedMasterVideo.EffectiveMax)
    Write-Host "Usable duration: $totalDuration seconds"
    
    # Setup output paths
    $outputBaseName = Split-Path $InputFolder -Leaf
    $outputFolder = Split-Path $InputFolder -Parent
    $outputFile = Join-Path $outputFolder "$outputBaseName.mp4"
    
    Write-Host "Output file: $outputFile"
    
    # Create temporary directories
    $tempClipsDir = Join-Path $InputFolder '_temp_clips'
    $tempMergeDir = Join-Path $InputFolder '_temp_merge'
    
    Write-Verbose "Creating temporary directories..."
    foreach ($dir in @($tempClipsDir, $tempMergeDir)) {
        if (Test-Path $dir) {
            Remove-Item -Recurse -Force $dir
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    
    # ============================================================================
    # CLIP EXTRACTION PHASE
    # ============================================================================
    
    Write-Host "`n=== Extracting GPS-Synced Clips ===" -ForegroundColor Cyan
    
    $extractedClips = New-Object System.Collections.Generic.List[object]
    $clipCounter = 0
    $masterTimePosition = 0.0
    $videoTimePositions = @{}
    $previousClipEndGps = $null
    $previousClipVideo = $null
    $previousClipEndTime = 0.0
    
    # Initialize time tracking for each video
    foreach ($vmeta in $videoMetadata) {
        $videoTimePositions[$vmeta.Name] = 0.0
    }
    
    # Start round-robin with the master video
    $masterVideoIndex = 0
    for ($i = 0; $i -lt $videoMetadata.Count; $i++) {
        if ($videoMetadata[$i].Name -eq $selectedMasterVideo.Name) {
            $masterVideoIndex = $i
            break
        }
    }
    $roundRobinIndex = $masterVideoIndex
    $lastUsedVideoIndex = $masterVideoIndex
    
    Write-Verbose "Round-robin starting with video index $masterVideoIndex ($($selectedMasterVideo.Name))"
    
    $attemptCounter = 0
    
    while ($masterTimePosition -lt $totalDuration) {
        $attemptCounter++
        if ($attemptCounter -ge $Script:Config.MaxSegmentAttempts) {
            Write-Warning "Reached maximum segment attempts ($($Script:Config.MaxSegmentAttempts)), stopping extraction"
            break
        }
        
        # Determine target GPS coordinates
        if ($clipCounter -eq 0) {
            # First clip: use master timeline
            $targetStartPos = Get-NearestGpsPoint -GpsPoints $selectedMasterVideo.GpsPoints -TargetTime $masterTimePosition
            $targetEndTime = [Math]::Min($masterTimePosition + $ClipLengthSec, $totalDuration)
            $targetEndPos = Get-NearestGpsPoint -GpsPoints $selectedMasterVideo.GpsPoints -TargetTime $targetEndTime
            
            Write-Host "`nClip #1 (from master): GPS Start($($targetStartPos.lat.ToString('N6')), $($targetStartPos.lon.ToString('N6'))) End($($targetEndPos.lat.ToString('N6')), $($targetEndPos.lon.ToString('N6')))"
        } else {
            # Subsequent clips: use master video timeline to prevent error cascading
            $targetStartPos = $previousClipEndGps
            # Calculate target end time from master timeline (not previous clip's video)
            $targetEndTime = [Math]::Min($masterTimePosition + $ClipLengthSec, $totalDuration)
            $targetEndPos = Get-NearestGpsPoint -GpsPoints $selectedMasterVideo.GpsPoints -TargetTime $targetEndTime
            
            Write-Host "`nClip #$($clipCounter + 1) (from master timeline): GPS Start($($targetStartPos.lat.ToString('N6')), $($targetStartPos.lon.ToString('N6'))) End($($targetEndPos.lat.ToString('N6')), $($targetEndPos.lon.ToString('N6')))"
        }
        
        # Round-robin video selection
        $foundVideo = $false
        $triesRemaining = $videoMetadata.Count
        $selectedVideo = $null
        $extractStart = 0.0
        $extractDuration = 0.0
        $actualEndTime = 0.0
        
        while ($triesRemaining -gt 0 -and -not $foundVideo) {
            $currentIndex = $roundRobinIndex % $videoMetadata.Count
            $vmeta = $videoMetadata[$currentIndex]
            
            Write-Verbose "  Trying video $($currentIndex + 1)/$($videoMetadata.Count): $($vmeta.Name)"
            
            # Search window for GPS matching
            $videoCurrentPos = $videoTimePositions[$vmeta.Name]
            $expectedStart = [Math]::Max($videoCurrentPos, $masterTimePosition)
            $searchStart = [Math]::Max($videoCurrentPos, $expectedStart - $Script:Config.SearchWindowHalfSec)
            $searchEnd = [Math]::Min($vmeta.EffectiveMax, $expectedStart + $Script:Config.SearchWindowHalfSec)
            
            # Find matching clip segment (using shared GPS scoring function)
            # For clips after the first, pass fade duration to ensure GPS continuity during crossfade
            $clipMatchParams = @{
                GpsPoints         = $vmeta.GpsPoints
                TargetStartLat    = $targetStartPos.lat
                TargetStartLon    = $targetStartPos.lon
                TargetEndLat      = $targetEndPos.lat
                TargetEndLon      = $targetEndPos.lon
                ClipDuration      = $ClipLengthSec
                SearchWindowStart = $searchStart
                SearchWindowEnd   = $searchEnd
            }
            
            # Add fade overlap for clips after the first to ensure seamless GPS continuity
            # Also add master timeline GPS position for deviation scoring
            if ($clipCounter -gt 0) {
                $clipMatchParams['FadeOverlapDuration'] = $FadeDurationSec
                # Pass master timeline end position for deviation penalty
                # This balances smooth transitions with master path consistency
                $masterTimelineEndPos = Get-NearestGpsPoint -GpsPoints $selectedMasterVideo.GpsPoints -TargetTime $targetEndTime
                $clipMatchParams['MasterEndLat'] = $masterTimelineEndPos.lat
                $clipMatchParams['MasterEndLon'] = $masterTimelineEndPos.lon
            }
            
            $clipMatch = Find-GpsMatchingClipSegment @clipMatchParams
            
            if (-not $clipMatch) {
                Write-Verbose "    No matching segment found"
                $roundRobinIndex++
                $triesRemaining--
                continue
            }
            
            # Check if match is valid or just a failed attempt with details
            if ($clipMatch.ContainsKey('IsValid') -and -not $clipMatch.IsValid) {
                Write-Verbose "    Match failed: $($clipMatch.FailureReason)"
                if ($clipMatch.ContainsKey('BestStartDistance')) {
                    Write-Verbose "    Best distances: start=$($clipMatch.BestStartDistance.ToString('N1'))m, end=$($clipMatch.BestEndDistance.ToString('N1'))m"
                }
                $roundRobinIndex++
                $triesRemaining--
                continue
            }
            
            # Check if it's a failed match with score details
            if ($clipMatch.ContainsKey('IsValid') -and -not $clipMatch.IsValid -and $clipMatch.FailureReason) {
                Write-Verbose "    Match rejected: $($clipMatch.FailureReason)"
                Write-Verbose "    Score: $($clipMatch.CombinedScore.ToString('N1')) - Start: $($clipMatch.StartDistance.ToString('N1'))m, End: $($clipMatch.EndDistance.ToString('N1'))m"
                $roundRobinIndex++
                $triesRemaining--
                continue
            }
            Write-Verbose "Combined Score for clip match: $($clipMatch.CombinedScore.ToString('N2'))"
            $extractStart = $clipMatch.ClipStart
            $extractDuration = [Math]::Max($clipMatch.ClipDuration, $Script:Config.MinExtractDuration)
            $actualEndTime = $clipMatch.ClipEnd
            
            # Validate bounds
            if ($extractStart -ge $vmeta.EffectiveMax -or $extractDuration -lt $Script:Config.MinClipDuration) {
                Write-Verbose "    Video exhausted or insufficient duration"
                $roundRobinIndex++
                $triesRemaining--
                continue
            }
            
            $foundVideo = $true
            $selectedVideo = $vmeta
            $lastUsedVideoIndex = $currentIndex
            
            Write-Verbose "    ✓ Match: t=$($extractStart.ToString('N2'))s dur=$($extractDuration.ToString('N2'))s, GPS dist: start=$($clipMatch.StartDistance.ToString('N1'))m end=$($clipMatch.EndDistance.ToString('N1'))m"
        }
        
        # Fallback if no video matched
        if (-not $foundVideo) {
            Write-Verbose "  No viable match, using fallback to last used video"
            $selectedVideo = $videoMetadata[$lastUsedVideoIndex]
            $extractStart = $videoTimePositions[$selectedVideo.Name]
            $desiredEnd = [Math]::Min($extractStart + $ClipLengthSec, $selectedVideo.EffectiveMax)
            $extractDuration = $desiredEnd - $extractStart
            $actualEndTime = $desiredEnd
            
            if ($extractStart -ge $selectedVideo.EffectiveMax -or $extractDuration -lt $Script:Config.MinClipDuration) {
                Write-Warning "Fallback video exhausted, stopping extraction"
                break
            }
            
            Write-Verbose "    Fallback: $($selectedVideo.Name) at t=$($extractStart.ToString('N2'))s"
        } else {
            $roundRobinIndex = ($lastUsedVideoIndex + 1) % $videoMetadata.Count
        }
        
        # Adjust for fade overlap on subsequent clips
        if ($clipCounter -gt 0) {
            $extractStart = [Math]::Max(0, $extractStart - $FadeDurationSec)
            $extractDuration = $extractDuration + $FadeDurationSec
        }
        
        # Final bounds check
        if ($extractStart + $extractDuration -gt $selectedVideo.EffectiveMax) {
            $extractDuration = [Math]::Max($Script:Config.MinClipDuration, $selectedVideo.EffectiveMax - $extractStart)
        }
        
        # Extract clip
        $clipCounter++
        $clipFile = Join-Path $tempClipsDir "clip_$($clipCounter.ToString('D4')).mp4"
        
        Write-Host "  Extracting clip #$($clipCounter): $($selectedVideo.Name) t=$($extractStart.ToString('N2'))s dur=$($extractDuration.ToString('N2'))s" -ForegroundColor Gray
        
        try {
            # Use high quality encoding for intermediate clips (balanced quality/size)
            $extractArgs = @(
                '-y',
                '-ss', $extractStart.ToString($ci),
                '-i', $selectedVideo.File.FullName,
                '-t', $extractDuration.ToString($ci),
                '-vf', "fps=$Fps,format=yuv420p,setsar=1",
                '-c:v', 'libx264',
                '-preset', 'veryfast',
                '-crf', '18',
                '-an',
                $clipFile
            )
            
            $proc = Start-Process -FilePath 'ffmpeg' -ArgumentList $extractArgs `
                -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\ffmpeg_extract.txt"
            
            if ($proc.ExitCode -ne 0 -or -not (Test-Path $clipFile)) {
                Write-Warning "Failed to extract clip #$clipCounter"
                break
            }
            
            $actualDuration = Get-VideoExactDuration -VideoPath $clipFile
            if (-not $actualDuration -or $actualDuration -le 0) {
                $actualDuration = $extractDuration
            }
            
            $extractedClips.Add([pscustomobject]@{
                Path     = $clipFile
                Duration = [double]::Parse($actualDuration.ToString('N3'), $ci)
                Video    = $selectedVideo.Name
            })
            
            # Update tracking
            $videoTimePositions[$selectedVideo.Name] = $actualEndTime
            $previousClipEndGps = Get-NearestGpsPoint -GpsPoints $selectedVideo.GpsPoints -TargetTime $actualEndTime
            $previousClipVideo = $selectedVideo
            $previousClipEndTime = $actualEndTime
            
            Write-Verbose "  ✓ Clip end GPS: ($($previousClipEndGps.lat.ToString('N6')), $($previousClipEndGps.lon.ToString('N6'))) at t=$($actualEndTime.ToString('N2'))s"
            
            # Advance master timeline
            if ($clipCounter -eq 1) {
                $masterTimePosition += $ClipLengthSec
            } else {
                $masterTimePosition += ($ClipLengthSec - $FadeDurationSec)
            }
            
        } catch {
            Write-Warning "Error extracting clip: $($_.Exception.Message)"
            break
        }
        
        # Safety check
        if ($masterTimePosition -ge $totalDuration -or $clipCounter -ge $Script:Config.MaxClipCount) {
            break
        }
    }
    
    Write-Host "`nTotal clips extracted: $($extractedClips.Count)" -ForegroundColor Green
    
    if ($extractedClips.Count -lt $Script:Config.MinClipsForMerge) {
        throw "Not enough clips extracted for merging (need at least $($Script:Config.MinClipsForMerge), got $($extractedClips.Count))"
    }
    
    # ============================================================================
    # VIDEO MERGING PHASE
    # ============================================================================
    
    Write-Host "`n=== Merging Clips with Crossfade ===" -ForegroundColor Cyan
    
    $currentVideoPath = $extractedClips[0].Path
    $currentDuration = $extractedClips[0].Duration
    
    Write-Verbose "Starting with clip A: $($currentDuration.ToString('N2'))s"
    
    for ($i = 1; $i -lt $extractedClips.Count; $i++) {
        $nextClip = $extractedClips[$i]
        $mergeOutputPath = Join-Path $tempMergeDir "m_$($i.ToString('D4')).mp4"
        
        Write-Host "  Merging clip #$i/$($extractedClips.Count - 1)..." -NoNewline
        
        try {
            $mergeResult = Merge-VideosWithCrossfade `
                -VideoA $currentVideoPath -DurationA $currentDuration `
                -VideoB $nextClip.Path -DurationB $nextClip.Duration `
                -FadeDuration $FadeDurationSec -Fps $Fps `
                -OutputPath $mergeOutputPath
            
            $currentVideoPath = $mergeOutputPath
            $currentDuration = $mergeResult.Dur
            
            Write-Host " ✓ Total: $($currentDuration.ToString('N1'))s" -ForegroundColor Green
        } catch {
            Write-Error "Failed to merge clip #$i`: $($_.Exception.Message)"
            throw
        }
    }
    
    Write-Host "`nMerge complete! Total duration: $($currentDuration.ToString('N1'))s" -ForegroundColor Green
    
    # ============================================================================
    # FINAL QUALITY ENCODE (BEFORE AUDIO)
    # ============================================================================
    
    Write-Host "`n=== Final Quality Encode ===" -ForegroundColor Cyan
    Write-Host "Converting from lossless intermediate to final quality..."
    
    # Encode the lossless merge to final quality BEFORE adding audio
    $losslessMerge = $currentVideoPath
    $outputFileNoAudio = Join-Path $outputFolder "$($outputBaseName)_noaudio.mp4"
    
    # Build final encode with GPU/CPU fallback
    $inputArgs = @('-y', '-i', $losslessMerge)
    $filterArgs = @()
    $outputArgs = @(
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart'
    )
    
    try {
        Invoke-FFmpegWithFallback -InputArgs $inputArgs -FilterArgs $filterArgs `
            -OutputArgs $outputArgs -OutputPath $outputFileNoAudio `
            -Description "Final quality encode" | Out-Null
        
        Write-Host "  ✓ Final encode complete" -ForegroundColor Green
        
        # Update current path and duration for audio overlay
        $currentVideoPath = $outputFileNoAudio
        $currentDuration = Get-VideoExactDuration -VideoPath $outputFileNoAudio
    } catch {
        Write-Warning "Final encode failed: $($_.Exception.Message)"
        Write-Warning "Copying lossless output (file will be larger)"
        Copy-Item -LiteralPath $losslessMerge -Destination $outputFileNoAudio -Force
        $currentVideoPath = $outputFileNoAudio
    }
    
    # ============================================================================
    # AUDIO OVERLAY PHASE
    # ============================================================================

    Write-Host "`n=== Adding Audio Overlay ===" -ForegroundColor Cyan

    $musicFolder = Join-Path $outputFolder 'music'

    if (Test-Path $musicFolder -PathType Container) {
        $mp3Files = Get-ChildItem -Path $musicFolder -Filter '*.mp3' -File
        
        if ($mp3Files.Count -gt 0) {
            $randomMp3 = $mp3Files | Get-Random
            Write-Host "Selected audio: $($randomMp3.Name)" -ForegroundColor Gray
            
            try {
                $audioDuration = Get-VideoFormatDuration -VideoPath $randomMp3.FullName
                $loops = [Math]::Ceiling($currentDuration / $audioDuration)
                
                Write-Verbose "Audio duration: $($audioDuration)s, Video duration: $($currentDuration)s"
                Write-Verbose "Audio will loop $loops time(s)"
                
                $fadeOutStart = [Math]::Max(0, $currentDuration - $Script:Config.AudioFadeOutDuration)
                
                # Build filter string
                $audioFilter = "[1:a]aloop=loop=${loops}:size=2e+09,atrim=end=${currentDuration},afade=t=in:st=0:d=$($Script:Config.AudioFadeInDuration),afade=t=out:st=${fadeOutStart}:d=$($Script:Config.AudioFadeOutDuration)[aout]"
                
                Write-Host "Applying audio with fade in/out..." -NoNewline
                
                $audioErrorLog = Join-Path $env:TEMP "ffmpeg_audio_error.txt"
                
                # Use native PowerShell call operator with proper quoting
                $ffmpegExe = (Get-Command ffmpeg).Source
                
                & $ffmpegExe -y `
                    -i "$outputFileNoAudio" `
                    -stream_loop -1 `
                    -i "$($randomMp3.FullName)" `
                    -filter_complex "$audioFilter" `
                    -map "0:v:0" `
                    -map "[aout]" `
                    -c:v copy `
                    -c:a aac `
                    -b:a $Script:Config.AudioBitrate `
                    -shortest `
                    "$outputFile" `
                    2> $audioErrorLog
                
                $exitCode = $LASTEXITCODE
                
                if ($exitCode -eq 0 -and (Test-Path $outputFile)) {
                    Write-Host " ✓" -ForegroundColor Green
                    Remove-Item -LiteralPath $outputFileNoAudio -Force -ErrorAction SilentlyContinue
                    Remove-Item $audioErrorLog -ErrorAction SilentlyContinue
                } else {
                    Write-Host "" # newline
                    Write-Warning "Audio overlay failed (exit code: $exitCode)"
                    
                    if (Test-Path $audioErrorLog) {
                        $errorContent = Get-Content $audioErrorLog -Raw
                        Write-Warning "FFmpeg error output:"
                        Write-Warning $errorContent
                    }
                    
                    Write-Host "Keeping video without audio: $outputFileNoAudio" -ForegroundColor Yellow
                    
                    if (Test-Path $outputFile) {
                        Remove-Item $outputFile -Force
                    }
                    Copy-Item -LiteralPath $outputFileNoAudio -Destination $outputFile -Force
                }
            } catch {
                Write-Warning "Error adding audio: $($_.Exception.Message)"
                Copy-Item -LiteralPath $outputFileNoAudio -Destination $outputFile -Force
            }
        } else {
            Write-Host "No MP3 files found in music folder, skipping audio" -ForegroundColor Yellow
            Copy-Item -LiteralPath $outputFileNoAudio -Destination $outputFile -Force
        }
    } else {
        Write-Host "Music folder not found, skipping audio overlay" -ForegroundColor Yellow
        Copy-Item -LiteralPath $outputFileNoAudio -Destination $outputFile -Force
    }
    
    # ============================================================================
    # FINALIZATION
    # ============================================================================
    
    Write-Host "`n=== Processing Complete ===" -ForegroundColor Green
    Write-Host "`nOutput file: $outputFile"
    
    if (Test-Path $outputFile) {
        $finalDuration = Get-VideoFormatDuration -VideoPath $outputFile
        Write-Host "Final duration: $($finalDuration.ToString('N1'))s"
        Write-Host "Total clips: $($extractedClips.Count)"
        Write-Host "Fade duration: $($FadeDurationSec)s"
        Write-Host "Frame rate: $($Fps) fps"
    }
    
    # Cleanup temporary directories
    if (-not $KeepTemps) {
        Write-Verbose "Cleaning up temporary directories..."
        Remove-Item -Recurse -Force $tempClipsDir, $tempMergeDir -ErrorAction SilentlyContinue
    } else {
        Write-Host "`nTemporary files kept in:" -ForegroundColor Yellow
        Write-Host "  $tempClipsDir"
        Write-Host "  $tempMergeDir"
    }
    
} catch {
    Write-Error "Fatal error: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
    exit 1
} finally {
    # Ensure cleanup on interruption if not keeping temps
    if (-not $KeepTemps -and $tempClipsDir -and (Test-Path $tempClipsDir)) {
        Write-Verbose "Final cleanup..."
        Remove-Item -Recurse -Force $tempClipsDir, $tempMergeDir -ErrorAction SilentlyContinue
    }
}

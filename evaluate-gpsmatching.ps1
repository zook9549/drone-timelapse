<#
.SYNOPSIS
    Evaluates GPS matching quality across multiple dashcam video SRT files.

.DESCRIPTION
    Analyzes SRT files with GPS data to evaluate how well video clips match up
    with each other based on GPS coordinates. Provides detailed scoring breakdowns
    to help identify:
    - The best starting clip for a timelapse
    - Optimal flow/sequence through videos
    - Videos that should be excluded due to poor GPS matching
    - Detailed score breakdowns for each potential transition

.PARAMETER InputFolder
    Path to the folder containing MP4 video files and corresponding SRT files.

.PARAMETER ClipLengthSec
    Target clip length in seconds for evaluation. Default is 5 seconds.
asf 
.PARAMETER MasterVideo
    Name of the video file to use as master reference (e.g., 'video1.mp4').
    If not specified, uses the first video by date/time.

.PARAMETER SimulateExtraction
    If specified, simulates the actual extraction process that timelapse.ps1 would perform,
    showing detailed scoring for each clip that would be extracted.

.PARAMETER FindBestMaster
    If specified, evaluates each video as a potential master to find which provides
    the best overall seamless path through all videos. Includes penalties for skipping
    videos during round-robin selection.

.PARAMETER OutputCsv
    Optional path to export results as CSV file.

.PARAMETER ShowAll
    Show all evaluations including poor matches. By default, only shows usable matches.

.EXAMPLE
    .\Evaluate-GpsMatching.ps1 -InputFolder "C:\Videos\Trip01"
    
    Evaluates GPS matching for all videos in the Trip01 folder.

.EXAMPLE
    .\Evaluate-GpsMatching.ps1 -InputFolder "C:\Videos\Trip01" -SimulateExtraction
    
    Simulates the actual timelapse extraction process with detailed scoring.

.EXAMPLE
    .\Evaluate-GpsMatching.ps1 -InputFolder "C:\Videos\Trip01" -MasterVideo "GX010123.mp4" -SimulateExtraction
    
    Simulates extraction using a specific master video.

.EXAMPLE
    .\Evaluate-GpsMatching.ps1 -InputFolder "C:\Videos\Trip01" -FindBestMaster
    
    Evaluates each video as master to find which provides the best seamless path.

.EXAMPLE
    .\Evaluate-GpsMatching.ps1 -InputFolder "C:\Videos\Trip01" -OutputCsv "results.csv" -ShowAll
    
    Evaluates and exports all results to CSV, including poor matches.
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

    [Parameter(HelpMessage = "Target clip length in seconds")]
    [ValidateRange(1, 60)]
    [int]$ClipLengthSec = 5,

    [Parameter(HelpMessage = "Name of the video file to use as master reference")]
    [string]$MasterVideo,

    [Parameter(HelpMessage = "Simulate the actual extraction process with detailed scoring")]
    [switch]$SimulateExtraction,

    [Parameter(HelpMessage = "Find the best master video by evaluating all videos")]
    [switch]$FindBestMaster,

    [Parameter(HelpMessage = "Path to export results as CSV")]
    [string]$OutputCsv,

    [Parameter(HelpMessage = "Show all matches including poor ones")]
    [switch]$ShowAll
)

#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$ci = [System.Globalization.CultureInfo]::InvariantCulture

# Import shared GPS scoring functions
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptPath "GpsScoring.ps1")

# ============================================================================
# HELPER FUNCTIONS - SRT PARSING
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
    
    throw "Invalid SRT timestamp format: '$Timestamp'"
}

function Get-SrtGpsPoints {
    <#
    .SYNOPSIS
        Parses GPS coordinates from SRT subtitle file.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SrtPath
    )
    
    if (-not (Test-Path -LiteralPath $SrtPath -PathType Leaf)) {
        throw "SRT file not found: $SrtPath"
    }
    
    Write-Verbose "Parsing GPS data from: $(Split-Path $SrtPath -Leaf)"
    
    $content = Get-Content -LiteralPath $SrtPath -Raw -ErrorAction Stop
    $blocks = ($content -split '(\r?\n){2,}') | Where-Object { $_.Trim() -ne '' }
    
    $timeLinePattern = [regex]'^\s*\d+\s*\r?\n\s*(?<t1>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<t2>\d{2}:\d{2}:\d{2},\d{3})'
    $labeledCoordPattern = [regex]'lat(?:itude)?[:=\s]*([+\-]?\d{1,3}(?:\.\d+)?)\D+lon(?:gitude)?[:=\s]*([+\-]?\d{1,3}(?:\.\d+)?)'
    $unlabeledCoordPattern = [regex]'([+\-]?\d{1,3}(?:\.\d+)?)[\s,;]+([+\-]?\d{1,3}(?:\.\d+)?)'
    
    $points = New-Object System.Collections.Generic.List[object]
    
    foreach ($block in $blocks) {
        $timeMatch = $timeLinePattern.Match($block)
        if (-not $timeMatch.Success) { continue }
        
        $timestamp = Convert-HmsToSeconds $timeMatch.Groups['t1'].Value
        
        $lines = ($block -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($lines.Count -lt 2) { continue }
        
        $payload = ($lines | Select-Object -Skip 2) -join ' '
        
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
        
        if ([double]::IsNaN($lat) -or [double]::IsNaN($lon)) { continue }
        
        if ($lat -lt -90 -or $lat -gt 90 -or $lon -lt -180 -or $lon -gt 180) { continue }
        
        $points.Add([pscustomobject]@{ 
            t = $timestamp
            lat = $lat
            lon = $lon
        })
    }
    
    return ($points | Sort-Object t)
}

# ============================================================================
# MAIN EVALUATION LOGIC
# ============================================================================

Write-Host "`n=== GPS Matching Quality Evaluator ===" -ForegroundColor Cyan
Write-Host "Input folder: $InputFolder"
Write-Host "Target clip length: $ClipLengthSec seconds"
if ($SimulateExtraction) {
    Write-Host "Mode: Simulating timelapse extraction process" -ForegroundColor Yellow
}
if ($FindBestMaster) {
    Write-Host "Mode: Finding best master video" -ForegroundColor Yellow
}
Write-Host ""

# Find all video files
$videoFiles = Get-ChildItem -Path $InputFolder -Filter '*.mp4' -File | Sort-Object Name

if ($videoFiles.Count -eq 0) {
    throw "No MP4 files found in folder: $InputFolder"
}

Write-Host "Found $($videoFiles.Count) video file(s)`n" -ForegroundColor Green

# Load GPS data for each video
Write-Host "Loading GPS metadata..." -ForegroundColor Cyan
$videos = New-Object System.Collections.Generic.List[object]

foreach ($video in $videoFiles) {
    $videoName = $video.Name
    $baseName = [IO.Path]::GetFileNameWithoutExtension($videoName)
    $srtPath = Join-Path $InputFolder "$baseName.srt"
    
    if (-not (Test-Path $srtPath)) {
        Write-Warning "No SRT file found for $videoName, skipping"
        continue
    }
    
    try {
        $gpsPoints = Get-SrtGpsPoints -SrtPath $srtPath
        
        if ($gpsPoints.Count -lt 3) {
            Write-Warning "Insufficient GPS points in $baseName.srt, skipping"
            continue
        }
        
        $videos.Add([pscustomobject]@{
            Name       = $videoName
            BaseName   = $baseName
            SrtPath    = $srtPath
            GpsPoints  = $gpsPoints
            MinTime    = $gpsPoints[0].t
            MaxTime    = $gpsPoints[-1].t
            Duration   = $gpsPoints[-1].t - $gpsPoints[0].t
            PointCount = $gpsPoints.Count
        })
        
        Write-Host "  ✓ $videoName - $($gpsPoints.Count) GPS points, duration: $($gpsPoints[-1].t.ToString('N1'))s" -ForegroundColor Gray
    } catch {
        Write-Warning "Failed to load $baseName.srt: $($_.Exception.Message)"
    }
}

if ($videos.Count -eq 0) {
    throw "No valid video files with GPS data found"
}

# ============================================================================
# FIND BEST MASTER VIDEO
# ============================================================================

if ($FindBestMaster) {
    Write-Host "`n=== Finding Best Master Video ===" -ForegroundColor Cyan
    Write-Host "Testing each video as master to find optimal starting point`n"
    
    $masterEvaluations = New-Object System.Collections.Generic.List[object]
    
    foreach ($testMaster in $videos) {
        Write-Host "Testing $($testMaster.Name) as master..." -ForegroundColor Yellow
        
        $totalDuration = [Math]::Floor($testMaster.MaxTime)
        $simulatedClips = New-Object System.Collections.Generic.List[object]
        $clipCounter = 0
        $masterTimePosition = 0.0
        $videoTimePositions = @{}
        $previousClipEndGps = $null
        $previousClipVideo = $null
        $previousClipEndTime = 0.0
        $skipPenalty = 0
        $totalSkips = 0
        
        # Initialize time tracking
        foreach ($v in $videos) {
            $videoTimePositions[$v.Name] = 0.0
        }
        
        # Start round-robin with the test master video
        $masterVideoIndex = 0
        for ($i = 0; $i -lt $videos.Count; $i++) {
            if ($videos[$i].Name -eq $testMaster.Name) {
                $masterVideoIndex = $i
                break
            }
        }
        $roundRobinIndex = $masterVideoIndex
        $lastUsedVideoIndex = $masterVideoIndex
        
        $maxAttempts = 500
        $attemptCounter = 0
        
        while ($masterTimePosition -lt $totalDuration -and $clipCounter -lt 200) {
            $attemptCounter++
            if ($attemptCounter -ge $maxAttempts) {
                break
            }
            
        # Determine target GPS
        if ($clipCounter -eq 0) {
            $targetStartPos = Get-NearestGpsPoint -GpsPoints $testMaster.GpsPoints -TargetTime $masterTimePosition
            $targetEndTime = [Math]::Min($masterTimePosition + $ClipLengthSec, $totalDuration)
            $targetEndPos = Get-NearestGpsPoint -GpsPoints $testMaster.GpsPoints -TargetTime $targetEndTime
        } else {
            # Use master video timeline to prevent error cascading
            $targetStartPos = $previousClipEndGps
            $targetEndTime = [Math]::Min($masterTimePosition + $ClipLengthSec, $totalDuration)
            $targetEndPos = Get-NearestGpsPoint -GpsPoints $testMaster.GpsPoints -TargetTime $targetEndTime
        }
            
            # Round-robin video selection
            $foundVideo = $false
            $triesRemaining = $videos.Count
            $selectedVideo = $null
            $clipMatch = $null
            $videosSkipped = 0
            
            while ($triesRemaining -gt 0 -and -not $foundVideo) {
                $currentIndex = $roundRobinIndex % $videos.Count
                $vmeta = $videos[$currentIndex]
                
                # Search window
                $videoCurrentPos = $videoTimePositions[$vmeta.Name]
                $expectedStart = [Math]::Max($videoCurrentPos, $masterTimePosition)
                $searchStart = [Math]::Max($videoCurrentPos, $expectedStart - 10.0)
                $searchEnd = [Math]::Min($vmeta.MaxTime, $expectedStart + 10.0)
                
                # Find matching segment
                # For clips after first, pass master timeline for deviation scoring
                if ($clipCounter -eq 0) {
                    $clipMatch = Find-GpsMatchingClipSegment `
                        -GpsPoints $vmeta.GpsPoints `
                        -TargetStartLat $targetStartPos.lat -TargetStartLon $targetStartPos.lon `
                        -TargetEndLat $targetEndPos.lat -TargetEndLon $targetEndPos.lon `
                        -ClipDuration $ClipLengthSec `
                        -SearchWindowStart $searchStart -SearchWindowEnd $searchEnd
                } else {
                    # Pass master timeline end position for deviation penalty
                    $masterTimelineEndPos = Get-NearestGpsPoint -GpsPoints $testMaster.GpsPoints -TargetTime $targetEndTime
                    $clipMatch = Find-GpsMatchingClipSegment `
                        -GpsPoints $vmeta.GpsPoints `
                        -TargetStartLat $targetStartPos.lat -TargetStartLon $targetStartPos.lon `
                        -TargetEndLat $targetEndPos.lat -TargetEndLon $targetEndPos.lon `
                        -ClipDuration $ClipLengthSec `
                        -SearchWindowStart $searchStart -SearchWindowEnd $searchEnd `
                        -MasterEndLat $masterTimelineEndPos.lat -MasterEndLon $masterTimelineEndPos.lon
                }
                
                if (-not $clipMatch -or 
                    ($clipMatch.ContainsKey('IsValid') -and -not $clipMatch.IsValid) -or
                    ($clipMatch.ContainsKey('FailureReason') -and $clipMatch.FailureReason) -or
                    $clipMatch.ClipStart -ge $vmeta.MaxTime -or $clipMatch.ClipDuration -lt 0.5) {
                    $roundRobinIndex++
                    $triesRemaining--
                    $videosSkipped++
                    continue
                }
                
                $foundVideo = $true
                $selectedVideo = $vmeta
                $lastUsedVideoIndex = $currentIndex
            }
            
            if (-not $foundVideo) {
                break
            }
            
            # Penalty for skipping more than 1 video
            if ($videosSkipped -gt 1) {
                $skipPenalty += ($videosSkipped - 1) * 100  # 100 points per extra skip
                $totalSkips += ($videosSkipped - 1)
            }
            
            $clipCounter++
            
            $simulatedClips.Add([pscustomobject]@{
                ClipNumber        = $clipCounter
                SourceVideo       = $selectedVideo.Name
                TotalScore        = $clipMatch.CombinedScore
                Rating            = $clipMatch.ScoreBreakdown.Rating
                VideosSkipped     = $videosSkipped
            })
            
            # Update tracking
            $videoTimePositions[$selectedVideo.Name] = $clipMatch.ClipEnd
            $previousClipEndGps = Get-NearestGpsPoint -GpsPoints $selectedVideo.GpsPoints -TargetTime $clipMatch.ClipEnd
            $previousClipVideo = $selectedVideo
            $previousClipEndTime = $clipMatch.ClipEnd
            $roundRobinIndex = ($lastUsedVideoIndex + 1) % $videos.Count
            
            # Advance timeline
            if ($clipCounter -eq 1) {
                $masterTimePosition += $ClipLengthSec
            } else {
                $masterTimePosition += $ClipLengthSec - 1.0
            }
        }
        
        if ($simulatedClips.Count -gt 0) {
            $avgScore = ($simulatedClips.TotalScore | Measure-Object -Average).Average
            $totalScore = $avgScore + $skipPenalty
            
            $ratingCounts = $simulatedClips | Group-Object Rating
            $excellentCount = ($ratingCounts | Where-Object { $_.Name -eq "Excellent" } | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue) ?? 0
            $goodCount = ($ratingCounts | Where-Object { $_.Name -eq "Good" } | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue) ?? 0
            
            Write-Host "  Clips extracted: $($simulatedClips.Count)" -ForegroundColor Gray
            Write-Host "  Average clip score: $($avgScore.ToString('N1'))" -ForegroundColor Gray
            Write-Host "  Skip penalty: $($skipPenalty.ToString('N0')) (skipped $totalSkips extra times)" -ForegroundColor $(if ($skipPenalty -gt 0) { "Yellow" } else { "Gray" })
            Write-Host "  Total score: $($totalScore.ToString('N1'))" -ForegroundColor Cyan
            Write-Host "  Quality: $excellentCount Excellent, $goodCount Good`n" -ForegroundColor Gray
            
            $masterEvaluations.Add([pscustomobject]@{
                MasterVideo       = $testMaster.Name
                ClipsExtracted    = $simulatedClips.Count
                AverageClipScore  = $avgScore
                SkipPenalty       = $skipPenalty
                TotalSkips        = $totalSkips
                TotalScore        = $totalScore
                ExcellentCount    = $excellentCount
                GoodCount         = $goodCount
            })
        } else {
            Write-Host "  ✗ No clips could be extracted" -ForegroundColor Red
            Write-Host ""
        }
    }
    
    if ($masterEvaluations.Count -gt 0) {
        Write-Host "`n=== Master Video Recommendations ===" -ForegroundColor Cyan
        Write-Host "Ranked by total score (lower is better)`n"
        
        $rankedMasters = $masterEvaluations | Sort-Object TotalScore
        
        $rank = 1
        foreach ($master in $rankedMasters) {
            $color = if ($rank -eq 1) { "Green" } elseif ($rank -le 3) { "Cyan" } else { "Gray" }
            
            Write-Host ("#$rank - $($master.MasterVideo)") -ForegroundColor $color
            Write-Host ("     Total Score: {0,7:N1}  |  Avg Clip Score: {1,7:N1}  |  Skip Penalty: {2,5:N0}" -f `
                $master.TotalScore, $master.AverageClipScore, $master.SkipPenalty) -ForegroundColor $color
            Write-Host ("     Clips: {0,3}  |  Quality: {1} Excellent, {2} Good  |  Skips: {3}" -f `
                $master.ClipsExtracted, $master.ExcellentCount, $master.GoodCount, $master.TotalSkips) -ForegroundColor $color
            Write-Host ""
            $rank++
        }
        
        $bestMaster = $rankedMasters[0]
        Write-Host "=== Recommendation ===" -ForegroundColor Green
        Write-Host "Best master video: $($bestMaster.MasterVideo)" -ForegroundColor Green
        Write-Host "To use this master, run:" -ForegroundColor Gray
        Write-Host "  .\timelapse.ps1 -InputFolder `"$InputFolder`" -MasterVideo `"$($bestMaster.MasterVideo)`"" -ForegroundColor White
        
        # Export if CSV specified
        if ($OutputCsv) {
            Write-Host "`n=== Exporting Results ===" -ForegroundColor Cyan
            $masterEvaluations | Export-Csv -Path $OutputCsv -NoTypeInformation
            Write-Host "Master evaluation results exported to: $OutputCsv" -ForegroundColor Green
        }
    } else {
        Write-Warning "No videos could successfully extract clips as master"
    }
    
    Write-Host "`n=== Evaluation Complete ===" -ForegroundColor Green
    return
}

# If SimulateExtraction, run simulation instead of general evaluation
if ($SimulateExtraction) {
    # Select master video
    if ($MasterVideo) {
        Write-Verbose "Looking for specified master video: $MasterVideo"
        $masterVideo = $videos | Where-Object { $_.Name -eq $MasterVideo } | Select-Object -First 1
        
        if (-not $masterVideo) {
            Write-Warning "Specified master video '$MasterVideo' not found."
            Write-Warning "Available videos: $($videos.Name -join ', ')"
            throw "Master video not found: $MasterVideo"
        }
        
        Write-Host "`nUsing specified master reference: $($masterVideo.Name)" -ForegroundColor Cyan
    } else {
        $masterVideo = $videos[0]
        Write-Host "`nUsing first video as master reference: $($masterVideo.Name)" -ForegroundColor Cyan
    }
    
    $totalDuration = [Math]::Floor($masterVideo.MaxTime)
    Write-Host "Usable duration: $totalDuration seconds`n"
    
    Write-Host "=== Simulating Clip Extraction ===" -ForegroundColor Cyan
    Write-Host "This shows exactly what timelapse.ps1 would extract`n"
    
    $simulatedClips = New-Object System.Collections.Generic.List[object]
    $clipCounter = 0
    $masterTimePosition = 0.0
    $videoTimePositions = @{}
    $previousClipEndGps = $null
    $previousClipVideo = $null
    $previousClipEndTime = 0.0
    
    # Initialize time tracking
    foreach ($v in $videos) {
        $videoTimePositions[$v.Name] = 0.0
    }
    
    # Start round-robin with the master video
    $masterVideoIndex = 0
    for ($i = 0; $i -lt $videos.Count; $i++) {
        if ($videos[$i].Name -eq $masterVideo.Name) {
            $masterVideoIndex = $i
            break
        }
    }
    $roundRobinIndex = $masterVideoIndex
    $lastUsedVideoIndex = $masterVideoIndex
    
    Write-Verbose "Round-robin starting with video index $masterVideoIndex ($($masterVideo.Name))"
    
    $maxAttempts = 500
    $attemptCounter = 0
    
    while ($masterTimePosition -lt $totalDuration -and $clipCounter -lt 200) {
        $attemptCounter++
        if ($attemptCounter -ge $maxAttempts) {
            Write-Warning "Reached maximum attempts ($maxAttempts)"
            break
        }
        
        # Determine target GPS
        if ($clipCounter -eq 0) {
            $targetStartPos = Get-NearestGpsPoint -GpsPoints $masterVideo.GpsPoints -TargetTime $masterTimePosition
            $targetEndTime = [Math]::Min($masterTimePosition + $ClipLengthSec, $totalDuration)
            $targetEndPos = Get-NearestGpsPoint -GpsPoints $masterVideo.GpsPoints -TargetTime $targetEndTime
            
            Write-Host "`n=== Clip #1 (Master Reference) ===" -ForegroundColor Green
            Write-Host "Target Start GPS: ($($targetStartPos.lat.ToString('N6')), $($targetStartPos.lon.ToString('N6')))"
            Write-Host "Target End GPS:   ($($targetEndPos.lat.ToString('N6')), $($targetEndPos.lon.ToString('N6')))"
        } else {
            # Use master video timeline to prevent error cascading
            $targetStartPos = $previousClipEndGps
            $targetEndTime = [Math]::Min($masterTimePosition + $ClipLengthSec, $totalDuration)
            $targetEndPos = Get-NearestGpsPoint -GpsPoints $masterVideo.GpsPoints -TargetTime $targetEndTime
            
            Write-Host "`n=== Clip #$($clipCounter + 1) ===" -ForegroundColor Green
            Write-Host "Target Start GPS: ($($targetStartPos.lat.ToString('N6')), $($targetStartPos.lon.ToString('N6'))) [continuing from $($previousClipVideo.Name)]"
            Write-Host "Target End GPS:   ($($targetEndPos.lat.ToString('N6')), $($targetEndPos.lon.ToString('N6'))) [from master timeline]"
        }
        
        # Round-robin video selection
        $foundVideo = $false
        $triesRemaining = $videos.Count
        $selectedVideo = $null
        $clipMatch = $null
        
        while ($triesRemaining -gt 0 -and -not $foundVideo) {
            $currentIndex = $roundRobinIndex % $videos.Count
            $vmeta = $videos[$currentIndex]
            
            Write-Verbose "  Trying video: $($vmeta.Name)"
            
            # Search window
            $videoCurrentPos = $videoTimePositions[$vmeta.Name]
            $expectedStart = [Math]::Max($videoCurrentPos, $masterTimePosition)
            $searchStart = [Math]::Max($videoCurrentPos, $expectedStart - 10.0)
            $searchEnd = [Math]::Min($vmeta.MaxTime, $expectedStart + 10.0)
            
            # Find matching segment
            # For clips after first, pass master timeline for deviation scoring
            if ($clipCounter -eq 0) {
                $clipMatch = Find-GpsMatchingClipSegment `
                    -GpsPoints $vmeta.GpsPoints `
                    -TargetStartLat $targetStartPos.lat -TargetStartLon $targetStartPos.lon `
                    -TargetEndLat $targetEndPos.lat -TargetEndLon $targetEndPos.lon `
                    -ClipDuration $ClipLengthSec `
                    -SearchWindowStart $searchStart -SearchWindowEnd $searchEnd
            } else {
                # Pass master timeline end position for deviation penalty
                $masterTimelineEndPos = Get-NearestGpsPoint -GpsPoints $masterVideo.GpsPoints -TargetTime $targetEndTime
                $clipMatch = Find-GpsMatchingClipSegment `
                    -GpsPoints $vmeta.GpsPoints `
                    -TargetStartLat $targetStartPos.lat -TargetStartLon $targetStartPos.lon `
                    -TargetEndLat $targetEndPos.lat -TargetEndLon $targetEndPos.lon `
                    -ClipDuration $ClipLengthSec `
                    -SearchWindowStart $searchStart -SearchWindowEnd $searchEnd `
                    -MasterEndLat $masterTimelineEndPos.lat -MasterEndLon $masterTimelineEndPos.lon
            }
            
            if (-not $clipMatch) {
                Write-Verbose "  No matching segment found"
                $roundRobinIndex++
                $triesRemaining--
                continue
            }
            
            # Check if match is valid or just a failed attempt with details
            if ($clipMatch.ContainsKey('IsValid') -and -not $clipMatch.IsValid) {
                if ($clipMatch.ContainsKey('BestStartDistance')) {
                    Write-Host "  ✗ No valid match: $($clipMatch.FailureReason)" -ForegroundColor Red
                    Write-Host "    Best distances: start=$($clipMatch.BestStartDistance.ToString('N1'))m, end=$($clipMatch.BestEndDistance.ToString('N1'))m" -ForegroundColor Gray
                } else {
                    Write-Host "  ✗ $($clipMatch.FailureReason)" -ForegroundColor Red
                }
                $roundRobinIndex++
                $triesRemaining--
                continue
            }
            
            # Check if it's a failed match with score details
            if ($clipMatch.ContainsKey('FailureReason') -and $clipMatch.FailureReason) {
                Write-Host "  ✗ Match rejected: $($clipMatch.FailureReason)" -ForegroundColor Yellow
                Write-Host "    Score: $($clipMatch.CombinedScore.ToString('N1')) - Start: $($clipMatch.StartDistance.ToString('N1'))m, End: $($clipMatch.EndDistance.ToString('N1'))m" -ForegroundColor Gray
                $roundRobinIndex++
                $triesRemaining--
                continue
            }
            
            if ($clipMatch.ClipStart -ge $vmeta.MaxTime -or $clipMatch.ClipDuration -lt 0.5) {
                Write-Verbose "  Video exhausted or insufficient duration"
                $roundRobinIndex++
                $triesRemaining--
                continue
            }
            
            $foundVideo = $true
            $selectedVideo = $vmeta
            $lastUsedVideoIndex = $currentIndex
        }
        
        if (-not $foundVideo) {
            Write-Host "  ✗ No matching clip found" -ForegroundColor Red
            break
        }
        
        $clipCounter++
        
        # Display detailed scoring
        Write-Host "  ✓ Match Found: $($selectedVideo.Name)" -ForegroundColor Cyan
        Write-Host "    Time: $($clipMatch.ClipStart.ToString('N2'))s - $($clipMatch.ClipEnd.ToString('N2'))s"
        Write-Host "    Duration: $($clipMatch.ClipDuration.ToString('N2'))s (target: $($ClipLengthSec)s, deviation: $($clipMatch.DurationDeviation.ToString('N2'))s)"
        Write-Host "    Start GPS Distance: $($clipMatch.StartDistance.ToString('N1'))m" -ForegroundColor $(if ($clipMatch.StartDistance -le 15) { "Green" } else { "Yellow" })
        Write-Host "    End GPS Distance:   $($clipMatch.EndDistance.ToString('N1'))m" -ForegroundColor $(if ($clipMatch.EndDistance -le 30) { "Green" } else { "Yellow" })
        Write-Host "    Score Breakdown:"
        Write-Host "      • Start GPS Score:     $($clipMatch.ScoreBreakdown.StartScore.ToString('N1')) (distance $($clipMatch.StartDistance.ToString('N1'))m × weight 10.0)"
        Write-Host "      • End GPS Score:       $($clipMatch.ScoreBreakdown.EndScore.ToString('N1')) (distance $($clipMatch.EndDistance.ToString('N1'))m × weight 2.0)"
        Write-Host "      • Duration Score:      $($clipMatch.ScoreBreakdown.DurationScore.ToString('N1')) (deviation $($clipMatch.DurationDeviation.ToString('N2'))s × weight 0.5)"
        Write-Host "      • Combined Score:      $($clipMatch.CombinedScore.ToString('N1'))" -ForegroundColor $(
            if ($clipMatch.ScoreBreakdown.Rating -eq "Excellent") { "Green" }
            elseif ($clipMatch.ScoreBreakdown.Rating -eq "Good") { "Cyan" }
            elseif ($clipMatch.ScoreBreakdown.Rating -eq "Fair") { "Yellow" }
            else { "Red" }
        )
        Write-Host "    Rating: $($clipMatch.ScoreBreakdown.Rating)" -ForegroundColor $(
            if ($clipMatch.ScoreBreakdown.Rating -eq "Excellent") { "Green" }
            elseif ($clipMatch.ScoreBreakdown.Rating -eq "Good") { "Cyan" }
            elseif ($clipMatch.ScoreBreakdown.Rating -eq "Fair") { "Yellow" }
            else { "Red" }
        )
        
        $simulatedClips.Add([pscustomobject]@{
            ClipNumber        = $clipCounter
            SourceVideo       = $selectedVideo.Name
            StartTime         = $clipMatch.ClipStart
            EndTime           = $clipMatch.ClipEnd
            Duration          = $clipMatch.ClipDuration
            StartDistance     = $clipMatch.StartDistance
            EndDistance       = $clipMatch.EndDistance
            DurationDeviation = $clipMatch.DurationDeviation
            StartScore        = $clipMatch.ScoreBreakdown.StartScore
            EndScore          = $clipMatch.ScoreBreakdown.EndScore
            DurationScore     = $clipMatch.ScoreBreakdown.DurationScore
            TotalScore        = $clipMatch.CombinedScore
            Rating            = $clipMatch.ScoreBreakdown.Rating
        })
        
        # Update tracking
        $videoTimePositions[$selectedVideo.Name] = $clipMatch.ClipEnd
        $previousClipEndGps = Get-NearestGpsPoint -GpsPoints $selectedVideo.GpsPoints -TargetTime $clipMatch.ClipEnd
        $previousClipVideo = $selectedVideo
        $previousClipEndTime = $clipMatch.ClipEnd
        $roundRobinIndex = ($lastUsedVideoIndex + 1) % $videos.Count
        
        # Advance timeline
        if ($clipCounter -eq 1) {
            $masterTimePosition += $ClipLengthSec
        } else {
            $masterTimePosition += $ClipLengthSec - 1.0  # Assuming 1s fade
        }
    }
    
    Write-Host "`n=== Simulation Summary ===" -ForegroundColor Cyan
    Write-Host "Total clips that would be extracted: $($simulatedClips.Count)"
    
    if ($simulatedClips.Count -gt 0) {
        $avgScore = ($simulatedClips.TotalScore | Measure-Object -Average).Average
        $ratingCounts = $simulatedClips | Group-Object Rating
        
        Write-Host "Average score: $($avgScore.ToString('N1'))"
        Write-Host "`nRating distribution:"
        foreach ($group in ($ratingCounts | Sort-Object Name)) {
            $color = switch ($group.Name) {
                "Excellent" { "Green" }
                "Good" { "Cyan" }
                "Fair" { "Yellow" }
                "Poor" { "DarkYellow" }
                default { "Gray" }
            }
            Write-Host "  $($group.Name): $($group.Count) clips" -ForegroundColor $color
        }
        
        Write-Host "`nVideo usage:"
        $videoUsage = $simulatedClips | Group-Object SourceVideo | Sort-Object Count -Descending
        foreach ($usage in $videoUsage) {
            Write-Host "  $($usage.Name): $($usage.Count) clips"
        }
    }
    
    # Export simulation results if CSV specified
    if ($OutputCsv) {
        Write-Host "`n=== Exporting Results ===" -ForegroundColor Cyan
        $simulatedClips | Export-Csv -Path $OutputCsv -NoTypeInformation
        Write-Host "Simulation results exported to: $OutputCsv" -ForegroundColor Green
    }
    
    Write-Host "`n=== Simulation Complete ===" -ForegroundColor Green
    return
}

Write-Host "`n=== Evaluating GPS Matching Quality ===" -ForegroundColor Cyan
Write-Host "Comparing all video pairs to find optimal transitions...`n"

# Setup cache file
$cacheFile = Join-Path $InputFolder "_gps_match_cache.csv"
$cachedResults = @{}
$newResultsCount = 0

# Load existing cache if it exists
if (Test-Path $cacheFile) {
    Write-Host "Loading cached results from previous runs..." -ForegroundColor Cyan
    try {
        $existingCache = Import-Csv -Path $cacheFile
        foreach ($cached in $existingCache) {
            # Create cache key: Source|SourceTime|Target|ClipLength
            $key = "$($cached.SourceVideo)|$($cached.SourceTime)|$($cached.TargetVideo)|$($cached.ClipDuration)"
            $cachedResults[$key] = $cached
        }
        Write-Host "  Loaded $($cachedResults.Count) cached evaluations" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to load cache file: $($_.Exception.Message)"
        Write-Warning "Will regenerate all results"
    }
}

# Evaluate all possible transitions
$evaluations = New-Object System.Collections.Generic.List[object]
$newEvaluations = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $videos.Count; $i++) {
    $sourceVideo = $videos[$i]
    
    Write-Host "Analyzing $($sourceVideo.Name)..." -ForegroundColor Yellow
    
    # Sample multiple points from this video to evaluate as potential clip starts
    $sampleCount = [Math]::Min(10, [Math]::Floor($sourceVideo.Duration / $ClipLengthSec))
    $sampleInterval = ($sourceVideo.Duration - $ClipLengthSec) / [Math]::Max(1, $sampleCount - 1)
    
    for ($sample = 0; $sample -lt $sampleCount; $sample++) {
        $sampleTime = $sourceVideo.MinTime + ($sample * $sampleInterval)
        
        # Get start and end GPS for this sample clip
        $startGps = Get-NearestGpsPoint -GpsPoints $sourceVideo.GpsPoints -TargetTime $sampleTime
        $endTime = $sampleTime + $ClipLengthSec
        $endGps = Get-NearestGpsPoint -GpsPoints $sourceVideo.GpsPoints -TargetTime $endTime
        
        # Try to find matching segments in all other videos (including same video at different times)
        for ($j = 0; $j -lt $videos.Count; $j++) {
            $targetVideo = $videos[$j]
            
            # Define search window
            $searchStart = $targetVideo.MinTime
            $searchEnd = $targetVideo.MaxTime - $ClipLengthSec
            
            if ($searchEnd -le $searchStart) { continue }
            
            # Check cache first
            $cacheKey = "$($sourceVideo.Name)|$sampleTime|$($targetVideo.Name)|$ClipLengthSec"
            
            if ($cachedResults.ContainsKey($cacheKey)) {
                # Use cached result
                $cached = $cachedResults[$cacheKey]
                $evaluations.Add([pscustomobject]@{
                    SourceVideo       = $cached.SourceVideo
                    SourceTime        = [double]$cached.SourceTime
                    TargetVideo       = $cached.TargetVideo
                    TargetTime        = [double]$cached.TargetTime
                    ClipDuration      = [double]$cached.ClipDuration
                    StartDistance     = [double]$cached.StartDistance
                    EndDistance       = [double]$cached.EndDistance
                    DurationDeviation = [double]$cached.DurationDeviation
                    TotalScore        = [double]$cached.TotalScore
                    StartScore        = [double]$cached.StartScore
                    EndScore          = [double]$cached.EndScore
                    DurationScore     = [double]$cached.DurationScore
                    Rating            = $cached.Rating
                    IsStartValid      = [bool]::Parse($cached.IsStartValid)
                    IsEndValid        = [bool]::Parse($cached.IsEndValid)
                })
            } else {
                # Run new evaluation
                $match = Find-GpsMatchingClipSegment `
                    -GpsPoints $targetVideo.GpsPoints `
                    -TargetStartLat $startGps.lat -TargetStartLon $startGps.lon `
                    -TargetEndLat $endGps.lat -TargetEndLon $endGps.lon `
                    -ClipDuration $ClipLengthSec `
                    -SearchWindowStart $searchStart `
                    -SearchWindowEnd $searchEnd
                
                if ($match) {
                    $newResult = [pscustomobject]@{
                        SourceVideo       = $sourceVideo.Name
                        SourceTime        = $sampleTime
                        TargetVideo       = $targetVideo.Name
                        TargetTime        = $match.ClipStart
                        ClipDuration      = $match.ClipDuration
                        StartDistance     = $match.StartDistance
                        EndDistance       = $match.EndDistance
                        DurationDeviation = $match.DurationDeviation
                        TotalScore        = $match.CombinedScore
                        StartScore        = $match.ScoreBreakdown.StartScore
                        EndScore          = $match.ScoreBreakdown.EndScore
                        DurationScore     = $match.ScoreBreakdown.DurationScore
                        Rating            = $match.ScoreBreakdown.Rating
                        IsStartValid      = $match.ScoreBreakdown.IsStartValid
                        IsEndValid        = $match.ScoreBreakdown.IsEndValid
                    }
                    $evaluations.Add($newResult)
                    $newEvaluations.Add($newResult)
                    $newResultsCount++
                }
            }
        }
    }
}

Write-Host "`n=== Evaluation Results ===" -ForegroundColor Cyan
Write-Host "Total evaluations: $($evaluations.Count)`n"

# Filter results
$filteredEvals = if ($ShowAll) {
    $evaluations
} else {
    $evaluations | Where-Object { $_.Rating -ne "Unusable" }
}

# Group by rating
$byRating = $filteredEvals | Group-Object Rating | Sort-Object Name

Write-Host "Match Quality Summary:" -ForegroundColor Green
foreach ($group in $byRating) {
    $color = switch ($group.Name) {
        "Excellent" { "Green" }
        "Good" { "Cyan" }
        "Fair" { "Yellow" }
        "Poor" { "DarkYellow" }
        "Unusable" { "Red" }
        default { "Gray" }
    }
    Write-Host "  $($group.Name): $($group.Count) matches" -ForegroundColor $color
}

# Find best starting points
Write-Host "`n=== Best Starting Points ===" -ForegroundColor Cyan
$bestStarts = $filteredEvals | 
    Where-Object { $_.Rating -in @("Excellent", "Good") } |
    Group-Object SourceVideo |
    ForEach-Object {
        $video = $_.Name
        $bestMatch = $_.Group | Sort-Object TotalScore | Select-Object -First 1
        [pscustomobject]@{
            Video = $video
            BestScore = $bestMatch.TotalScore
            BestRating = $bestMatch.Rating
            MatchCount = $_.Count
        }
    } |
    Sort-Object BestScore

if ($bestStarts.Count -gt 0) {
    Write-Host "Videos ranked by best transition quality:" -ForegroundColor Gray
    foreach ($start in $bestStarts) {
        $color = if ($start.BestRating -eq "Excellent") { "Green" } else { "Cyan" }
        Write-Host ("  {0,-30} Score: {1,7:N1}  Rating: {2,-10} Matches: {3}" -f `
            $start.Video, $start.BestScore, $start.BestRating, $start.MatchCount) -ForegroundColor $color
    }
} else {
    Write-Warning "No good starting points found. Videos may be too far apart geographically."
}

# Show video compatibility matrix
Write-Host "`n=== Video Compatibility Matrix ===" -ForegroundColor Cyan
Write-Host "Shows average match quality between video pairs`n"

$matrix = @{}
foreach ($eval in $filteredEvals) {
    $key = "$($eval.SourceVideo)|$($eval.TargetVideo)"
    if (-not $matrix.ContainsKey($key)) {
        $matrix[$key] = New-Object System.Collections.Generic.List[double]
    }
    $matrix[$key].Add($eval.TotalScore)
}

$videoNames = $videos.Name | Sort-Object
$matrixResults = New-Object System.Collections.Generic.List[object]

foreach ($source in $videoNames) {
    $row = [pscustomobject]@{ Source = $source }
    foreach ($target in $videoNames) {
        $key = "$source|$target"
        if ($matrix.ContainsKey($key)) {
            $avgScore = ($matrix[$key] | Measure-Object -Average).Average
            $row | Add-Member -NotePropertyName $target -NotePropertyValue $avgScore
        } else {
            $row | Add-Member -NotePropertyName $target -NotePropertyValue $null
        }
    }
    $matrixResults.Add($row)
}

# Display simplified matrix
foreach ($row in $matrixResults) {
    Write-Host ("{0,-30}" -f $row.Source) -NoNewline
    foreach ($target in $videoNames) {
        $score = $row.$target
        if ($null -eq $score) {
            Write-Host "  ----  " -NoNewline
        } else {
            $color = if ($score -lt 50) { "Green" } 
                     elseif ($score -lt 150) { "Cyan" }
                     elseif ($score -lt 300) { "Yellow" }
                     else { "Red" }
            Write-Host ("{0,7:N0}" -f $score) -ForegroundColor $color -NoNewline
        }
    }
    Write-Host ""
}

# Identify unusable videos
$unusableVideos = $videos.Name | Where-Object {
    $videoName = $_
    $matches = $filteredEvals | Where-Object { $_.SourceVideo -eq $videoName }
    $matches.Count -eq 0
}

if ($unusableVideos.Count -gt 0) {
    Write-Host "`n=== Unusable Videos ===" -ForegroundColor Red
    Write-Host "These videos have no usable GPS matches with other videos:" -ForegroundColor Gray
    foreach ($unusable in $unusableVideos) {
        Write-Host "  ✗ $unusable" -ForegroundColor Red
    }
}

# Show detailed breakdown for top matches
Write-Host "`n=== Top 10 Best Matches (Detailed Breakdown) ===" -ForegroundColor Cyan
$topMatches = $filteredEvals | Sort-Object TotalScore | Select-Object -First 10

foreach ($match in $topMatches) {
    Write-Host "`nMatch Score: $($match.TotalScore.ToString('N1')) [$($match.Rating)]" -ForegroundColor Green
    Write-Host "  Source: $($match.SourceVideo) @ $($match.SourceTime.ToString('N1'))s"
    Write-Host "  Target: $($match.TargetVideo) @ $($match.TargetTime.ToString('N1'))s"
    Write-Host "  Clip Duration: $($match.ClipDuration.ToString('N2'))s (deviation: $($match.DurationDeviation.ToString('N2'))s)"
    Write-Host "  Score Breakdown:"
    Write-Host "    - Start GPS Distance: $($match.StartDistance.ToString('N1'))m (score: $($match.StartScore.ToString('N1')))"
    Write-Host "    - End GPS Distance:   $($match.EndDistance.ToString('N1'))m (score: $($match.EndScore.ToString('N1')))"
    Write-Host "    - Duration Penalty:   (score: $($match.DurationScore.ToString('N1')))"
    Write-Host "  Validation: Start=$($match.IsStartValid) End=$($match.IsEndValid)"
}

# Save new results to cache
if ($newResultsCount -gt 0) {
    Write-Host "`n=== Updating Cache ===" -ForegroundColor Cyan
    Write-Host "Appending $newResultsCount new evaluation(s) to cache..." -ForegroundColor Gray
    try {
        # Append new results to cache file
        $newEvaluations | Export-Csv -Path $cacheFile -NoTypeInformation -Append
        Write-Host "  ✓ Cache updated: $cacheFile" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to update cache: $($_.Exception.Message)"
    }
} elseif ($cachedResults.Count -gt 0) {
    Write-Host "`n=== Cache Status ===" -ForegroundColor Cyan
    Write-Host "All results loaded from cache - no new evaluations needed" -ForegroundColor Green
}

# Export to CSV if requested
if ($OutputCsv) {
    Write-Host "`n=== Exporting Results ===" -ForegroundColor Cyan
    $filteredEvals | Export-Csv -Path $OutputCsv -NoTypeInformation
    Write-Host "Results exported to: $OutputCsv" -ForegroundColor Green
}

Write-Host "`n=== Evaluation Complete ===" -ForegroundColor Green
Write-Host "Total matches analyzed: $($evaluations.Count)"
Write-Host "Usable matches: $($filteredEvals.Count)"
Write-Host "Videos with usable matches: $($videos.Count - $unusableVideos.Count) of $($videos.Count)"
if ($newResultsCount -gt 0) {
    Write-Host "New evaluations cached: $newResultsCount" -ForegroundColor Cyan
}

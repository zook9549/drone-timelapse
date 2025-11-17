<#
.SYNOPSIS
    Shared GPS scoring functions for timelapse video analysis.

.DESCRIPTION
    Provides GPS coordinate matching and scoring functionality that can be used
    by both the evaluation script and the main timelapse script.
#>

$Script:ScoringConfig = @{
    # GPS matching thresholds
    MaxDistanceMeters      = 25.0    # Maximum distance in meters for GPS coordinate matching
    StartDistanceWeight    = 10.0    # Weight for start coordinate precision
    EndDistanceWeight      = 2.0     # Weight for end coordinate proximity
    DurationDeviationWeight = 0.5    # Weight for duration deviation penalty
    MasterDeviationWeight  = 0.5     # Weight for master timeline deviation penalty
    
    # Duration flexibility
    MinDurationMultiplier  = 0.5     # Minimum duration as fraction of target (50%)
    MaxDurationMultiplier  = 2.0     # Maximum duration as fraction of target (150%)
    
    # Start point precision threshold (stricter than end point)
    StartDistanceMultiplier = 0.6    # Start must be within 50% of max distance
    
    # GPS coordinate validation
    MinLatitude            = -90.0
    MaxLatitude            = 90.0
    MinLongitude           = -180.0
    MaxLongitude           = 180.0
}

function Get-HaversineDistance {
    <#
    .SYNOPSIS
        Calculates distance between two GPS coordinates using Haversine formula.
    .DESCRIPTION
        Returns distance in meters between two points on Earth's surface.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [double]$Lat1,
        
        [Parameter(Mandatory = $true)]
        [double]$Lon1,
        
        [Parameter(Mandatory = $true)]
        [double]$Lat2,
        
        [Parameter(Mandatory = $true)]
        [double]$Lon2
    )
    
    $earthRadiusMeters = 6371000.0
    $toRadians = [Math]::PI / 180.0
    
    # Convert to radians and calculate deltas
    $dLat = ($Lat2 - $Lat1) * $toRadians
    $dLon = ($Lon2 - $Lon1) * $toRadians
    $lat1Rad = $Lat1 * $toRadians
    $lat2Rad = $Lat2 * $toRadians
    
    # Haversine formula
    $a = [Math]::Pow([Math]::Sin($dLat / 2), 2) + 
         [Math]::Cos($lat1Rad) * [Math]::Cos($lat2Rad) * 
         [Math]::Pow([Math]::Sin($dLon / 2), 2)
    
    $c = 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1 - $a))
    
    return $earthRadiusMeters * $c
}

function Get-NearestGpsPoint {
    <#
    .SYNOPSIS
        Finds GPS point closest to specified time.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$GpsPoints,
        
        [Parameter(Mandatory = $true)]
        [double]$TargetTime
    )
    
    $bestPoint = $null
    $bestTimeDiff = [double]::PositiveInfinity
    
    foreach ($point in $GpsPoints) {
        $timeDiff = [Math]::Abs($point.t - $TargetTime)
        if ($timeDiff -lt $bestTimeDiff) {
            $bestTimeDiff = $timeDiff
            $bestPoint = $point
        }
    }
    
    return $bestPoint
}

function Get-GpsMatchScore {
    <#
    .SYNOPSIS
        Calculates a GPS matching score for a potential clip segment.
    .DESCRIPTION
        Evaluates how well a clip segment matches target GPS coordinates.
        Returns a detailed score breakdown including individual component scores.
        Lower scores are better (0 is perfect match).
    .OUTPUTS
        Hashtable with the following keys:
        - TotalScore: Combined weighted score
        - StartDistance: Distance from target start in meters
        - EndDistance: Distance from target end in meters
        - MasterDeviation: Distance from master timeline end position (optional)
        - DurationDeviation: Difference from target duration in seconds
        - StartScore: Weighted start distance score
        - EndScore: Weighted end distance score
        - MasterScore: Weighted master deviation score (if applicable)
        - DurationScore: Weighted duration deviation score
        - IsStartValid: Whether start point meets strict threshold
        - IsEndValid: Whether end point meets threshold
        - Rating: Text rating (Excellent/Good/Fair/Poor/Unusable)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [double]$StartDistance,
        
        [Parameter(Mandatory = $true)]
        [double]$EndDistance,
        
        [Parameter(Mandatory = $true)]
        [double]$DurationDeviation,
        
        [Parameter(Mandatory = $true)]
        [double]$TargetDuration,
        
        [Parameter(Mandatory = $false)]
        [double]$MasterDeviation = 0.0
    )
    
    # Calculate component scores
    $startScore = $StartDistance * $Script:ScoringConfig.StartDistanceWeight
    $endScore = $EndDistance * $Script:ScoringConfig.EndDistanceWeight
    $durationScore = $DurationDeviation * $Script:ScoringConfig.DurationDeviationWeight
    $masterScore = $MasterDeviation * $Script:ScoringConfig.MasterDeviationWeight
    
    $totalScore = $startScore + $endScore + $durationScore + $masterScore
    
    # Validate thresholds
    $startThreshold = $Script:ScoringConfig.MaxDistanceMeters * $Script:ScoringConfig.StartDistanceMultiplier
    $isStartValid = $StartDistance -le $startThreshold
    $isEndValid = $EndDistance -le $Script:ScoringConfig.MaxDistanceMeters
    
    # Determine rating (adjust thresholds slightly for master deviation)
    $rating = if (-not $isStartValid -or -not $isEndValid) {
        "Unusable"
    } elseif ($totalScore -lt 60) {
        "Excellent"
    } elseif ($totalScore -lt 180) {
        "Good"
    } elseif ($totalScore -lt 350) {
        "Fair"
    } else {
        "Poor"
    }
    
    return @{
        TotalScore         = $totalScore
        StartDistance      = $StartDistance
        EndDistance        = $EndDistance
        MasterDeviation    = $MasterDeviation
        DurationDeviation  = $DurationDeviation
        StartScore         = $startScore
        EndScore           = $endScore
        MasterScore        = $masterScore
        DurationScore      = $durationScore
        IsStartValid       = $isStartValid
        IsEndValid         = $isEndValid
        Rating             = $rating
    }
}

function Find-GpsMatchingClipSegment {
    <#
    .SYNOPSIS
        Finds video segment matching target GPS coordinates at both start and end.
    .DESCRIPTION
        Searches for a clip segment where both the starting and ending GPS positions
        match the target coordinates. Prioritizes GPS coordinate precision over timing.
        Uses the shared scoring function to evaluate matches.
        Returns detailed failure information if no valid match is found.
        
        When FadeOverlapDuration is specified (for clips after the first), the function
        ensures the GPS point at (ClipStart - FadeOverlapDuration) matches the target,
        providing seamless GPS continuity during crossfade transitions.
        
        When MasterEndLat/Lon is specified, adds a penalty score based on deviation
        from where the master timeline expects the clip to end. This helps maintain
        overall path consistency while still prioritizing smooth transitions.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$GpsPoints,
        
        [Parameter(Mandatory = $true)]
        [double]$TargetStartLat,
        
        [Parameter(Mandatory = $true)]
        [double]$TargetStartLon,
        
        [Parameter(Mandatory = $true)]
        [double]$TargetEndLat,
        
        [Parameter(Mandatory = $true)]
        [double]$TargetEndLon,
        
        [Parameter(Mandatory = $true)]
        [double]$ClipDuration,
        
        [Parameter(Mandatory = $true)]
        [double]$SearchWindowStart,
        
        [Parameter(Mandatory = $true)]
        [double]$SearchWindowEnd,
        
        [Parameter(Mandatory = $false)]
        [double]$FadeOverlapDuration = 0.0,
        
        [Parameter(Mandatory = $false)]
        [double]$MasterEndLat = [double]::NaN,
        
        [Parameter(Mandatory = $false)]
        [double]$MasterEndLon = [double]::NaN
    )
    
    $bestMatch = $null
    $bestScore = [double]::PositiveInfinity
    $bestFailedMatch = $null
    $failureReason = "No GPS points found in search window"
    
    # Define duration search range
    $minDuration = $ClipDuration * $Script:ScoringConfig.MinDurationMultiplier
    $maxDuration = $ClipDuration * $Script:ScoringConfig.MaxDurationMultiplier
    
    # Thresholds
    $maxDistance = $Script:ScoringConfig.MaxDistanceMeters
    $startThreshold = $maxDistance * $Script:ScoringConfig.StartDistanceMultiplier
    
    $pointsInWindow = 0
    $startPointsChecked = 0
    $bestStartDistance = [double]::PositiveInfinity
    $bestEndDistance = [double]::PositiveInfinity
    $bestFailedScore = [double]::PositiveInfinity
    
    foreach ($startPoint in $GpsPoints) {
        # Filter by time window
        if ($startPoint.t -lt $SearchWindowStart -or $startPoint.t -gt $SearchWindowEnd) {
            continue
        }
        
        $pointsInWindow++
        
        # For fade overlap, we need to match the GPS point BEFORE the actual start
        # This ensures GPS continuity during the crossfade transition
        $matchPoint = $startPoint
        if ($FadeOverlapDuration -gt 0) {
            # Find the GPS point at (startPoint.t - FadeOverlapDuration)
            $overlapTime = $startPoint.t - $FadeOverlapDuration
            $matchPoint = Get-NearestGpsPoint -GpsPoints $GpsPoints -TargetTime $overlapTime
            
            # If the overlap point is too far back in time, skip this start point
            if (-not $matchPoint -or [Math]::Abs($matchPoint.t - $overlapTime) -gt ($FadeOverlapDuration * 0.5)) {
                continue
            }
        }
        
        # Check start position match - must be very precise
        # When using fade overlap, this checks the GPS at (ClipStart - FadeOverlapDuration)
        $startDistance = Get-HaversineDistance -Lat1 $TargetStartLat -Lon1 $TargetStartLon `
            -Lat2 $matchPoint.lat -Lon2 $matchPoint.lon
        
        if ($startDistance -lt $bestStartDistance) {
            $bestStartDistance = $startDistance
        }
        
        if ($startDistance -gt $startThreshold) {
            $startPointsChecked++
            continue
        }
        
        # Search for the best end point within the duration range
        $potentialEndPoints = $GpsPoints | Where-Object {
            $duration = $_.t - $startPoint.t
            $duration -ge $minDuration -and $duration -le $maxDuration
        }
        
        if ($potentialEndPoints.Count -eq 0) {
            if ($failureReason -eq "No GPS points found in search window") {
                $failureReason = "No valid end points within duration range ($($minDuration.ToString('N1'))s - $($maxDuration.ToString('N1'))s)"
            }
            continue
        }
        
        foreach ($endPoint in $potentialEndPoints) {
            # Check end position match
            $endDistance = Get-HaversineDistance -Lat1 $TargetEndLat -Lon1 $TargetEndLon `
                -Lat2 $endPoint.lat -Lon2 $endPoint.lon
            
            if ($endDistance -lt $bestEndDistance) {
                $bestEndDistance = $endDistance
            }
            
            $actualDuration = $endPoint.t - $startPoint.t
            $durationDeviation = [Math]::Abs($actualDuration - $ClipDuration)
            
            # Calculate master timeline deviation if master coordinates provided
            $masterDeviation = 0.0
            if (-not [double]::IsNaN($MasterEndLat) -and -not [double]::IsNaN($MasterEndLon)) {
                $masterDeviation = Get-HaversineDistance `
                    -Lat1 $MasterEndLat -Lon1 $MasterEndLon `
                    -Lat2 $endPoint.lat -Lon2 $endPoint.lon
            }
            
            # Get score using shared scoring function
            $scoreResult = Get-GpsMatchScore `
                -StartDistance $startDistance `
                -EndDistance $endDistance `
                -DurationDeviation $durationDeviation `
                -TargetDuration $ClipDuration `
                -MasterDeviation $masterDeviation
            
            # Track best attempt even if it fails validation
            if ($scoreResult.TotalScore -lt $bestFailedScore) {
                $bestFailedScore = $scoreResult.TotalScore
                $bestFailedMatch = @{
                    StartDistance     = $startDistance
                    EndDistance       = $endDistance
                    MasterDeviation   = $masterDeviation
                    DurationDeviation = $durationDeviation
                    ClipStart         = $startPoint.t
                    ClipEnd           = $endPoint.t
                    ClipDuration      = $actualDuration
                    CombinedScore     = $scoreResult.TotalScore
                    ScoreBreakdown    = $scoreResult
                    IsValid           = ($scoreResult.IsStartValid -and $scoreResult.IsEndValid)
                    FailureReason     = if (-not $scoreResult.IsStartValid) {
                        "Start GPS distance too large ($($startDistance.ToString('N1'))m > $($startThreshold.ToString('N1'))m threshold)"
                    } elseif (-not $scoreResult.IsEndValid) {
                        "End GPS distance too large ($($endDistance.ToString('N1'))m > $($maxDistance.ToString('N1'))m threshold)"
                    } else {
                        $null
                    }
                }
            }
            
            if ($endDistance -gt $maxDistance) {
                continue
            }
            
            if ($scoreResult.TotalScore -lt $bestScore) {
                $bestScore = $scoreResult.TotalScore
                $bestMatch = @{
                    StartPoint        = $startPoint
                    EndPoint          = $endPoint
                    StartDistance     = $startDistance
                    EndDistance       = $endDistance
                    MasterDeviation   = $masterDeviation
                    DurationDeviation = $durationDeviation
                    ClipStart         = $startPoint.t
                    ClipEnd           = $endPoint.t
                    ClipDuration      = $actualDuration
                    CombinedScore     = $scoreResult.TotalScore
                    ScoreBreakdown    = $scoreResult
                    TimingError       = $durationDeviation  # For backward compatibility
                    IsValid           = $true
                }
            }
        }
    }
    
    # If no valid match, return best failed attempt with details
    if (-not $bestMatch -and $bestFailedMatch) {
        return $bestFailedMatch
    }
    
    if (-not $bestMatch) {
        # Generate detailed failure reason
        if ($pointsInWindow -eq 0) {
            $failureReason = "No GPS points in search window ($($SearchWindowStart.ToString('N1'))s - $($SearchWindowEnd.ToString('N1'))s)"
        } elseif ($startPointsChecked -gt 0) {
            $failureReason = "Start GPS distance too large (best: $($bestStartDistance.ToString('N1'))m > $($startThreshold.ToString('N1'))m threshold)"
        }
        
        return @{
            IsValid = $false
            FailureReason = $failureReason
            BestStartDistance = $bestStartDistance
            BestEndDistance = $bestEndDistance
            PointsInWindow = $pointsInWindow
        }
    }
    
    return $bestMatch
}

# Functions are automatically available when dot-sourced
# No Export-ModuleMember needed for .ps1 files

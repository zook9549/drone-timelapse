<#
    Usage examples:
      .\copy.ps1 -Src "D:\DCIM\DJI_001" -Dst "\timelapse\full" -MinSize "2.247483648GB" -MaxSize "2.647483648GB"
#>

param(
    [Parameter(Mandatory = $true)][string]$Src,
    [Parameter(Mandatory = $true)][string]$Dst,
    [Parameter(Mandatory = $true)][string]$MinSize,
    [Parameter(Mandatory = $true)][string]$MaxSize,
    [string]$Filter = '*.mp4',
    [switch]$Recurse
)

function Convert-ToBytes {
    param([string]$Size)

    if ($null -eq $Size) { return 0 }
    $size = $Size.Trim()
    if ($size -match '^[0-9]+$') { return [int64]$size }

    if ($size -match '^\s*(\d+(\.\d+)?)\s*(KB|MB|GB|TB)?\s*$') {
        $num = [double]$matches[1]
        $unit = ($matches[3] -as [string]).ToUpper()
        switch ($unit) {
            'KB' { $mul = 1KB }
            'MB' { $mul = 1MB }
            'GB' { $mul = 1GB }
            'TB' { $mul = 1TB }
            default { $mul = 1 } # bytes if no unit
        }
        return [int64]([math]::Floor($num * $mul))
    }

    throw "Unable to parse size: $Size"
}

$minBytes = Convert-ToBytes $MinSize
$maxBytes = Convert-ToBytes $MaxSize

if (-not (Test-Path $Src -PathType Container)) {
    throw "Source path '$Src' does not exist or is not a directory."
}

if (-not (Test-Path $Dst)) {
    New-Item -Path $Dst -ItemType Directory -Force | Out-Null
}

$gciParams = @{
    Path  = $Src
    Filter = $Filter
    File  = $true
}
if ($Recurse) { $gciParams.Add('Recurse', $true) }

Get-ChildItem @gciParams |
    Where-Object { ($_.Length -ge $minBytes) -and ($_.Length -le $maxBytes) } |
    ForEach-Object {
        $dest = Join-Path $Dst $_.Name
        $destX = $dest + 'x'
        if (-not (Test-Path $dest) -and -not (Test-Path $destX)) {
            Write-Output "Copying $($_.Name) to $Dst"
            Copy-Item -Path $_.FullName -Destination $dest -Force
        }        
        # Copy corresponding .srt (same base name) if it exists in the source folder
        $base = [io.path]::GetFileNameWithoutExtension($_.Name)
        $srtSrc = Join-Path $_.DirectoryName ($base + '.srt')
        if (Test-Path $srtSrc) {
            $srtDest = Join-Path $Dst ($base + '.srt')
            $srtDestX = $srtDest + 'x'
            if (-not (Test-Path $srtDest) -and -not (Test-Path $srtDestX)) {
                Write-Output "Copying SRT coordinates $([io.path]::GetFileName($srtSrc)) to $Dst"
                Copy-Item -Path $srtSrc -Destination $srtDest -Force
            }
        }
    }
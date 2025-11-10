<#  
.SYNOPSIS
  Upload a file or folder to Amazon S3 (overwrites if it exists).
  Uses AWS CLI if available; otherwise falls back to AWSPowerShell.NetCore.

.EXAMPLES
  # Upload a single file (key defaults to file name)
  .\Upload-ToS3.ps1 -SourcePath "F:\fenton\timelapse\buildable.mp4" -Bucket "my-drone-archive"

  # Upload single file to a specific key, set content-type and cache-control
  .\Upload-ToS3.ps1 -SourcePath "buildable.mp4" -Bucket "my-bucket" -Key "timelapse/buildable.mp4" `
    -ContentType "video/mp4" -CacheControl "public, max-age=31536000"

  # Upload entire folder (recursively) under a prefix, with AES256 server-side encryption
  .\Upload-ToS3.ps1 -SourcePath "F:\fenton\timelapse\out" -Bucket "my-bucket" -KeyPrefix "timelapse/" -SSE AES256

  # Upload using an AWS named profile and region, Intelligent Tiering storage class
  .\Upload-ToS3.ps1 -SourcePath "F:\fenton\timelapse\buildable.mp4" -Bucket "my-bucket" `
    -Region "us-east-2" -Profile "default" -StorageClass INTELLIGENT_TIERING
#>

param(
  # File or folder to upload
  [Parameter(Mandatory=$true)]
  [string]$SourcePath,

  # S3 destination
  [Parameter(Mandatory=$true)]
  [string]$Bucket,

  # Object key for single-file uploads. If omitted, uses the file name.
  [string]$Key,

  # For folder uploads, objects go under this prefix (e.g., "timelapse/"). Optional for files.
  [string]$KeyPrefix = "",

  # AWS region/profile (optional – otherwise default credential chain)
  [string]$Region,
  [string]$Profile,

  # Storage class & encryption
  [ValidateSet('STANDARD','STANDARD_IA','ONEZONE_IA','INTELLIGENT_TIERING','GLACIER_IR','GLACIER','DEEP_ARCHIVE')]
  [string]$StorageClass = 'STANDARD',

  # Server-side encryption: '' (none), 'AES256', 'aws:kms'
  [ValidateSet('','AES256','aws:kms')]
  [string]$SSE = '',

  # When SSE = aws:kms, optionally provide a KMS Key Id/Arn (CLI: --sse-kms-key-id)
  [string]$KmsKeyId,

  # Content-Type & Cache-Control (used for single-file uploads; folder uploads let the tool infer)
  [string]$ContentType,
  [string]$CacheControl,

  # Make object publicly readable (CLI: --acl public-read / PS: CannedACL)
  [switch]$PublicRead
)

$ErrorActionPreference = 'Stop'

# --- Helpers ---
function Test-CommandExists([string]$name) {
  try { return [bool](Get-Command $name -ErrorAction Stop) } catch { return $false }
}

# Simple content-type mapping (used only if -ContentType not provided)
$MimeMap = @{
  ".mp4"="video/mp4"; ".mov"="video/quicktime"; ".mkv"="video/x-matroska"; ".avi"="video/x-msvideo";
  ".jpg"="image/jpeg"; ".jpeg"="image/jpeg"; ".png"="image/png"; ".gif"="image/gif"; ".webp"="image/webp";
  ".json"="application/json"; ".txt"="text/plain"; ".srt"="application/x-subrip"
}

function Guess-ContentType([string]$path) {
  if ($ContentType) { return $ContentType }
  $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
  if ($MimeMap.ContainsKey($ext)) { return $MimeMap[$ext] }
  return "application/octet-stream"
}

# --- Validate input ---
if (-not (Test-Path -LiteralPath $SourcePath)) {
  throw "SourcePath not found: $SourcePath"
}
$useCli = Test-CommandExists "aws"
$usePs  = -not $useCli

if ($usePs -and -not (Get-Module -ListAvailable -Name AWSPowerShell.NetCore)) {
  throw "AWS CLI not found and AWSPowerShell.NetCore module not installed. Install one of them."
}

# --- Build destination strings ---
$SourceIsDirectory = (Get-Item -LiteralPath $SourcePath).PSIsContainer

if ($SourceIsDirectory) {
  # Folder upload → require/derive a prefix
  if ($Key) {
    Write-Host "Ignoring -Key for folder upload; using -KeyPrefix '$KeyPrefix' instead." -ForegroundColor Yellow
  }
  if ($KeyPrefix -and -not $KeyPrefix.EndsWith("/")) { $KeyPrefix = $KeyPrefix + "/" }
  Write-Host ("Uploading folder '{0}' to s3://{1}/{2}" -f $SourcePath, $Bucket, $KeyPrefix)
} else {
  # Single file
  if (-not $Key -or $Key.Trim() -eq "") {
    $Key = [IO.Path]::GetFileName($SourcePath)
  }
  # If both KeyPrefix and Key are set, combine them
  if ($KeyPrefix) {
    if (-not $KeyPrefix.EndsWith("/")) { $KeyPrefix = $KeyPrefix + "/" }
    $Key = $KeyPrefix + $Key
  }
  Write-Host ("Uploading file '{0}' to s3://{1}/{2}" -f $SourcePath, $Bucket, $Key)
}

# --- Upload using AWS CLI (preferred) ---
if ($useCli) {
  if ($SourceIsDirectory) {
    # aws s3 sync (overwrites by default)
    $dst = "s3://$Bucket/$KeyPrefix"
    $args = @("s3","sync",$SourcePath,$dst,"--no-progress","--storage-class",$StorageClass)
    if ($Profile) { $args += @("--profile",$Profile) }
    if ($Region)  { $args += @("--region",$Region)  }
    if ($SSE)     { $args += @("--sse",$SSE) }
    if ($SSE -eq "aws:kms" -and $KmsKeyId) { $args += @("--sse-kms-key-id",$KmsKeyId) }
    if ($PublicRead) { $args += @("--acl","public-read") }

    Write-Host ("AWS CLI: aws {0}" -f ($args -join ' '))
    $p = Start-Process -FilePath "aws" -ArgumentList $args -NoNewWindow -PassThru -Wait
    if ($p.ExitCode -ne 0) { throw "aws s3 sync failed with exit code $($p.ExitCode)" }
  } else {
    # aws s3 cp (overwrites by default)
    $dst = "s3://$Bucket/$Key"
    # ContentType: add explicit if provided or guessed
    $ct = Guess-ContentType $SourcePath
    $args = @("s3","cp",$SourcePath,$dst,"--no-progress","--storage-class",$StorageClass,"--content-type",$ct)
    if ($CacheControl) { $args += @("--cache-control",$CacheControl) }
    if ($Profile) { $args += @("--profile",$Profile) }
    if ($Region)  { $args += @("--region",$Region)  }
    if ($SSE)     { $args += @("--sse",$SSE) }
    if ($SSE -eq "aws:kms" -and $KmsKeyId) { $args += @("--sse-kms-key-id",$KmsKeyId) }
    if ($PublicRead) { $args += @("--acl","public-read") }

    Write-Host ("AWS CLI: aws {0}" -f ($args -join ' '))
    $p = Start-Process -FilePath "aws" -ArgumentList $args -NoNewWindow -PassThru -Wait
    if ($p.ExitCode -ne 0) { throw "aws s3 cp failed with exit code $($p.ExitCode)" }
  }

  Write-Host "✅ S3 upload complete (AWS CLI)."
  exit 0
}

# --- Fallback: AWSPowerShell.NetCore ---
Import-Module AWSPowerShell.NetCore -ErrorAction Stop

# Build common args
$common = @{
  BucketName   = $Bucket
  StorageClass = $StorageClass
  CannedACL    = $(if ($PublicRead) { "public-read" } else { "bucket-owner-full-control" })
  Force        = $true   # overwrite
}
if ($Profile) { $common["ProfileName"] = $Profile }
if ($Region)  { $common["Region"]      = $Region  }
if ($SSE)     { $common["ServerSideEncryptionMethod"] = $SSE }
if ($SSE -eq "aws:kms" -and $KmsKeyId) { $common["ServerSideEncryptionKeyManagementServiceKeyId"] = $KmsKeyId }

if ($SourceIsDirectory) {
  if ($KeyPrefix) { $common["KeyPrefix"] = $KeyPrefix }
  $common["Folder"] = $SourcePath
  Write-Host ("AWSPowerShell: Write-S3Object {0}" -f ($common.Keys | ForEach-Object { "-${_}:$($common[$_])" } -join ' '))
  Write-S3Object @common | Out-Null
} else {
  $ct = Guess-ContentType $SourcePath
  $common["File"]        = $SourcePath
  $common["Key"]         = $Key
  $common["ContentType"] = $ct
  if ($CacheControl) { $common["Headers"] = @{ "Cache-Control" = $CacheControl } }

  Write-Host ("AWSPowerShell: Write-S3Object {0}" -f ($common.Keys | ForEach-Object { "-${_}:$($common[$_])" } -join ' '))
  Write-S3Object @common | Out-Null
}

Write-Host "✅ S3 upload complete (AWSPowerShell)."

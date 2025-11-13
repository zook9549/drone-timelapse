# GPS-Synced Timelapse Video Creator

A suite of PowerShell scripts for creating GPS-synchronized timelapse videos from drone footage using consistent waypoint paths, and uploading them to YouTube or Amazon S3.

## Overview

This toolset enables you to:
- **Create timelapse videos** from multiple drone flights following consistent waypoint paths with GPS data synchronization
- **Upload videos to YouTube** with automatic replacement of existing videos
- **Upload videos to Amazon S3** for archival or CDN distribution

## Requirements

### Software
- **PowerShell 7.0+** - [Download here](https://github.com/PowerShell/PowerShell/releases)
- **FFmpeg** - Video processing tool ([Download](https://ffmpeg.org/download.html))
- **FFprobe** - Video metadata tool (included with FFmpeg)

### Optional
- **AWS CLI** or **AWSPowerShell.NetCore** module (for S3 uploads)
- **YouTube OAuth credentials** (for YouTube uploads)

## Scripts

### 1. Timelapse Creator (`timelapse.ps1`)

Creates GPS-synchronized timelapse videos from multiple drone flights that follow consistent waypoint paths. By matching GPS coordinates using a hybrid approach, the script seamlessly merges footage from multiple flights into a single round-robin timelapse video with smooth transitions while maintaining path consistency.

#### Features
- **Hybrid GPS Matching** - Balances smooth transitions with master timeline path adherence
- Extracts clips from multiple drone videos in round-robin fashion
- Intelligent scoring system that considers start/end GPS accuracy, duration, and path deviation
- Applies crossfade transitions with GPS continuity during fades
- Adds optional random background music with fade in/out
- GPU-accelerated encoding (NVENC) with automatic CPU fallback
- High-quality output (CRF 18 - visually lossless)
- Configurable clip length, fade duration, and frame rate
- Optional master video selection for custom GPS timeline reference

#### Usage

```powershell
# Basic usage with default settings (5s clips, 1s fade, 30fps)
.\timelapse.ps1 -InputFolder "C:\DroneFootage\Flight01"

# Custom settings
.\timelapse.ps1 -InputFolder "C:\DroneFootage\Flight01" -ClipLengthSec 3 -FadeDurationSec 0.5 -Fps 60

# Keep temporary files for debugging
.\timelapse.ps1 -InputFolder "C:\DroneFootage\Flight01" -KeepTemps

# Enable verbose output for troubleshooting
.\timelapse.ps1 -InputFolder "C:\DroneFootage\Flight01" -Verbose

# Use specific video as GPS timeline reference
.\timelapse.ps1 -InputFolder "C:\DroneFootage\Flight01" -MasterVideo "GX010123.mp4"
```

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `InputFolder` | String | *Required* | Path to folder containing MP4 files and corresponding SRT files |
| `ClipLengthSec` | Integer | 5 | Length of each clip in seconds (1-60) |
| `FadeDurationSec` | Double | 1.0 | Duration of crossfade transitions (0.1-5.0) |
| `Fps` | Integer | 30 | Output video frame rate (15-60) |
| `MasterVideo` | String | *first video* | Name of video file to use as GPS timeline reference (e.g., 'GX010123.mp4') |
| `KeepTemps` | Switch | False | Keep temporary files after processing |

#### Input Requirements

Your input folder should contain:
- **MP4 video files** - Drone footage from flights following the same waypoint path
- **Corresponding SRT files** - GPS data with the same base filename
  - Example: `flight01.mp4` and `flight01.srt`

**Important:** For best results, all drone flights should follow the same waypoint path to ensure GPS coordinates align for smooth transitions between clips.

#### Audio Overlay

To add background music:
1. Create a `music` folder in the same parent directory as your input folder
2. Place MP3 files in the music folder
3. The script will randomly select one MP3 and loop it to match video duration
4. Automatic fade in (2s) and fade out (2s) applied

#### Output

The script creates:
- **Final video** - Named after the input folder (e.g., `Flight01.mp4`)
- **Location** - Saved in the parent directory of your input folder

---

### 2. YouTube Uploader (`upload-youtube.ps1`)

Uploads videos to YouTube with options to replace existing videos atomically (upload new, then delete old).

#### Features
- Upload new videos to YouTube
- Find and replace existing videos by tag or video ID
- Preserve or update video metadata (title, description, tags)
- Atomic replacement (upload completes before deletion)
- OAuth 2.0 authentication via refresh token

#### Usage

```powershell
# Upload new video (simple)
.\upload-youtube.ps1 -AuthFile "oauth-credentials.json" -NewVideoFile "video.mp4"

# Upload and replace existing video by tag
.\upload-youtube.ps1 -AuthFile "oauth-credentials.json" `
  -NewVideoFile "Flight01.mp4" `
  -LookupTag "flight01-timelapse" `
  -ReplacementPrivacyStatus "unlisted"

# Upload with custom metadata
.\upload-youtube.ps1 -AuthFile "oauth-credentials.json" `
  -NewVideoFile "Flight01.mp4" `
  -ReplacementTitle "Drone Waypoint Flight Day 1" `
  -ReplacementDescription "Timelapse from multiple drone flights" `
  -ReplacementTags @("drone", "timelapse", "aerial") `
  -ReplacementPrivacyStatus "public"

# Replace specific video by ID
.\upload-youtube.ps1 -AuthFile "oauth-credentials.json" `
  -NewVideoFile "Flight01.mp4" `
  -VideoId "dQw4w9WgXcQ"
```

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `AuthFile` | String | *Required* | Path to JSON file with OAuth credentials |
| `NewVideoFile` | String | *Required* | Path to video file to upload |
| `ReplacementPrivacyStatus` | String | unlisted | Privacy status: public, unlisted, or private |
| `ReplacementTitle` | String | *filename* | Video title |
| `ReplacementDescription` | String | "" | Video description |
| `ReplacementTags` | Array | *filename* | Array of tags |
| `VideoId` | String | - | Explicit ID of video to replace |
| `LookupTag` | String | - | Find video to replace by searching for this tag |

#### OAuth Setup

1. **Create OAuth credentials** in [Google Cloud Console](https://console.cloud.google.com/):
   - Enable YouTube Data API v3
   - Create OAuth 2.0 credentials (Desktop app type)

2. **Get refresh token** using [OAuth 2.0 Playground](https://developers.google.com/oauthplayground/):
   - Configure with your client ID and secret
   - Authorize YouTube Data API v3 scope
   - Exchange authorization code for tokens

3. **Create auth JSON file**:
```json
{
  "client_id": "your-client-id.apps.googleusercontent.com",
  "client_secret": "your-client-secret",
  "refresh_token": "your-refresh-token",
  "token_uri": "https://oauth2.googleapis.com/token"
}
```

#### Video Replacement Logic

When using `-LookupTag`:
1. Searches your channel's uploads for a video with matching tag
2. Uploads new video with metadata from old video (unless overridden)
3. Merges tags from both videos (removing duplicates)
4. Deletes old video after successful upload

---

### 3. S3 Uploader (`upload-s3.ps1`)

Uploads files or entire folders to Amazon S3 with support for various storage classes and encryption options.

#### Features
- Upload single files or entire directories
- Automatic content-type detection
- Multiple storage classes (Standard, Intelligent Tiering, Glacier, etc.)
- Server-side encryption (AES256 or KMS)
- Public read access option
- Automatic tool selection (AWS CLI preferred, PowerShell module fallback)

#### Usage

```powershell
# Upload single file
.\upload-s3.ps1 -SourcePath "video.mp4" -Bucket "my-bucket"

# Upload to specific key with custom settings
.\upload-s3.ps1 -SourcePath "Flight01.mp4" `
  -Bucket "my-archive" `
  -Key "videos/2024/flight01.mp4" `
  -StorageClass "INTELLIGENT_TIERING" `
  -ContentType "video/mp4" `
  -CacheControl "public, max-age=31536000"

# Upload entire folder recursively
.\upload-s3.ps1 -SourcePath "C:\DroneFootage\Flight01" `
  -Bucket "my-archive" `
  -KeyPrefix "videos/flight01/" `
  -SSE "AES256"

# Upload with KMS encryption
.\upload-s3.ps1 -SourcePath "video.mp4" `
  -Bucket "my-bucket" `
  -SSE "aws:kms" `
  -KmsKeyId "arn:aws:kms:us-east-1:123456789012:key/your-key-id"

# Upload with AWS profile and region
.\upload-s3.ps1 -SourcePath "video.mp4" `
  -Bucket "my-bucket" `
  -Profile "production" `
  -Region "us-west-2"

# Make publicly readable
.\upload-s3.ps1 -SourcePath "video.mp4" `
  -Bucket "my-cdn-bucket" `
  -PublicRead
```

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `SourcePath` | String | *Required* | File or folder to upload |
| `Bucket` | String | *Required* | S3 bucket name |
| `Key` | String | *filename* | Object key for single files |
| `KeyPrefix` | String | "" | Prefix for folder uploads |
| `Region` | String | *default* | AWS region |
| `Profile` | String | *default* | AWS credential profile |
| `StorageClass` | String | STANDARD | Storage class (see below) |
| `SSE` | String | "" | Server-side encryption (none, AES256, aws:kms) |
| `KmsKeyId` | String | - | KMS key ID/ARN (when using KMS encryption) |
| `ContentType` | String | *auto* | MIME type for single files |
| `CacheControl` | String | - | Cache-Control header |
| `PublicRead` | Switch | False | Make object publicly readable |

#### Storage Classes

- `STANDARD` - Standard storage (default)
- `STANDARD_IA` - Infrequent Access
- `ONEZONE_IA` - One Zone Infrequent Access
- `INTELLIGENT_TIERING` - Automatic cost optimization
- `GLACIER_IR` - Glacier Instant Retrieval
- `GLACIER` - Glacier Flexible Retrieval
- `DEEP_ARCHIVE` - Glacier Deep Archive

#### AWS Credentials

The script uses standard AWS credential chain:
1. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
2. AWS credential file (`~/.aws/credentials`)
3. IAM role (when running on EC2/ECS)

Or specify a named profile with `-Profile` parameter.

---

## Complete Workflow Example

```powershell
# Step 1: Create timelapse from drone flights following the same waypoint path
.\timelapse.ps1 -InputFolder "C:\DroneFootage\DailyFlight" -ClipLengthSec 4 -Fps 60

# Step 2: Upload to YouTube and replace existing video
.\upload-youtube.ps1 -AuthFile "youtube-oauth.json" `
  -NewVideoFile "C:\DroneFootage\DailyFlight.mp4" `
  -LookupTag "daily-waypoint-timelapse" `
  -ReplacementPrivacyStatus "public"

# Step 3: Archive to S3
.\upload-s3.ps1 -SourcePath "C:\DroneFootage\DailyFlight.mp4" `
  -Bucket "my-video-archive" `
  -KeyPrefix "timelapses/2024/" `
  -StorageClass "GLACIER_IR" `
  -SSE "AES256"
```

## Configuration

### GPS Matching Thresholds

The timelapse creator uses configurable thresholds for GPS synchronization to match waypoints across multiple drone flights:
- Maximum GPS coordinate matching distance
- Time window for searching GPS points
- Maximum timing error tolerance
- Minimum clip durations

These can be adjusted by editing the configuration constants at the top of `timelapse.ps1`. Fine-tuning these settings ensures smooth transitions when merging clips from different flights along the same waypoint path.

### Video Encoding

The timelapse creator supports:
- **GPU encoding** (NVIDIA NVENC) - Attempted first for faster processing
- **CPU encoding** (libx264) - Automatic fallback if GPU unavailable
- Configurable quality settings (CRF/CQ values)
- Multiple preset options for speed/quality trade-off

## Troubleshooting

### Timelapse Creator Issues

**Problem:** "No MP4 files found"
- Ensure input folder contains `.mp4` video files from drone flights
- Check file permissions

**Problem:** "Missing SRT file"
- Each MP4 file needs a corresponding `.srt` file with the same base name
- SRT files must contain GPS coordinates in the format `latitude: XX.XXXXX longitude: YY.YYYYY`
- Ensure your drone or video processing software exports GPS data in SRT format

**Problem:** "Not enough clips extracted"
- GPS data may be insufficient or mismatched between flights
- Ensure all drone flights follow the same waypoint path
- Try increasing GPS matching thresholds
- Use `-Verbose` flag to see detailed extraction logs

**Problem:** GPU encoding fails
- Install latest NVIDIA drivers
- Script automatically falls back to CPU encoding
- CPU encoding is slower but produces same quality

### YouTube Upload Issues

**Problem:** OAuth authentication fails
- Verify OAuth credentials are correct in JSON file
- Ensure refresh token hasn't expired (regenerate if needed)
- Check YouTube Data API v3 is enabled in Google Cloud Console

**Problem:** Video not found by tag
- Tag search is case-insensitive by default
- Ensure the tag exists on one of your uploaded videos
- Try using `-VideoId` instead for explicit targeting

### S3 Upload Issues

**Problem:** "AWS CLI not found"
- Install AWS CLI: `winget install Amazon.AWSCLI`
- Or install PowerShell module: `Install-Module -Name AWSPowerShell.NetCore`

**Problem:** Authentication fails
- Configure AWS credentials: `aws configure`
- Or specify profile: `-Profile "your-profile-name"`
- Verify IAM permissions for S3 bucket access

## Performance Tips

1. **Use GPU encoding** - Install NVIDIA drivers for 5-10x faster video processing
2. **SSD storage** - Process videos on SSD for better I/O performance
3. **Batch processing** - Process multiple flight sets sequentially using a loop
4. **Pre-process videos** - Trim unnecessary footage before creating timelapses
5. **Parallel uploads** - Upload to YouTube and S3 simultaneously using separate PowerShell windows
6. **Consistent waypoints** - Ensure all drone flights follow the exact same waypoint path for best GPS matching and smooth transitions

## License

These scripts are provided as-is for personal or commercial use. Modify as needed for your workflow.

## Support

For issues or questions:
- Check the troubleshooting section above
- Use `-Verbose` flag for detailed logging
- Review PowerShell error messages for specific issues
- Ensure all prerequisites are installed and accessible in PATH

---

**Version:** 2.0  
**Last Updated:** 2024  
**PowerShell Version Required:** 7.0+

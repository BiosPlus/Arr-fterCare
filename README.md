## arrftercare.sh

`arrftercare.sh` is a Bash script designed to enhance the post-processing of media files managed by Sonarr and Radarr. It automates tasks such as crop detection, audio stream handling, and video encoding to ensure optimal file quality and size.

### Features

- **Event Validation**: Processes only `download` events triggered by Sonarr or Radarr.
- **Crop Detection**: Automatically detects and applies crop values to remove black bars from videos.
- **Audio Stream Handling**: Re-encodes TrueHD audio streams to AC3 while preserving other audio streams.
- **Bitrate Estimation**: Ensures the output video bitrate matches the original for consistent quality.
- **File Management**: Marks processed files and skips already post-processed ones.
- **Error Handling**: Creates backups and restores original files in case of encoding failures.

### Requirements

- `ffmpeg` and `ffprobe` must be installed and available in the system's PATH.

### Usage

This script is intended to be triggered automatically by Sonarr or Radarr during their post-processing workflows. Ensure the environment variables `radarr_eventtype`, `radarr_moviefile_path`, `sonarr_eventtype`, or `sonarr_episodefile_path` are correctly set by the calling application.

### How It Works

1. Validates the event type to ensure it's a `download` event.
2. Detects crop values using `ffmpeg` and applies them during re-encoding.
3. Handles audio streams intelligently, re-encoding TrueHD streams to AC3.
4. Encodes the video with the detected crop values, maintaining the original bitrate.
5. Deletes the original file after successful processing or restores it in case of failure.

### Notes

- The script uses a temporary log file for crop detection, which is automatically cleaned up after execution.
- Files already marked as post-processed (with `[PPd]` in the filename) are skipped.

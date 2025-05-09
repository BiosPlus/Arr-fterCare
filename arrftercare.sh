#!/bin/bash

# Fail fast on error
set -e

# Set internal field separator for safety
IFS=$'\n'

# Function for soft exit
soft_exit() {
  log_message "Info" "$(timestamp) ℹ️  $1"
  exit 0
}

# Function for hard exit
hard_exit() {
  log_message "Info" "$(timestamp) ❌ $1"
  exit 1
}

# Function to get the current timestamp
timestamp() {
  echo "$(date +'%Y-%m-%d %H:%M:%S')"
}


# Function to log messages with levels
log_message() {
  local level="$1"
  local message="$2"
  case "$level" in
    Debug) echo "$message" ;;
    Info) echo "$message" >&2 ;;
    Trace) echo "$message" >&2 ;;
    *) echo "Unknown log level: $level" >&2 ;;
  esac
}

# Ensure required tools are installed
if ! command -v ffmpeg &>/dev/null || ! command -v ffprobe &>/dev/null; then
  hard_exit "ffmpeg and/or ffprobe not found. Please install them."
fi

# Trap to clean up temporary files on exit
TMP_LOG=$(mktemp /tmp/cropdetect_log.XXXXXX)
trap 'rm -f "$TMP_LOG"' EXIT

# Determine the event type and validate it
EVENT_TYPE=""
if [ -n "$radarr_eventtype" ]; then
  EVENT_TYPE="$radarr_eventtype"
elif [ -n "$sonarr_eventtype" ]; then
  EVENT_TYPE="$sonarr_eventtype"
fi

if [ "$EVENT_TYPE" == "Test" ]; then
  log_message "Test event detected. Exiting gracefully."
  exit 0
fi

if [ "$EVENT_TYPE" != "Download" ]; then
  soft_exit "Not a download event, skipping."
fi

# Determine the input file path
if [ -n "$radarr_moviefile_path" ]; then
  INPUT="$radarr_moviefile_path"
elif [ -n "$sonarr_episodefile_path" ]; then
  INPUT="$sonarr_episodefile_path"
else
  hard_exit "No valid input file path found."
fi

# Validate the input file path
if [[ ! -f "$INPUT" ]]; then
  hard_exit "Input file does not exist: $INPUT"
fi

# Extract file details
DIRNAME="$(dirname "$INPUT")"
FILENAME="$(basename "$INPUT")"
EXT="${FILENAME##*.}"  # Extract file extension
NAME="${FILENAME%.*}"  # Extract file name without extension
OUTPUT="$DIRNAME/${NAME} [PPd].${EXT}"  # Define output file path

# Skip if already post-processed
if [[ "$FILENAME" == *"[PPd]."* ]]; then
  soft_exit "File already marked as post-processed. Skipping."
fi

# Ensure input exists
if [[ ! -f "$INPUT" ]]; then
  hard_exit "File not found: $INPUT"
fi

# Detect crop
log_message "Debug" "$(timestamp) 🕵️ Detecting crop value from: $INPUT"
if ! ffmpeg -ss 120 -i "$INPUT" -vf "select=not(mod(n\,100)),cropdetect" -an -f null - 2>&1 | grep 'crop=' | tail -n 1 > "$TMP_LOG"; then
  hard_exit "Failed to run crop detection."
fi

CROP=$(grep 'crop=' "$TMP_LOG" | tail -n 1 | sed -n 's/.*\(crop=[0-9:]*\).*/\1/p')
if [[ -z "$CROP" ]]; then
  log_message "Info" "$(timestamp) ⚠️  Failed to detect crop value. Defaulting to no crop."
  CROP="null"
else
  log_message "Debug" "$(timestamp) ✅ Crop detected: $CROP"
fi

if [[ "$CROP" != "null" ]]; then
  WIDTH=$(echo "$CROP" | sed -n 's/.*crop=\([0-9]*\):\([0-9]*\):\([0-9]*\):\([0-9]*\).*/\1/p')
  HEIGHT=$(echo "$CROP" | sed -n 's/.*crop=\([0-9]*\):\([0-9]*\):\([0-9]*\):\([0-9]*\).*/\2/p')
  Y_OFFSET=$(echo "$CROP" | sed -n 's/.*crop=\([0-9]*\):\([0-9]*\):\([0-9]*\):\([0-9]*\).*/\4/p')

  ORIGINAL_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")

  if [[ -n "$HEIGHT" && -n "$Y_OFFSET" && -n "$ORIGINAL_HEIGHT" ]]; then
    REMOVED_PIXELS=$((ORIGINAL_HEIGHT - HEIGHT - Y_OFFSET))
    if ((REMOVED_PIXELS < 20)); then
      soft_exit "Less than 20 pixels removed from height. Exiting process."
    fi
  fi
fi

if [[ "$CROP" == "null" ]]; then
  soft_exit "No cropping needed. Exiting process."
fi

# Build audio codec options per stream
AUDIO_OPTS=(-map 0)
AUDIO_STREAMS=$(ffprobe -v error -select_streams a -show_entries stream=index,codec_name \
  -of csv=p=0 "$INPUT")

while IFS=',' read -r IDX CODEC; do
  if [[ "$CODEC" == "truehd" ]]; then
    log_message "Debug" "$(timestamp) 🎧 Stream #$IDX is TrueHD — re-encoding to AC3"
    AUDIO_OPTS+=(-c:a:$IDX ac3 -b:a:$IDX 640k)
  else
    AUDIO_OPTS+=(-c:a:$IDX copy)
  fi
done <<< "$AUDIO_STREAMS"

# Get original video bitrate
VIDEO_BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
  -of default=noprint_wrappers=1:nokey=1 "$INPUT")

if ! [[ "$VIDEO_BITRATE" =~ ^[0-9]+$ ]]; then
  DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")
  FILESIZE=$(stat -c%s "$INPUT")
  DURATION_INT=${DURATION%.*}
  if [[ -z "$DURATION_INT" || "$DURATION_INT" -eq 0 ]]; then
    hard_exit "Invalid duration, cannot estimate bitrate."
  fi
  VIDEO_BITRATE=$(( FILESIZE * 8 / DURATION_INT ))
  log_message "Debug" "$(timestamp) 📊 Estimated bitrate: $VIDEO_BITRATE"
else
  log_message "Debug" "$(timestamp) 📊 Detected bitrate: $VIDEO_BITRATE"
fi

# Encode with crop, CRF 18, constrained to original bitrate
log_message "Debug" "$(timestamp) 🎬 Encoding to: $OUTPUT"

if ffmpeg -y -i "$INPUT" \
  -vf "$CROP" \
  -c:v libx264 -crf 18 -preset slow \
  -maxrate ${VIDEO_BITRATE} -bufsize $((VIDEO_BITRATE * 2)) \
  "${AUDIO_OPTS[@]}" \
  -c:s copy \
  "$OUTPUT"; then
  ORIG_SIZE=$(du -h "$INPUT" | cut -f1)
  NEW_SIZE=$(du -h "$OUTPUT" | cut -f1)
  log_message "Debug" "$(timestamp) 📦 Original size: $ORIG_SIZE"
  log_message "Debug" "$(timestamp) 📦 New size:      $NEW_SIZE"

  rm -f "$INPUT"
  log_message "Info" "$(timestamp) 🧹 Original file deleted: $INPUT"
else
  BACKUP="$INPUT.bak"
  cp "$INPUT" "$BACKUP"
  log_message "Info" "$(timestamp) 🛡️ Backup created: $BACKUP"
  log_message "Info" "$(timestamp) ❌ Encode failed. Restoring original file from backup."
  mv "$BACKUP" "$INPUT"
fi
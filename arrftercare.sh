#!/bin/bash
# Run this on a cron job or manually or as a service. It'll process one file, finish, and exit.

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

# Function to validate tools
validate_tools() {
  if ! command -v ffmpeg &>/dev/null || ! command -v ffprobe &>/dev/null; then
    hard_exit "ffmpeg and/or ffprobe not found. Please install them."
  fi
}

# Function to process a single file
process_file() {
  local INPUT="$1"

  # Validate the input file path
  if [[ ! -f "$INPUT" ]]; then
    log_message "Info" "Skipping non-existent file: $INPUT"
    return
  fi

  # Extract file details
  local DIRNAME="$(dirname "$INPUT")"
  local FILENAME="$(basename "$INPUT")"
  local EXT="${FILENAME##*.}"  # Extract file extension
  local NAME="${FILENAME%.*}"  # Extract file name without extension
  local OUTPUT="$DIRNAME/${NAME} [PPd].${EXT}"  # Define output file path

  # Skip if already post-processed
  if [[ "$FILENAME" == *"[PPd]."* ]]; then
    log_message "Info" "File already marked as post-processed. Skipping: $FILENAME"
    return
  fi

  # Detect crop
  detect_crop "$INPUT"

  # Encode the file
  encode_file "$INPUT" "$OUTPUT"
}

# Function to detect crop
detect_crop() {
  local INPUT="$1"
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

  if [[ "$CROP" == "null" ]]; then
    soft_exit "No cropping needed. Exiting process."
  fi
}

# Function to encode the file
encode_file() {
  local INPUT="$1"
  local OUTPUT="$2"

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
}

# Function to process all files in a directory
process_directory() {
  local DIRECTORY="$1"

  if [[ ! -d "$DIRECTORY" ]]; then
    hard_exit "Provided path is not a directory: $DIRECTORY"
  fi

  # Find all video files in the directory
  find "$DIRECTORY" -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' \) | while read -r FILE; do
    log_message "Info" "Processing file: $FILE"
    process_file "$FILE"
  done

  soft_exit "Processing completed for directory: $DIRECTORY"
}

# Trap to clean up temporary files on exit
TMP_LOG=$(mktemp /tmp/cropdetect_log.XXXXXX)
trap 'rm -f "$TMP_LOG"' EXIT

# Main script logic
validate_tools

if [ -n "$1" ]; then
  process_directory "$1"
else
  hard_exit "No directory provided. Please specify a directory to process."
fi
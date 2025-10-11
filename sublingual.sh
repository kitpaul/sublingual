#!/usr/bin/env bash
# Sublingual - Batch movie multi-language subtitle downloader script with NFO caching and survey mode
# Works with macOS's built-in bash 3.2 (no bash 4+ features)

set -euo pipefail
IFS=$'\n\t'

# Constants
readonly SCRIPT_VERSION="v1.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly CURRENT_YEAR=$(date +%Y)
readonly API_LIMIT=500
readonly API_BUDGET_LIMIT=490  # Stop before hitting hard limit
readonly API_STATE_FILE="${HOME}/.sublingual_api_state"
readonly IMDB_MAPPING_FILE="${HOME}/.sublingual_imdb_map"
readonly SURVEY_STATE_FILE="${HOME}/.sublingual_survey_state"

# Configuration variables
MOVIE_DIR=""
LANGUAGES="EN"
PAUSE=1
USE_YTS="true"
# OMDb API key - must be configured via environment variable or --omdb-key flag
OMDB_KEY="${OMDB_API_KEY:-}"
DEBUG="false"
WORKERS=4
RENAME="true"
DRY_RUN="false"
SURVEY_MODE="false"

# Statistics tracking
STATS_IMDB_SUCCESS=0
STATS_IMDB_FAIL=0
STATS_SUBTITLE_SUCCESS=0
STATS_SUBTITLE_FAIL=0
STATS_IMDB_SOURCE_DIRNAME=0
STATS_IMDB_SOURCE_NFO=0
STATS_IMDB_SOURCE_MAPPING=0
STATS_IMDB_SOURCE_OMDB=0
STATS_IMDB_SOURCE_DDGR=0
STATS_SUBTITLE_SOURCE_SUBLIMINAL=0
STATS_SUBTITLE_SOURCE_OPENSUB=0

# Secure temporary directory
readonly TMP_DIR="$(mktemp -d -t sublingual.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

# Logging functions
log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*" >&2
}

debug() { [[ "${DEBUG}" == "true" ]] && log "DEBUG" "$@" || true; }
info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }
fatal() { log "FATAL" "$@"; exit 1; }

# Safe string operations
url_encode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# Safe temporary file creation
safe_temp_file() {
    local prefix="${1:-temp}"
    local suffix="${2:-.tmp}"

    # BSD mktemp (macOS) requires XXXXXX at the end of the template
    # Create temp file first, then add suffix if needed
    local temp_file="$(mktemp "${TMP_DIR}/${prefix}.XXXXXX")"

    # Add suffix if provided and not empty
    if [[ -n "$suffix" ]]; then
        local new_name="${temp_file}${suffix}"
        mv "$temp_file" "$new_name"
        echo "$new_name"
    else
        echo "$temp_file"
    fi
}

# Validate positive integer
validate_positive_integer() {
    local value="$1"
    local param_name="$2"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        fatal "${param_name} must be a positive integer: $value"
    fi

    if [[ "$value" -eq 0 ]]; then
        fatal "${param_name} must be greater than zero: $value"
    fi

    return 0
}

# Validate language codes
validate_language_codes() {
    local langs="$1"

    # Check format: only letters and commas
    if [[ ! "$langs" =~ ^[A-Za-z,]+$ ]]; then
        fatal "Invalid language code format. Only letters and commas allowed: $langs"
    fi

    # Check for empty codes (double commas or leading/trailing commas)
    if [[ "$langs" =~ ^, ]] || [[ "$langs" =~ ,$ ]] || [[ "$langs" =~ ,, ]]; then
        fatal "Invalid language code format. Empty language codes detected: $langs"
    fi

    return 0
}

# Validate input - macOS compatible version
validate_path() {
    local path="$1"

    # Check if path exists and is a directory
    if [[ -d "$path" ]]; then
        # Get absolute path (macOS compatible) - use subshell to avoid side effects
        (cd "$path" && pwd)
    else
        return 1
    fi
}

# Check required commands
check_dependencies() {
    local deps=("curl" "unzip" "file")
    local missing=()

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing required commands: ${missing[*]}"
    fi
}

# Check optional components
check_optional_components() {
    local missing_optional=()

    # Check for optional year extraction tools
    if ! command -v ddgr &>/dev/null; then
        missing_optional+=("ddgr - for improved year detection via web search")
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        warn "Optional components not installed (enhanced features will be disabled):"
        for component in "${missing_optional[@]}"; do
            warn "  - $component"
        done
        warn "Install with: brew install ddgr"
        warn ""
    fi
}

# Show dependency status (for --version and startup)
show_dependency_status() {
    local show_versions="${1:-false}"

    echo ""
    echo "DEPENDENCIES"
    echo ""

    # Required dependencies
    echo "Required:"
    local required_deps=("curl" "unzip" "file")
    local all_required_ok=true

    for cmd in "${required_deps[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            if [[ "$show_versions" == "true" ]]; then
                local version=""
                case "$cmd" in
                    curl)
                        version=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
                        ;;
                    unzip)
                        version=$(unzip -v 2>/dev/null | head -1 | awk '{print $2}')
                        ;;
                    file)
                        version=$(file --version 2>/dev/null | head -1 | awk '{print $2}')
                        ;;
                esac
                echo "  ✓ $cmd ${version:+($version)}"
            else
                echo "  ✓ $cmd"
            fi
        else
            echo "  ✗ $cmd (MISSING)"
            all_required_ok=false
        fi
    done

    echo ""
    echo "Optional:"
    local optional_deps=("subliminal" "subdownloader" "ddgr")

    for cmd in "${optional_deps[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            if [[ "$show_versions" == "true" ]]; then
                local version=""
                case "$cmd" in
                    subliminal)
                        version=$(subliminal --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                        ;;
                    subdownloader)
                        version=$(subdownloader --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                        ;;
                    ddgr)
                        version=$(ddgr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
                        ;;
                esac
                echo "  ✓ $cmd ${version:+($version)}"
            else
                echo "  ✓ $cmd"
            fi
        else
            echo "  - $cmd (not installed)"
        fi
    done

    echo ""
    echo "Configuration:"

    # Check OMDb API key
    if [[ -n "${OMDB_KEY}" ]]; then
        echo "  ✓ OMDb API key (configured)"
    else
        echo "  ✗ OMDb API key (NOT CONFIGURED)"
        all_required_ok=false
    fi

    echo ""

    if [[ "$all_required_ok" == "false" ]]; then
        echo "ERROR: Missing required dependencies or configuration."
        echo ""
        if [[ -z "${OMDB_KEY}" ]]; then
            echo "OMDb API key is required. Apply for a FREE key at:"
            echo "  https://www.omdbapi.com/apikey.aspx"
            echo ""
        fi
        return 1
    fi

    return 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --folder)
                MOVIE_DIR="$2"
                shift 2
                ;;
            --language)
                LANGUAGES="$2"
                shift 2
                ;;
            --pause)
                validate_positive_integer "$2" "--pause"
                PAUSE="$2"
                shift 2
                ;;
            --omdb-key)
                OMDB_KEY="$2"  # Will override env var or hardcoded key
                shift 2
                ;;
            --debug)
                DEBUG="true"
                shift
                ;;
            --no-rename)
                RENAME="false"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --survey)
                SURVEY_MODE="true"
                shift
                ;;
            --workers)
                validate_positive_integer "$2" "--workers"
                WORKERS="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                show_version
                exit 0
                ;;
            *)
                fatal "Unknown option: $1"
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "${MOVIE_DIR}" ]]; then
        fatal "--folder is required"
    fi

    # Validate language codes
    validate_language_codes "${LANGUAGES}"

    # Debug: show original path
    debug "Original path: ${MOVIE_DIR}"

    # Validate and sanitize movie directory
    MOVIE_DIR="$(validate_path "${MOVIE_DIR}")" || {
        error "Path validation failed for: ${MOVIE_DIR}"
        fatal "Invalid directory: ${MOVIE_DIR}"
    }

    debug "Validated path: ${MOVIE_DIR}"
}

# API rate limiting functions
load_api_state() {
    if [[ -f "$API_STATE_FILE" ]]; then
        local state_date=$(head -1 "$API_STATE_FILE" 2>/dev/null || echo "")
        local state_count=$(tail -1 "$API_STATE_FILE" 2>/dev/null || echo "0")

        local today=$(date +%Y-%m-%d)

        # If state is from today, return the count
        if [[ "$state_date" == "$today" ]]; then
            echo "$state_count"
        else
            # Different day, reset count
            echo "0"
        fi
    else
        echo "0"
    fi
}

save_api_state() {
    local count="$1"
    local today=$(date +%Y-%m-%d)

    echo "$today" > "$API_STATE_FILE"
    echo "$count" >> "$API_STATE_FILE"

    debug "API state saved: $count calls on $today"
}

check_api_limit() {
    local current_count=$(load_api_state)

    if [[ $current_count -ge $API_BUDGET_LIMIT ]]; then
        local today=$(date +%Y-%m-%d)
        error "=================================================="
        error "API budget limit reached: $current_count/$API_LIMIT calls used today ($today)"
        error "Stopping at $API_BUDGET_LIMIT to preserve safety buffer."
        error "=================================================="
        error ""
        error "Options:"
        error "  1. Wait until tomorrow (script will resume automatically)"
        error "  2. Manually reset counter: rm $API_STATE_FILE"
        error "  3. Use a different API key with higher limits"
        error ""
        fatal "Exiting due to API budget limit. Resume tomorrow or reset manually."
    fi

    return 0
}

increment_api_count() {
    local current_count=$(load_api_state)
    local new_count=$((current_count + 1))
    save_api_state "$new_count"

    debug "API call count: $new_count/$API_LIMIT"

    # Warn when approaching limit
    if [[ $new_count -eq 450 ]]; then
        warn "Approaching API limit: $new_count/$API_LIMIT calls used (90%)"
    elif [[ $new_count -eq 475 ]]; then
        warn "Near API limit: $new_count/$API_LIMIT calls used (95%)"
    elif [[ $new_count -eq 490 ]]; then
        warn "Very close to API limit: $new_count/$API_LIMIT calls used (98%)"
    fi
}

# Safe curl wrapper with retry
safe_curl() {
    local url="$1"
    local output_file="${2:-}"
    local max_retries=3
    local timeout=30

    local curl_opts=(
        --silent
        --location
        --max-time "$timeout"
        --retry "$max_retries"
        --retry-delay 2
        --user-agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        --max-filesize 10485760
    )

    if [[ -n "$output_file" ]]; then
        curl_opts+=(--output "$output_file")
    fi

    if ! curl "${curl_opts[@]}" "$url"; then
        debug "curl failed for URL: $url"
        return 1
    fi

    if [[ -n "$output_file" && -f "$output_file" ]]; then
        local file_size=$(wc -c < "$output_file" 2>/dev/null || echo "0")
        debug "Downloaded $file_size bytes to $output_file"
        if [[ $file_size -lt 1024 ]]; then
            warn "Downloaded file is suspiciously small ($file_size bytes), may be invalid"
        elif [[ $file_size -gt 5242880 ]]; then
            warn "Downloaded file is large ($file_size bytes), may not be a subtitle"
        fi
    fi

    return 0
}

# Process subtitle file (ZIP archive or direct subtitle file)
process_subtitle_file() {
    local subtitle_file="$1"
    local dest_dir="$2"
    local language="$3"

    # Detect file type
    local file_type
    file_type="$(file "$subtitle_file")"

    # Check if it's a ZIP archive
    if echo "$file_type" | grep -q "Zip archive"; then
        debug "Processing ZIP archive: $subtitle_file"
        debug "Attempting to extract subtitle files from ZIP"

        # Create safe extraction directory
        local extract_dir
        extract_dir="$(safe_temp_file "extract" "")"
        rm "$extract_dir"  # Remove file, we need directory
        mkdir -p "$extract_dir"

        # Extract all subtitle files
        if unzip -q -j "$subtitle_file" '*.srt' '*.sub' '*.ass' '*.ssa' '*.vtt' '*.idx' '*.txt' -d "$extract_dir" 2>/dev/null; then
            local extracted_count=$(find "$extract_dir" -type f 2>/dev/null | wc -l)
            debug "Found $extracted_count files in ZIP archive"

            # Move subtitle files to destination
            local count=0
            for subtitle in "$extract_dir"/*; do
                [[ -f "$subtitle" ]] || continue

                local base_name="$(basename "$subtitle")"
                # Sanitize filename
                base_name="${base_name//[^a-zA-Z0-9._-]/_}"
                # Prevent filenames starting with dashes
                [[ "$base_name" =~ ^- ]] && base_name="_${base_name}"

                if mv "$subtitle" "$dest_dir/${base_name}" 2>/dev/null; then
                    ((count++))
                fi
            done

            rm -rf "$extract_dir"
            if [[ $count -gt 0 ]]; then
                debug "Successfully processed $count subtitle files from ZIP"
                return 0
            fi
        fi

        rm -rf "$extract_dir"
        return 1
    # Check if it's a text-based subtitle file
    elif echo "$file_type" | grep -qE "(text|ASCII|UTF-8)"; then
        debug "Processing text subtitle file: $subtitle_file"

        # Check if it's an HTML error page from OpenSubtitles
        if grep -qE '<html|<HTML|<!DOCTYPE|<head|<body' "$subtitle_file" 2>/dev/null; then
            debug "OpenSubtitles returned HTML error page instead of subtitle"
            return 1
        fi

        # Validate subtitle content
        if ! grep -qE '^[0-9]+$|^[0-9]{2}:[0-9]{2}:|^\[.*\]|^Dialogue:' "$subtitle_file" 2>/dev/null; then
            debug "File doesn't appear to contain valid subtitle content"
            return 1
        fi

        local base_name="$(basename "$subtitle_file")"
        # Sanitize filename
        base_name="${base_name//[^a-zA-Z0-9._-]/_}"
        # Prevent filenames starting with dashes
        [[ "$base_name" =~ ^- ]] && base_name="_${base_name}"

        if cp "$subtitle_file" "$dest_dir/${base_name}" 2>/dev/null; then
            debug "Successfully copied text subtitle to destination"
            return 0
        else
            debug "Failed to copy text subtitle to destination"
            return 1
        fi
    # Reject HTML or other non-subtitle files
    elif echo "$file_type" | grep -qE "(HTML|XML)"; then
        debug "Rejected HTML/XML file: $subtitle_file"
        return 1
    else
        debug "Unknown file type, rejecting: $subtitle_file"
        return 1
    fi
}

# Get IMDb ID from directory name (e.g., "Movie (2024) [tt1234567]")
get_imdb_from_dirname() {
    local dir_name="$1"

    # Extract IMDb ID pattern tt followed by 7-8 digits
    local imdb_id=$(echo "$dir_name" | grep -oE 'tt[0-9]{7,8}' | head -1)

    if [[ -n "$imdb_id" ]]; then
        debug "Found IMDb ID in directory name: $imdb_id"
        echo "$imdb_id"
        return 0
    fi

    return 1
}

# Get IMDb ID and metadata from .nfo file
# Returns structured data similar to get_imdb_from_omdb:
# IMDB:tt1234567
# TITLE:Movie Title
# YEAR:2024
# PLOT:Movie description...
# DIRECTOR:Director Name
# GENRE:Action, Drama
# RUNTIME:120 min
# RATING:PG-13
# PREMIERED:2024-04-16
get_imdb_from_nfo() {
    local dir_path="$1"

    # Find .nfo file in directory
    local nfo_file=$(find "$dir_path" -maxdepth 1 -name "*.nfo" -print -quit 2>/dev/null)

    if [[ -z "$nfo_file" ]]; then
        return 1
    fi

    debug "Checking .nfo file for metadata: $(basename "$nfo_file")"

    # Check if it's XML format
    if ! grep -q "<?xml" "$nfo_file" 2>/dev/null; then
        debug "NFO is not XML format, trying simple IMDb ID extraction"
        # Plain text format - just extract IMDb ID
        local imdb_id=$(grep -oE 'tt[0-9]{7,8}' "$nfo_file" 2>/dev/null | head -1)
        if [[ -n "$imdb_id" ]]; then
            debug "Found IMDb ID in plain text NFO: $imdb_id"
            echo "IMDB:${imdb_id}"
            return 0
        fi
        return 1
    fi

    # Extract IMDb ID
    local imdb_id=$(grep -oE '<uniqueid[^>]*type="imdb"[^>]*>tt[0-9]{7,8}</uniqueid>' "$nfo_file" 2>/dev/null | grep -oE 'tt[0-9]{7,8}' | head -1)

    if [[ -z "$imdb_id" ]]; then
        # Fallback: try any IMDb ID pattern
        imdb_id=$(grep -oE 'tt[0-9]{7,8}' "$nfo_file" 2>/dev/null | head -1)
    fi

    if [[ -z "$imdb_id" ]]; then
        debug "No IMDb ID found in NFO file"
        return 1
    fi

    debug "Found IMDb ID in XML NFO: $imdb_id"

    # Extract other metadata fields from XML
    local title=$(grep -oE '<title>([^<]*)</title>' "$nfo_file" 2>/dev/null | sed 's/<title>//;s/<\/title>//' | head -1)
    local year=$(grep -oE '<year>([0-9]{4})</year>' "$nfo_file" 2>/dev/null | grep -oE '[0-9]{4}' | head -1)
    local plot=$(grep -oE '<plot>([^<]*)</plot>' "$nfo_file" 2>/dev/null | sed 's/<plot>//;s/<\/plot>//' | head -1)
    local director=$(grep -oE '<director>([^<]*)</director>' "$nfo_file" 2>/dev/null | sed 's/<director>//;s/<\/director>//' | head -1)
    local genre=$(grep -oE '<genre>([^<]*)</genre>' "$nfo_file" 2>/dev/null | sed 's/<genre>//;s/<\/genre>//' | head -1)
    local runtime=$(grep -oE '<runtime>([^<]*)</runtime>' "$nfo_file" 2>/dev/null | sed 's/<runtime>//;s/<\/runtime>//' | head -1)
    local rating=$(grep -oE '<mpaa>([^<]*)</mpaa>' "$nfo_file" 2>/dev/null | sed 's/<mpaa>//;s/<\/mpaa>//' | head -1)
    local premiered=$(grep -oE '<premiered>([^<]*)</premiered>' "$nfo_file" 2>/dev/null | sed 's/<premiered>//;s/<\/premiered>//' | head -1)

    # Check if this is a Sublingual-created NFO
    local is_sublingual=$(grep -q '<sublingual' "$nfo_file" 2>/dev/null && echo "true" || echo "false")

    # Output structured metadata
    echo "IMDB:${imdb_id}"
    [[ -n "$title" ]] && echo "TITLE:${title}"
    [[ -n "$year" ]] && echo "YEAR:${year}"
    [[ -n "$plot" ]] && echo "PLOT:${plot}"
    [[ -n "$director" ]] && echo "DIRECTOR:${director}"
    [[ -n "$genre" ]] && echo "GENRE:${genre}"
    [[ -n "$runtime" ]] && echo "RUNTIME:${runtime}"
    [[ -n "$rating" ]] && echo "RATING:${rating}"
    [[ -n "$premiered" ]] && echo "PREMIERED:${premiered}"
    echo "SUBLINGUAL:${is_sublingual}"

    debug "NFO metadata extracted - Title: $title, Year: $year, Sublingual: $is_sublingual"

    return 0
}

# Validate cache data
validate_cache_data() {
    local imdb_id="$1"
    local year="${2:-}"

    # Validate IMDb ID format
    if [[ ! "$imdb_id" =~ ^tt[0-9]{7,8}$ ]]; then
        debug "Invalid IMDb ID format: $imdb_id"
        return 1
    fi

    # Validate year if provided
    if [[ -n "$year" ]]; then
        if [[ ! "$year" =~ ^[0-9]{4}$ ]] || [[ $year -lt 1920 ]] || [[ $year -gt $CURRENT_YEAR ]]; then
            debug "Invalid year: $year"
            return 1
        fi
    fi

    return 0
}

# Write NFO cache file
write_nfo_cache() {
    local movie_dir="$1"
    local imdb_id="$2"
    local movie_name="${3:-}"
    local movie_year="${4:-}"
    local imdb_source="${5:-unknown}"
    local plot="${6:-}"
    local director="${7:-}"
    local genre="${8:-}"
    local runtime="${9:-}"
    local rating="${10:-}"
    local premiered="${11:-}"

    # Validate data before writing
    if ! validate_cache_data "$imdb_id" "$movie_year"; then
        warn "Cache data validation failed, skipping cache write"
        return 1
    fi

    # Dry-run mode: skip writing
    if [[ "$DRY_RUN" == "true" ]]; then
        debug "DRY-RUN: Would write cache to NFO file"
        return 0
    fi

    # Determine NFO filename (prefer video filename per Kodi standards)
    local nfo_file=""
    local nfo_existed=false

    # First check if NFO already exists
    local existing_nfo=$(find "$movie_dir" -maxdepth 1 -name "*.nfo" -print -quit 2>/dev/null)

    if [[ -n "$existing_nfo" ]]; then
        nfo_file="$existing_nfo"
        nfo_existed=true
        debug "NFO file exists, checking if update needed: $(basename "$nfo_file")"

        # Check if this is a Sublingual-created NFO
        local is_sublingual_nfo=false
        if grep -q '<sublingual' "$nfo_file" 2>/dev/null; then
            is_sublingual_nfo=true
            debug "NFO was created by Sublingual"
        else
            debug "NFO from external source (Kodi/Plex/etc.)"
        fi

        # Check if it already has the IMDb ID
        if grep -q "<uniqueid[^>]*type=\"imdb\"[^>]*>$imdb_id</uniqueid>" "$nfo_file" 2>/dev/null; then
            if [[ "$is_sublingual_nfo" == "true" ]]; then
                debug "Sublingual NFO already contains correct IMDb ID, could update fields (future enhancement)"
                # Future: Check if we need to add missing fields like plot, genre, etc.
            else
                debug "External NFO already contains correct IMDb ID, skipping update"
            fi
            return 0
        fi

        # Check if it has a different IMDb ID (don't overwrite - safety first)
        if grep -q '<uniqueid[^>]*type="imdb"' "$nfo_file" 2>/dev/null; then
            debug "NFO contains different IMDb ID, preserving existing to avoid conflicts"
            return 0
        fi

        if [[ "$is_sublingual_nfo" == "true" ]]; then
            debug "Updating Sublingual NFO with new cache data"
        else
            debug "Enhancing external NFO with Sublingual metadata"
        fi
    else
        # Find video file to name NFO after it (Kodi preferred format)
        local video_file=$(find "$movie_dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \) -print -quit 2>/dev/null)

        if [[ -n "$video_file" ]]; then
            # Use video filename without extension
            local video_basename=$(basename "$video_file")
            local video_name="${video_basename%.*}"
            nfo_file="${movie_dir}/${video_name}.nfo"
            debug "Creating new NFO named after video file: ${video_name}.nfo"
        else
            # Fallback to movie.nfo
            nfo_file="${movie_dir}/movie.nfo"
            debug "Creating new NFO cache file: movie.nfo"
        fi
    fi

    # Create timestamp
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build NFO content
    local nfo_content=""

    if [[ "$nfo_existed" == "false" ]]; then
        # Create new NFO file
        nfo_content="<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<movie>
  <title>${movie_name}</title>"

        [[ -n "$movie_year" ]] && nfo_content+="
  <year>${movie_year}</year>"

        [[ -n "$premiered" ]] && nfo_content+="
  <premiered>${premiered}</premiered>"

        [[ -n "$plot" ]] && nfo_content+="
  <plot>${plot}</plot>"

        [[ -n "$director" ]] && nfo_content+="
  <director>${director}</director>"

        [[ -n "$genre" ]] && nfo_content+="
  <genre>${genre}</genre>"

        [[ -n "$runtime" ]] && nfo_content+="
  <runtime>${runtime}</runtime>"

        [[ -n "$rating" ]] && nfo_content+="
  <mpaa>${rating}</mpaa>"

        nfo_content+="
  <uniqueid type=\"imdb\">${imdb_id}</uniqueid>
  <sublingual version=\"${SCRIPT_VERSION}\" source=\"${imdb_source}\" cached=\"${timestamp}\"/>
</movie>"

        # Write new NFO
        echo "$nfo_content" > "$nfo_file"
        info "   Cache: Created NFO with IMDb ID $imdb_id"
    else
        # Update existing NFO by inserting before closing tag
        # First, check if it's XML format
        if grep -q "<?xml" "$nfo_file" 2>/dev/null; then
            # Build insert content with all available metadata
            local insert_content=""

            [[ -n "$premiered" ]] && insert_content+="  <premiered>${premiered}</premiered>
"
            [[ -n "$plot" ]] && insert_content+="  <plot>${plot}</plot>
"
            [[ -n "$director" ]] && insert_content+="  <director>${director}</director>
"
            [[ -n "$genre" ]] && insert_content+="  <genre>${genre}</genre>
"
            [[ -n "$runtime" ]] && insert_content+="  <runtime>${runtime}</runtime>
"
            [[ -n "$rating" ]] && insert_content+="  <mpaa>${rating}</mpaa>
"
            insert_content+="  <uniqueid type=\"imdb\">${imdb_id}</uniqueid>
  <sublingual version=\"${SCRIPT_VERSION}\" source=\"${imdb_source}\" cached=\"${timestamp}\"/>"

            # Use sed to insert before </movie> tag
            sed -i.bak "/<\/movie>/i\\
$insert_content
" "$nfo_file" 2>/dev/null && rm -f "${nfo_file}.bak"

            info "   Cache: Updated NFO with IMDb ID $imdb_id"
        else
            # Plain text NFO, append IMDb ID
            echo "" >> "$nfo_file"
            echo "IMDb ID: $imdb_id" >> "$nfo_file"
            echo "Cached: $timestamp by Sublingual $SCRIPT_VERSION ($imdb_source)" >> "$nfo_file"
            info "   Cache: Appended IMDb ID to NFO"
        fi
    fi

    return 0
}

# Get IMDb ID from manual mapping file
get_imdb_from_mapping() {
    local movie_name="$1"

    if [[ ! -f "$IMDB_MAPPING_FILE" ]]; then
        return 1
    fi

    debug "Checking manual mapping file for: $movie_name"

    # Case-insensitive grep for movie name
    local imdb_id=$(grep -i "^${movie_name}|" "$IMDB_MAPPING_FILE" | cut -d'|' -f2 | head -1)

    if [[ -z "$imdb_id" ]]; then
        # Try partial match if exact match fails
        imdb_id=$(grep -i "${movie_name}" "$IMDB_MAPPING_FILE" | cut -d'|' -f2 | head -1)
    fi

    if [[ -n "$imdb_id" ]]; then
        debug "Found IMDb ID in manual mapping: $imdb_id"
        echo "$imdb_id"
        return 0
    fi

    return 1
}

# Get IMDb ID and metadata from OMDb
# Returns structured data similar to parse_movie_info:
# IMDB:tt1234567
# PLOT:Movie description...
# DIRECTOR:Director Name
# GENRE:Action, Drama
# RUNTIME:120 min
# RATING:PG-13
# PREMIERED:2024-04-16
get_imdb_from_omdb() {
    local movie_name="$1"
    local year="${2:-}"

    [[ -z "${OMDB_KEY}" ]] && return 1

    # Clean movie name
    movie_name="${movie_name//[._-]/ }"
    movie_name="$(echo "$movie_name" | xargs)"

    local url="https://www.omdbapi.com/?apikey=${OMDB_KEY}&t=$(url_encode "$movie_name")&type=movie"
    [[ -n "$year" ]] && url="${url}&y=${year}"

    debug "OMDb URL: $url"

    # Check API limit before making the call
    check_api_limit || return 1

    local response
    response="$(safe_curl "$url")" || return 1

    # Increment API counter after successful call
    increment_api_count

    debug "OMDb response (first 200 chars): ${response:0:200}"
    debug "Searching for IMDb ID in response"

    # Extract IMDb ID from JSON (simple grep approach)
    local imdb_id
    imdb_id="$(echo "$response" | grep -oE '"imdbID":"tt[0-9]+"' | cut -d'"' -f4)"

    if [[ -n "$imdb_id" ]]; then
        # Extract additional metadata from OMDb response
        local response_title=$(echo "$response" | grep -oE '"Title":"[^"]*"' | cut -d'"' -f4)
        local plot=$(echo "$response" | grep -oE '"Plot":"[^"]*"' | cut -d'"' -f4)
        local director=$(echo "$response" | grep -oE '"Director":"[^"]*"' | cut -d'"' -f4)
        local genre=$(echo "$response" | grep -oE '"Genre":"[^"]*"' | cut -d'"' -f4)
        local runtime=$(echo "$response" | grep -oE '"Runtime":"[^"]*"' | cut -d'"' -f4)
        local rating=$(echo "$response" | grep -oE '"Rated":"[^"]*"' | cut -d'"' -f4)
        local released=$(echo "$response" | grep -oE '"Released":"[^"]*"' | cut -d'"' -f4)

        # Check for title mismatch
        if [[ -n "$response_title" ]]; then
            local folder_lower=$(echo "$movie_name" | tr '[:upper:]' '[:lower:]')
            local response_lower=$(echo "$response_title" | tr '[:upper:]' '[:lower:]')
            if [[ "$response_lower" != "$folder_lower" ]]; then
                warn "Title mismatch - Folder: '$movie_name', OMDb: '$response_title'"
            fi
        fi

        # Output structured metadata
        echo "IMDB:${imdb_id}"
        [[ -n "$plot" && "$plot" != "N/A" ]] && echo "PLOT:${plot}"
        [[ -n "$director" && "$director" != "N/A" ]] && echo "DIRECTOR:${director}"
        [[ -n "$genre" && "$genre" != "N/A" ]] && echo "GENRE:${genre}"
        [[ -n "$runtime" && "$runtime" != "N/A" ]] && echo "RUNTIME:${runtime}"
        [[ -n "$rating" && "$rating" != "N/A" ]] && echo "RATING:${rating}"
        [[ -n "$released" && "$released" != "N/A" ]] && echo "PREMIERED:${released}"

        # Rate limiting: sleep after each OMDB API call
        sleep 0.5
        return 0
    fi

    if [[ -z "$imdb_id" ]] && [[ -n "$year" ]]; then
        debug "IMDb ID not found with year, retrying without year parameter"

        # Check API limit before second attempt
        check_api_limit || return 1

        local url_no_year="https://www.omdbapi.com/?apikey=${OMDB_KEY}&t=$(url_encode "$movie_name")&type=movie"
        response="$(safe_curl "$url_no_year")" || return 1

        # Increment API counter after successful call
        increment_api_count

        debug "OMDb response without year (first 200 chars): ${response:0:200}"
        imdb_id="$(echo "$response" | grep -oE '"imdbID":"tt[0-9]+"' | cut -d'"' -f4)"

        if [[ -n "$imdb_id" ]]; then
            # Extract additional metadata from OMDb response
            local response_title=$(echo "$response" | grep -oE '"Title":"[^"]*"' | cut -d'"' -f4)
            local response_year=$(echo "$response" | grep -oE '"Year":"[^"]*"' | cut -d'"' -f4)
            local plot=$(echo "$response" | grep -oE '"Plot":"[^"]*"' | cut -d'"' -f4)
            local director=$(echo "$response" | grep -oE '"Director":"[^"]*"' | cut -d'"' -f4)
            local genre=$(echo "$response" | grep -oE '"Genre":"[^"]*"' | cut -d'"' -f4)
            local runtime=$(echo "$response" | grep -oE '"Runtime":"[^"]*"' | cut -d'"' -f4)
            local rating=$(echo "$response" | grep -oE '"Rated":"[^"]*"' | cut -d'"' -f4)
            local released=$(echo "$response" | grep -oE '"Released":"[^"]*"' | cut -d'"' -f4)

            # Check for title/year mismatch
            if [[ -n "$response_title" ]]; then
                local folder_lower=$(echo "$movie_name" | tr '[:upper:]' '[:lower:]')
                local response_lower=$(echo "$response_title" | tr '[:upper:]' '[:lower:]')
                if [[ "$response_lower" != "$folder_lower" ]]; then
                    warn "Title mismatch - Folder: '$movie_name', OMDb: '$response_title'"
                fi
            fi

            if [[ -n "$response_year" && "$response_year" != "$year" ]]; then
                warn "Year mismatch - Folder: $year, OMDb: $response_year"
            fi

            # Output structured metadata
            echo "IMDB:${imdb_id}"
            [[ -n "$plot" && "$plot" != "N/A" ]] && echo "PLOT:${plot}"
            [[ -n "$director" && "$director" != "N/A" ]] && echo "DIRECTOR:${director}"
            [[ -n "$genre" && "$genre" != "N/A" ]] && echo "GENRE:${genre}"
            [[ -n "$runtime" && "$runtime" != "N/A" ]] && echo "RUNTIME:${runtime}"
            [[ -n "$rating" && "$rating" != "N/A" ]] && echo "RATING:${rating}"
            [[ -n "$released" && "$released" != "N/A" ]] && echo "PREMIERED:${released}"

            # Rate limiting: sleep after each OMDB API call
            sleep 0.5
            return 0
        fi
    fi

    # Rate limiting: sleep after each OMDB API call (even on failure)
    sleep 0.5
    return 1
}

# Get IMDb ID from ddgr web search (Sprint 2)
get_imdb_from_ddgr() {
    local movie_name="$1"
    local year="${2:-}"

    if ! command -v ddgr &>/dev/null; then
        debug "ddgr not available for IMDb lookup"
        return 1
    fi

    debug "Attempting IMDb lookup via ddgr search"

    # Build search query
    local search_query="imdb $movie_name"
    [[ -n "$year" ]] && search_query="$search_query $year"

    debug "ddgr search: $search_query"

    # Search IMDb using ddgr (get first 5 results)
    local search_output=$(ddgr --np "$search_query" 2>/dev/null | head -20)

    # Extract IMDb ID from search results
    local imdb_id=$(echo "$search_output" | grep -oE 'imdb\.com/title/(tt[0-9]{7,8})' | head -1 | grep -oE 'tt[0-9]{7,8}')

    if [[ -n "$imdb_id" ]]; then
        debug "Found IMDb ID via ddgr: $imdb_id"
        echo "$imdb_id"
        return 0
    fi

    debug "No IMDb ID found via ddgr"
    return 1
}

# Extract year from various sources
extract_year() {
    local dir_name="$1"
    local dir_path="$2"
    local year=""

    # Method 1: Parentheses (fast, precise)
    if [[ "$dir_name" =~ \(([0-9]{4})\) ]]; then
        year="${BASH_REMATCH[1]}"
        debug "Year from parentheses: $year"
        echo "$year"
        return 0
    fi

    # Method 2: Last 4-digit number in valid range (1920-current year)
    # Extract all 4-digit numbers, then filter using arithmetic comparison
    local all_years=$(echo "$dir_name" | grep -oE '[0-9]{4}')
    if [[ -n "$all_years" ]]; then
        local valid_years=""
        while IFS= read -r candidate; do
            # Check if year is in valid range using arithmetic
            if [[ $candidate -ge 1920 && $candidate -le $CURRENT_YEAR ]]; then
                valid_years="${valid_years}${candidate}"$'\n'
            fi
        done <<< "$all_years"

        if [[ -n "$valid_years" ]]; then
            year=$(echo "$valid_years" | grep -v '^$' | tail -1)
            debug "Year from range-based extraction (1920-$CURRENT_YEAR): $year"
            echo "$year"
            return 0
        fi
    fi

    # Method 3: Check .nfo file
    local nfo_file=$(find "$dir_path" -maxdepth 1 -name "*.nfo" -print -quit 2>/dev/null)
    if [[ -n "$nfo_file" ]]; then
        year=$(grep -oE '<year>[0-9]{4}</year>' "$nfo_file" 2>/dev/null | grep -oE '[0-9]{4}' | head -1)
        if [[ -n "$year" ]]; then
            debug "Year from NFO file: $year"
            echo "$year"
            return 0
        fi
    fi

    return 1
}

# Web search fallback for year using ddgr
extract_year_web() {
    local movie_name="$1"

    if ! command -v ddgr &>/dev/null; then
        debug "ddgr not available for web year extraction"
        return 1
    fi

    debug "Attempting year extraction via ddgr search"

    # Extract years from search results and validate range
    local search_output=$(ddgr --np "imdb $movie_name" 2>/dev/null | head -1)
    local all_years=$(echo "$search_output" | grep -oE '\((19[0-9]{2}|20[0-9]{2})\)' | tr -d '()')

    if [[ -n "$all_years" ]]; then
        local valid_year=""
        while IFS= read -r candidate; do
            # Validate year is in range 1920-current year
            if [[ $candidate -ge 1920 && $candidate -le $CURRENT_YEAR ]]; then
                valid_year="$candidate"
                break
            fi
        done <<< "$all_years"

        if [[ -n "$valid_year" ]]; then
            debug "Year from ddgr search (1920-$CURRENT_YEAR): $valid_year"
            echo "$valid_year"
            return 0
        fi
    fi

    return 1
}

# Parse movie info from directory name and video files
parse_movie_info() {
    local dir_path="$1"
    local dir_name="$(basename "$dir_path")"
    local movie_name=""
    local year=""
    local resolution=""

    # Extract year using extract_year function
    year=$(extract_year "$dir_name" "$dir_path") || year=""

    # Extract resolution from directory name first
    # Priority: bracketed format [1080p], then bare with spaces, then bare at start
    if [[ "$dir_name" =~ \[([0-9]+p)\] ]]; then
        resolution="${BASH_REMATCH[1]}"
    elif [[ "$dir_name" =~ [[:space:]]([0-9]{3,4}p)[[:space:]] ]]; then
        resolution="${BASH_REMATCH[1]}"
    elif [[ "$dir_name" =~ ^([0-9]{3,4}p)[[:space:]] ]]; then
        resolution="${BASH_REMATCH[1]}"
    fi

    # If no resolution in directory name, check video files
    if [[ -z "$resolution" ]]; then
        local video_file
        video_file=$(find "$dir_path" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \) -print -quit 2>/dev/null)
        if [[ -n "$video_file" ]]; then
            local video_name="$(basename "$video_file")"
            # Check for resolution patterns in video filename
            if [[ "$video_name" =~ ([0-9]{3,4}p) ]]; then
                resolution="${BASH_REMATCH[1]}"
            elif [[ "$video_name" =~ ([0-9]{3,4})x([0-9]{3,4}) ]]; then
                # Convert 1920x1080 format to 1080p
                case "${BASH_REMATCH[2]}" in
                    2160|2140|2076|2048) resolution="2160p" ;;
                    1080|1920) resolution="1080p" ;;
                    720|1280) resolution="720p" ;;
                    480|640) resolution="480p" ;;
                    *) resolution="${BASH_REMATCH[2]}p" ;;
                esac
            fi
        fi
    fi

    # Clean movie name from directory
    movie_name="$dir_name"
    movie_name="${movie_name//\[*\]/}"  # Remove [tags]
    movie_name="${movie_name//(*)/}"     # Remove (year)

    # Remove specific year if found (not all 4-digit numbers!)
    if [[ -n "$year" ]]; then
        # Remove the specific year (handles both bare "1969" and already removed "(1969)")
        movie_name="${movie_name//$year/}"
    fi

    # Remove common codec and quality terms (case-insensitive)
    movie_name=$(echo "$movie_name" | sed -E 's/[[:space:]]*(BluRay|BRRip|WEBRip|WEB-DL|HDRip|DVDRip|x264|x265|h264|h265|HEVC|AAC|AC3|DTS|5\.1|7\.1|YIFY|YTS|RARBG|GeneMige)[[:space:]]*/ /gi')

    # Remove bare resolution patterns (720p, 1080p, 2160p, etc.)
    movie_name=$(echo "$movie_name" | sed -E 's/[[:space:]]+[0-9]{3,4}p([[:space:]]+|$)/ /g')

    # Replace separators with spaces
    movie_name="${movie_name//[._-]/ }"

    # Trim and remove multiple spaces
    movie_name="$(echo "$movie_name" | xargs)"

    echo "NAME:${movie_name}"
    echo "YEAR:${year}"
    echo "RESOLUTION:${resolution}"
}

# Run external tools safely
run_subdownloader() {
    local movie_dir="$1"
    local language="$2"

    if ! command -v subdownloader &>/dev/null; then
        debug "subdownloader not installed"
        return 1
    fi

    info "  [Subdownloader] Searching for ${language} subtitles..."

    local output
    if output=$(subdownloader -c -V "$movie_dir" -l "$language" 2>&1); then
        debug "Subdownloader output (first 500 chars): ${output:0:500}"
        local count
        count=$(echo "$output" | grep -c 'Saved subtitle' || echo "0")
        if [[ $count -gt 0 ]]; then
            info "  [Subdownloader] Downloaded $count subtitle(s)"
            return 0
        fi
    fi

    info "  [Subdownloader] No subtitles found"
    return 1
}

run_subliminal() {
    local movie_dir="$1"
    local language="$2"

    if ! command -v subliminal &>/dev/null; then
        debug "subliminal not installed"
        return 1
    fi

    info "  [Subliminal] Searching for ${language} subtitles..."

    # Dry-run mode: skip actual download
    if [[ "$DRY_RUN" == "true" ]]; then
        info "  [Subliminal] DRY-RUN: Would search for subtitles"
        return 1
    fi

    local output
    # Add timeout to prevent hanging (30 seconds)
    if command -v gtimeout &>/dev/null; then
        # GNU timeout (if installed via homebrew)
        output=$(gtimeout 30s subliminal download -l "$language" -f "$movie_dir" 2>&1) || true
    elif command -v timeout &>/dev/null; then
        # BSD timeout
        output=$(timeout 30s subliminal download -l "$language" -f "$movie_dir" 2>&1) || true
    else
        # No timeout available, add providers limit to speed up
        output=$(subliminal download -l "$language" -f "$movie_dir" --provider opensubtitles --provider podnapisi 2>&1) || true
    fi

    debug "Subliminal output (first 500 chars): ${output:0:500}"

    if [[ -n "$output" ]]; then
        local count
        count=$(echo "$output" | grep -oE 'Downloaded [0-9]+' | grep -oE '[0-9]+' || echo "0")
        if [[ $count -gt 0 ]]; then
            info "  [Subliminal] Downloaded $count subtitle(s)"
            ((STATS_SUBTITLE_SOURCE_SUBLIMINAL++))
            return 0
        fi
    fi

    info "  [Subliminal] No subtitles found"
    return 1
}

# Download from OpenSubtitles
download_opensubtitles() {
    local movie_dir="$1"
    local language="$2"
    local imdb_id="$3"

    [[ "$USE_YTS" != "true" ]] && return 0
    [[ -z "$imdb_id" ]] && { info "  [OpenSubtitles] Skipped (no IMDb ID)"; return 1; }

    info "  [OpenSubtitles] Searching for ${language} subtitles..."

    # Dry-run mode: skip actual download
    if [[ "$DRY_RUN" == "true" ]]; then
        info "  [OpenSubtitles] DRY-RUN: Would search for subtitles with IMDb ID $imdb_id"
        return 1
    fi

    sleep 1  # Rate limiting for OpenSubtitles

    # Language mapping - OpenSubtitles 3-letter codes
    local lang_code="eng"
    local lang_lower=$(echo "$language" | tr '[:upper:]' '[:lower:]')
    case "$lang_lower" in
        # European languages
        en) lang_code="eng" ;;
        ro) lang_code="rum" ;;
        fr) lang_code="fre" ;;
        es) lang_code="spa" ;;
        de) lang_code="ger" ;;
        it) lang_code="ita" ;;
        pt) lang_code="por" ;;
        nl) lang_code="dut" ;;
        pl) lang_code="pol" ;;
        ru) lang_code="rus" ;;
        el) lang_code="gre" ;;
        tr) lang_code="tur" ;;
        sv) lang_code="swe" ;;
        no) lang_code="nor" ;;
        da) lang_code="dan" ;;
        fi) lang_code="fin" ;;
        cs) lang_code="cze" ;;
        hu) lang_code="hun" ;;
        bg) lang_code="bul" ;;
        hr) lang_code="hrv" ;;
        sr) lang_code="scc" ;;
        sk) lang_code="slo" ;;
        sl) lang_code="slv" ;;
        uk) lang_code="ukr" ;;
        # Asian languages
        ar) lang_code="ara" ;;
        zh) lang_code="chi" ;;
        ja) lang_code="jpn" ;;
        ko) lang_code="kor" ;;
        hi) lang_code="hin" ;;
        th) lang_code="tha" ;;
        vi) lang_code="vie" ;;
        id) lang_code="ind" ;;
        # Other common languages
        he) lang_code="heb" ;;
        fa) lang_code="per" ;;
        bn) lang_code="ben" ;;
    esac

    local search_url="https://www.opensubtitles.org/en/search/sublanguageid-${lang_code}/imdbid-${imdb_id#tt}"
    debug "OpenSubtitles URL: $search_url"

    local response
    response="$(safe_curl "$search_url")" || return 1

    debug "Searching for download links in OpenSubtitles response"

    # Extract first download link
    local download_link
    download_link="$(echo "$response" | grep -oE 'href="/en/subtitleserve/sub/[0-9]+"' | head -1 | cut -d'"' -f2)"

    if [[ -n "$download_link" ]]; then
        debug "Found download link: $download_link"
    else
        debug "No download link found in response"
    fi

    if [[ -n "$download_link" ]]; then
        local full_url="https://www.opensubtitles.org${download_link}"
        local temp_file
        temp_file="$(safe_temp_file "opensub" ".tmp")"

        if safe_curl "$full_url" "$temp_file"; then
            if process_subtitle_file "$temp_file" "$movie_dir" "$language"; then
                info "  [OpenSubtitles] Downloaded subtitle(s)"
                ((STATS_SUBTITLE_SOURCE_OPENSUB++))
                sleep 1  # Rate limiting for OpenSubtitles
                rm -f "$temp_file"
                return 0
            fi
        fi

        rm -f "$temp_file"
    fi

    info "  [OpenSubtitles] No subtitles found"
    return 1
}

# Main processing function
process_movie() {
    local movie_dir="$1"
    local language="$2"

    local movie_basename="$(basename "$movie_dir")"
    info ""
    info "Processing: ${movie_basename}"
    info "   Language: ${language}"

    # Parse movie info
    local movie_info
    movie_info="$(parse_movie_info "$movie_dir")"

    local movie_name=""
    local movie_year=""
    local movie_resolution=""

    while IFS= read -r line; do
        case "$line" in
            NAME:*) movie_name="${line#NAME:}" ;;
            YEAR:*) movie_year="${line#YEAR:}" ;;
            RESOLUTION:*) movie_resolution="${line#RESOLUTION:}" ;;
        esac
    done <<< "$movie_info"

    debug "Parsed - Name: ${movie_name}, Year: ${movie_year}, Resolution: ${movie_resolution:-Not found}"

    # Try web search if no year found locally
    if [[ -z "$movie_year" ]] && command -v ddgr &>/dev/null; then
        debug "No year found locally, attempting web search"
        movie_year=$(extract_year_web "$movie_name") || true
        [[ -n "$movie_year" ]] && info "   Year (from web): $movie_year"
    fi

    # Try to get IMDb ID using multiple methods (priority order)
    local imdb_id=""
    local imdb_source=""

    # Metadata (can come from NFO or OMDb API)
    local omdb_plot=""
    local omdb_director=""
    local omdb_genre=""
    local omdb_runtime=""
    local omdb_rating=""
    local omdb_premiered=""

    # 1. Check directory name for IMDb ID
    imdb_id="$(get_imdb_from_dirname "$movie_basename")" && imdb_source="dirname" || true

    # 2. Check .nfo file (returns structured metadata)
    if [[ -z "$imdb_id" ]]; then
        local nfo_response
        nfo_response="$(get_imdb_from_nfo "$movie_dir")" && {
            imdb_source="nfo"

            # Parse structured output from NFO
            local nfo_title=""
            local nfo_year=""
            local is_sublingual_nfo="false"

            while IFS= read -r line; do
                case "$line" in
                    IMDB:*) imdb_id="${line#IMDB:}" ;;
                    TITLE:*) nfo_title="${line#TITLE:}" ;;
                    YEAR:*) nfo_year="${line#YEAR:}" ;;
                    PLOT:*) omdb_plot="${line#PLOT:}" ;;
                    DIRECTOR:*) omdb_director="${line#DIRECTOR:}" ;;
                    GENRE:*) omdb_genre="${line#GENRE:}" ;;
                    RUNTIME:*) omdb_runtime="${line#RUNTIME:}" ;;
                    RATING:*) omdb_rating="${line#RATING:}" ;;
                    PREMIERED:*) omdb_premiered="${line#PREMIERED:}" ;;
                    SUBLINGUAL:*) is_sublingual_nfo="${line#SUBLINGUAL:}" ;;
                esac
            done <<< "$nfo_response"

            # Override movie name and year with NFO data if available
            [[ -n "$nfo_title" ]] && movie_name="$nfo_title" && debug "Using title from NFO: $movie_name"
            [[ -n "$nfo_year" ]] && movie_year="$nfo_year" && debug "Using year from NFO: $movie_year"

            debug "NFO metadata extracted - Title: $nfo_title, Year: $nfo_year, Sublingual: $is_sublingual_nfo"

            # If Sublingual NFO has complete metadata, we can skip OMDb call
            if [[ "$is_sublingual_nfo" == "true" ]] && [[ -n "$omdb_plot" ]]; then
                debug "Using cached metadata from Sublingual NFO, skipping OMDb API call"
            fi
        } || true
    fi

    # 3. Check manual mapping file
    if [[ -z "$imdb_id" ]]; then
        imdb_id="$(get_imdb_from_mapping "$movie_name")" && imdb_source="mapping" || true
    fi

    # 4. Try OMDb API (returns structured metadata) - skip if we have complete NFO cache
    if [[ -z "$imdb_id" ]] && [[ -n "${OMDB_KEY}" ]] && [[ -n "$movie_name" ]]; then
        local omdb_response
        omdb_response="$(get_imdb_from_omdb "$movie_name" "$movie_year")" && {
            imdb_source="omdb"

            # Parse structured output from OMDb
            while IFS= read -r line; do
                case "$line" in
                    IMDB:*) imdb_id="${line#IMDB:}" ;;
                    PLOT:*) omdb_plot="${line#PLOT:}" ;;
                    DIRECTOR:*) omdb_director="${line#DIRECTOR:}" ;;
                    GENRE:*) omdb_genre="${line#GENRE:}" ;;
                    RUNTIME:*) omdb_runtime="${line#RUNTIME:}" ;;
                    RATING:*) omdb_rating="${line#RATING:}" ;;
                    PREMIERED:*) omdb_premiered="${line#PREMIERED:}" ;;
                esac
            done <<< "$omdb_response"

            debug "OMDb metadata extracted - Plot: ${#omdb_plot} chars, Director: $omdb_director, Genre: $omdb_genre"
        } || true
    fi

    # 5. Try ddgr web search as last resort (Sprint 2)
    if [[ -z "$imdb_id" ]] && [[ -n "$movie_name" ]]; then
        imdb_id="$(get_imdb_from_ddgr "$movie_name" "$movie_year")" && imdb_source="ddgr" || true
    fi

    # Report IMDb ID with source
    if [[ -n "$imdb_id" ]]; then
        info "   IMDb ID: $imdb_id (source: $imdb_source)"
        # Update statistics
        case "$imdb_source" in
            dirname) ((STATS_IMDB_SOURCE_DIRNAME++)) ;;
            nfo) ((STATS_IMDB_SOURCE_NFO++)) ;;
            mapping) ((STATS_IMDB_SOURCE_MAPPING++)) ;;
            omdb) ((STATS_IMDB_SOURCE_OMDB++)) ;;
            ddgr) ((STATS_IMDB_SOURCE_DDGR++)) ;;
        esac
        ((STATS_IMDB_SUCCESS++))

        # Write to NFO cache for faster subsequent runs
        # Skip if source is already "nfo" (already cached)
        if [[ "$imdb_source" != "nfo" ]]; then
            write_nfo_cache "$movie_dir" "$imdb_id" "$movie_name" "$movie_year" "$imdb_source" \
                "$omdb_plot" "$omdb_director" "$omdb_genre" "$omdb_runtime" "$omdb_rating" "$omdb_premiered" || true
        fi
    else
        ((STATS_IMDB_FAIL++))
    fi

    # Create marker for tracking new files
    local marker_file
    marker_file="$(safe_temp_file "marker")"
    touch "$marker_file"

    # Try each provider - stop after first success
    local subtitle_found=false
    if run_subdownloader "$movie_dir" "$language"; then
        debug "Subtitle found via subdownloader, skipping remaining providers"
        subtitle_found=true
    elif run_subliminal "$movie_dir" "$language"; then
        debug "Subtitle found via subliminal, skipping remaining providers"
        subtitle_found=true
    else
        if download_opensubtitles "$movie_dir" "$language" "$imdb_id"; then
            subtitle_found=true
        fi
    fi

    # Update subtitle statistics
    if [[ "$subtitle_found" == "true" ]]; then
        ((STATS_SUBTITLE_SUCCESS++))
    else
        ((STATS_SUBTITLE_FAIL++))
    fi

    # Apply renaming if enabled
    if [[ "${RENAME}" == "true" ]]; then
        rename_subtitles "$movie_dir" "$language" "$marker_file" "$movie_name" "$movie_resolution" "$movie_year"
    fi

    rm -f "$marker_file"
}

# Validate subtitle file quality
validate_subtitle() {
    local subtitle_file="$1"

    # 1. Check file size (must be > 500 bytes)
    local size=$(wc -c < "$subtitle_file" 2>/dev/null || echo "0")
    if [[ "$size" -lt 500 ]]; then
        debug "Subtitle file too small ($size bytes) - likely invalid"
        return 1
    fi

    # 2. Check for subtitle timestamps
    if ! grep -qE '^[0-9]+$|^[0-9]{2}:[0-9]{2}:|^\[.*\]|^Dialogue:' "$subtitle_file" 2>/dev/null; then
        debug "No subtitle timestamps found - invalid format"
        return 1
    fi

    # 3. Check encoding (should be UTF-8 for Synology)
    if command -v file &>/dev/null; then
        local encoding=$(file -b --mime-encoding "$subtitle_file")
        if [[ "$encoding" != "utf-8" ]] && [[ "$encoding" != "us-ascii" ]]; then
            warn "Subtitle encoding is $encoding (Synology prefers UTF-8)"
        fi
    fi

    return 0
}

# Detect duplicate subtitles using hash comparison
detect_duplicate() {
    local new_file="$1"
    local movie_dir="$2"

    # Get hash of new file
    local new_hash=""
    if command -v md5 &>/dev/null; then
        new_hash=$(md5 -q "$new_file" 2>/dev/null)
    elif command -v shasum &>/dev/null; then
        new_hash=$(shasum -a 256 "$new_file" 2>/dev/null | cut -d' ' -f1)
    else
        # Fallback to size comparison only
        local new_size=$(wc -c < "$new_file" 2>/dev/null || echo "0")
        for existing in "$movie_dir"/*.{srt,sub,ass,ssa,vtt,idx,txt}; do
            [[ -f "$existing" ]] || continue
            [[ "$existing" == "$new_file" ]] && continue

            local existing_size=$(wc -c < "$existing" 2>/dev/null || echo "0")
            if [[ "$existing_size" -eq "$new_size" ]]; then
                debug "Duplicate detected (same size): $(basename "$existing")"
                return 0  # Duplicate found
            fi
        done
        return 1  # No duplicate
    fi

    # Compare hash with existing files
    for existing in "$movie_dir"/*.{srt,sub,ass,ssa,vtt,idx,txt}; do
        [[ -f "$existing" ]] || continue
        [[ "$existing" == "$new_file" ]] && continue

        local existing_hash=""
        if command -v md5 &>/dev/null; then
            existing_hash=$(md5 -q "$existing" 2>/dev/null)
        elif command -v shasum &>/dev/null; then
            existing_hash=$(shasum -a 256 "$existing" 2>/dev/null | cut -d' ' -f1)
        fi

        if [[ -n "$new_hash" && "$new_hash" == "$existing_hash" ]]; then
            debug "Duplicate detected (same hash): $(basename "$existing")"
            return 0  # Duplicate found
        fi
    done

    return 1  # No duplicate
}

# Rename subtitles with incremental naming
rename_subtitles() {
    local movie_dir="$1"
    local language="$2"
    local marker_file="$3"
    local movie_name="${4:-Movie}"
    local resolution="${5:-Unknown}"
    local movie_year="${6:-}"

    # Dry-run mode: skip renaming
    if [[ "$DRY_RUN" == "true" ]]; then
        debug "DRY-RUN: Would rename subtitles in $movie_dir"
        return 0
    fi

    # Find new subtitle files (all formats)
    local new_files=()
    while IFS= read -r -d '' file; do
        new_files+=("$file")
    done < <(find "$movie_dir" -maxdepth 1 \( -name "*.srt" -o -name "*.sub" -o -name "*.ass" -o -name "*.ssa" -o -name "*.vtt" -o -name "*.idx" -o -name "*.txt" \) -newer "$marker_file" -print0 2>/dev/null)

    debug "Found ${#new_files[@]} subtitle files newer than marker"

    if [[ ${#new_files[@]} -eq 0 ]]; then
        return
    fi

    # Format language
    local lang_lower=$(echo "$language" | tr '[:upper:]' '[:lower:]')
    local lang_title=$(echo "$lang_lower" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')

    # Format resolution
    if [[ -n "$resolution" ]]; then
        resolution="[${resolution}]"
    else
        # Check if we should keep original resolution from subtitle filename
        # or default to [Unknown]
        resolution="[Unknown]"
    fi

    # Validate and filter subtitle files before renaming
    local valid_files=()
    for file in "${new_files[@]}"; do
        # Validate subtitle quality
        if ! validate_subtitle "$file"; then
            warn "   Removing invalid subtitle: $(basename "$file")"
            rm -f "$file"
            continue
        fi

        # Check for duplicates
        if detect_duplicate "$file" "$movie_dir"; then
            warn "   Removing duplicate subtitle: $(basename "$file")"
            rm -f "$file"
            continue
        fi

        valid_files+=("$file")
    done

    # Update new_files to only include valid, non-duplicate files
    if [[ ${#valid_files[@]} -gt 0 ]]; then
        new_files=("${valid_files[@]}")
    else
        new_files=()
    fi

    if [[ ${#new_files[@]} -eq 0 ]]; then
        debug "No valid subtitle files after validation"
        return
    fi

    debug "Validated ${#new_files[@]} subtitle files"

    # Rename files
    local counter=1
    for file in "${new_files[@]}"; do
        # Get file extension
        local ext="${file##*.}"

        # Skip already renamed files
        if [[ "$(basename "$file")" =~ \.[a-z]{2}\.[A-Z][a-z]+[0-9]+\. ]]; then
            continue
        fi

        # Try to preserve resolution from original subtitle filename if movie doesn't have it
        local use_resolution="$resolution"
        if [[ "$resolution" == "[Unknown]" ]] && [[ "$(basename "$file")" =~ \[([0-9]+p)\] ]]; then
            use_resolution="[${BASH_REMATCH[1]}]"
            debug "Preserving resolution from subtitle: $use_resolution"
        fi

        # Build subtitle name with year if available
        local new_name
        if [[ -n "$movie_year" ]]; then
            new_name="${movie_name} (${movie_year}) ${use_resolution}.${lang_lower}.${lang_title}${counter}.${ext}"
        else
            new_name="${movie_name} ${use_resolution}.${lang_lower}.${lang_title}${counter}.${ext}"
        fi
        local new_path="${movie_dir}/${new_name}"

        if [[ ! -f "$new_path" ]]; then
            if mv "$file" "$new_path" 2>/dev/null; then
                info "   Renamed: $(basename "$file") -> $new_name"
                ((counter++))
            fi
        else
            debug "   Skipped rename (target exists): $(basename "$file")"
        fi
    done
}

# Show summary statistics (Sprint 3)
show_summary_statistics() {
    info ""
    info "=================================================="
    info "Summary Statistics"
    info "=================================================="
    info ""
    info "IMDb Lookup:"
    info "  Success: $STATS_IMDB_SUCCESS"
    info "  Failed:  $STATS_IMDB_FAIL"

    if [[ $STATS_IMDB_SUCCESS -gt 0 ]]; then
        info ""
        info "  IMDb Sources:"
        [[ $STATS_IMDB_SOURCE_DIRNAME -gt 0 ]] && info "    Directory name: $STATS_IMDB_SOURCE_DIRNAME"
        [[ $STATS_IMDB_SOURCE_NFO -gt 0 ]] && info "    NFO file:       $STATS_IMDB_SOURCE_NFO"
        [[ $STATS_IMDB_SOURCE_MAPPING -gt 0 ]] && info "    Manual mapping: $STATS_IMDB_SOURCE_MAPPING"
        [[ $STATS_IMDB_SOURCE_OMDB -gt 0 ]] && info "    OMDb API:       $STATS_IMDB_SOURCE_OMDB"
        [[ $STATS_IMDB_SOURCE_DDGR -gt 0 ]] && info "    Web search:     $STATS_IMDB_SOURCE_DDGR"
    fi

    info ""
    info "Subtitle Download:"
    info "  Success: $STATS_SUBTITLE_SUCCESS"
    info "  Failed:  $STATS_SUBTITLE_FAIL"

    if [[ $STATS_SUBTITLE_SUCCESS -gt 0 ]]; then
        info ""
        info "  Subtitle Sources:"
        [[ $STATS_SUBTITLE_SOURCE_SUBLIMINAL -gt 0 ]] && info "    Subliminal:     $STATS_SUBTITLE_SOURCE_SUBLIMINAL"
        [[ $STATS_SUBTITLE_SOURCE_OPENSUB -gt 0 ]] && info "    OpenSubtitles:  $STATS_SUBTITLE_SOURCE_OPENSUB"
    fi

    info ""
    info "Success Rate:"
    local total_ops=$((STATS_IMDB_SUCCESS + STATS_IMDB_FAIL))
    if [[ $total_ops -gt 0 ]]; then
        local imdb_rate=$((STATS_IMDB_SUCCESS * 100 / total_ops))
        info "  IMDb lookup: ${imdb_rate}% ($STATS_IMDB_SUCCESS/$total_ops)"
    fi

    if [[ $total_ops -gt 0 ]]; then
        local subtitle_rate=$((STATS_SUBTITLE_SUCCESS * 100 / total_ops))
        info "  Subtitles:   ${subtitle_rate}% ($STATS_SUBTITLE_SUCCESS/$total_ops)"
    fi

    info "=================================================="
}

# Survey mode functions

# Check if a folder has an NFO file
has_nfo_file() {
    local dir="$1"
    [[ -n $(find "$dir" -maxdepth 1 -name "*.nfo" -print -quit 2>/dev/null) ]] && return 0 || return 1
}

# Load survey state (processed folders)
load_survey_state() {
    if [[ -f "$SURVEY_STATE_FILE" ]]; then
        cat "$SURVEY_STATE_FILE"
    fi
}

# Save survey state (mark folder as processed)
save_survey_state() {
    local folder_path="$1"
    echo "$folder_path" >> "$SURVEY_STATE_FILE"
}

# Check if folder was already processed
is_folder_processed() {
    local folder_path="$1"
    [[ -f "$SURVEY_STATE_FILE" ]] && grep -Fxq "$folder_path" "$SURVEY_STATE_FILE" 2>/dev/null
}

# Check if we should stop due to API budget
should_stop_for_api_budget() {
    local current_count=$(load_api_state)
    [[ $current_count -ge $API_BUDGET_LIMIT ]] && return 0 || return 1
}

# Progress feedback for long operations
show_progress() {
    local current="$1"
    local total="$2"
    local operation="$3"
    # Use \r to overwrite the same line (carriage return without newline)
    printf "\r[INFO] %s: %d/%s folders" "$operation" "$current" "$total" >&2
}

# Progress feedback for scanning (discovery phase)
show_scan_progress() {
    local count="$1"
    # Use \r to overwrite the same line (carriage return without newline)
    printf "\r[INFO] Scanning: %d folders discovered" "$count" >&2
}

clear_progress() {
    # Clear the progress line
    printf "\r%-80s\r" "" >&2
}

# Calculate seconds until midnight (API quota reset)
seconds_until_midnight() {
    local current_epoch=$(date +%s)
    local current_date=$(date +%Y-%m-%d)
    # Get tomorrow's date at 00:00:00
    local tomorrow_midnight=$(date -j -f "%Y-%m-%d %H:%M:%S" "${current_date} 23:59:59" +%s 2>/dev/null)
    if [[ -z "$tomorrow_midnight" ]]; then
        # Fallback for systems without -j flag
        tomorrow_midnight=$(date -d "tomorrow 00:00:00" +%s 2>/dev/null || echo $((current_epoch + 86400)))
    fi
    local seconds_remaining=$((tomorrow_midnight - current_epoch + 1))
    echo "$seconds_remaining"
}

# Format seconds into human-readable time
format_time() {
    local total_seconds="$1"
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

# Countdown display until API budget resets
wait_for_api_reset() {
    local remaining_seconds=$(seconds_until_midnight)
    local reset_time=$(date -v+1d +"%Y-%m-%d 00:00:00" 2>/dev/null || date -d "tomorrow" +"%Y-%m-%d 00:00:00" 2>/dev/null)

    warn ""
    warn "=================================================="
    warn "API Budget Limit Reached ($API_BUDGET_LIMIT/$API_LIMIT)"
    warn "=================================================="
    warn "Pausing until quota resets at: $reset_time"
    warn "Press Ctrl+C to exit and resume later"
    warn ""

    # Countdown loop
    while [[ $remaining_seconds -gt 0 ]]; do
        local time_display=$(format_time "$remaining_seconds")
        printf "\r[WAIT] API quota resets in: %s (hh:mm:ss)" "$time_display" >&2
        sleep 1
        ((remaining_seconds--))
    done

    # Clear countdown line and show reset message
    printf "\r%-80s\r" "" >&2
    info ""
    info "=================================================="
    info "API Quota Reset - Resuming Processing"
    info "=================================================="
    info ""

    # Small delay to ensure the new day has started
    sleep 2
}

# Main function
main() {
    check_dependencies
    check_optional_components
    parse_args "$@"

    info "Sublingual v${SCRIPT_VERSION} starting..."
    info "Configuration:"
    info "  Movie dir: ${MOVIE_DIR}"
    info "  Languages: ${LANGUAGES}"
    info "  OMDB Key: $([ -n "${OMDB_KEY}" ] && echo "Configured" || echo "Not set")"
    info "  Year range: 1920-${CURRENT_YEAR}"
    info "  Dry-run: ${DRY_RUN}"
    info "  Survey mode: ${SURVEY_MODE}"

    # Show API usage status
    local current_api_count=$(load_api_state)
    local api_remaining=$((API_LIMIT - current_api_count))
    info "  API Usage: $current_api_count/$API_LIMIT calls used today ($api_remaining remaining)"

    # Validate OMDb API key is configured
    if [[ -z "${OMDB_KEY}" ]]; then
        echo ""
        error "OMDb API key is not configured!"
        error ""
        error "Sublingual requires an OMDb API key to function properly."
        error "Please apply for a FREE API key at:"
        error "  https://www.omdbapi.com/apikey.aspx"
        error ""
        error "After receiving your key, configure it using one of these methods:"
        error "  1. Environment variable: export OMDB_API_KEY='your-key-here'"
        error "  2. Command-line flag: --omdb-key your-key-here"
        error ""
        exit 1
    fi

    # Process languages
    IFS=',' read -ra languages <<< "${LANGUAGES}"

    # Survey mode: infinite loop to continuously monitor and process
    local survey_cycle=1
    while true; do
        # Show cycle info in survey mode
        if [[ "$SURVEY_MODE" == "true" ]]; then
            info ""
            info "=================================================="
            info "Survey Cycle #${survey_cycle}"
            info "=================================================="
        fi

    # Find all movie directories
    info ""
    info "Scanning for movie directories..."
    local all_dirs=()
    local scan_count=0

    # First check if the provided path itself contains videos
    if find "${MOVIE_DIR}" -maxdepth 1 \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \) -print -quit | grep -q .; then
        all_dirs+=("${MOVIE_DIR}")
        ((scan_count++))
        show_scan_progress "$scan_count"
    else
        # Otherwise search subdirectories with progress feedback
        while IFS= read -r -d '' dir; do
            if find "$dir" -maxdepth 1 \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \) -print -quit | grep -q .; then
                all_dirs+=("$dir")
                ((scan_count++))
                # Show progress every 10 folders to avoid terminal spam
                if (( scan_count % 10 == 0 )) || [[ $scan_count -eq 1 ]]; then
                    show_scan_progress "$scan_count"
                fi
            fi
        done < <(find "${MOVIE_DIR}" -mindepth 1 -type d -print0)
    fi

    clear_progress
    info "Found ${#all_dirs[@]} movie directories"

    # Survey mode: smart prioritization
    local movie_dirs=()
    if [[ "$SURVEY_MODE" == "true" ]]; then
        info "Survey mode: Analyzing folders and building priority queue..."

        # Priority 1: Folders without NFO (need API calls - limited by quota)
        local no_nfo_dirs=()
        # Priority 2: Folders with NFO (0 API calls - unlimited, but network I/O for subtitles)
        local with_nfo_dirs=()

        local analyzed=0
        local total_to_analyze=${#all_dirs[@]}

        for dir in "${all_dirs[@]}"; do
            ((analyzed++))

            # Show progress every 10 folders
            if (( analyzed % 10 == 0 )) || [[ $analyzed -eq 1 ]] || [[ $analyzed -eq $total_to_analyze ]]; then
                show_progress "$analyzed" "$total_to_analyze" "Analyzing"
            fi

            # Skip already processed folders
            if is_folder_processed "$dir"; then
                debug "Skipping already processed: $(basename "$dir")"
                continue
            fi

            if has_nfo_file "$dir"; then
                with_nfo_dirs+=("$dir")
            else
                no_nfo_dirs+=("$dir")
            fi
        done

        clear_progress
        info "  Priority 1 (no NFO, needs API): ${#no_nfo_dirs[@]} folders"
        info "  Priority 2 (has NFO, 0 API): ${#with_nfo_dirs[@]} folders"

        # Combine: no-NFO first, then with-NFO
        movie_dirs=("${no_nfo_dirs[@]}" "${with_nfo_dirs[@]}")
    else
        movie_dirs=("${all_dirs[@]}")
    fi

    # Process each movie/language combination
    local total_processed=0
    local total_operations=$((${#movie_dirs[@]} * ${#languages[@]}))
    local stopped_for_api_budget=false

    # Main processing loop - continues until all movies processed
    local dir_index=0
    while [[ $dir_index -lt ${#movie_dirs[@]} ]]; do
        local dir="${movie_dirs[$dir_index]}"

        # Check API budget in survey mode - wait if needed
        if [[ "$SURVEY_MODE" == "true" ]] && should_stop_for_api_budget; then
            stopped_for_api_budget=true
            # Wait for API quota to reset (countdown display)
            wait_for_api_reset
            # After reset, continue processing
            stopped_for_api_budget=false
            # Don't increment dir_index - reprocess this directory
            continue
        fi

        for lang in "${languages[@]}"; do
            ((total_processed++))

            # Progress indicator
            info "=================================================="
            if [[ "$SURVEY_MODE" == "true" ]]; then
                info "Progress: $total_processed/$total_operations (Survey mode - continuous)"
            else
                info "Progress: $total_processed/$total_operations"
            fi
            info "=================================================="

            process_movie "$dir" "$lang"

            # Mark as processed in survey mode
            if [[ "$SURVEY_MODE" == "true" ]]; then
                save_survey_state "$dir"
            fi

            # Pause between operations
            sleep "${PAUSE}"
        done

        # Move to next directory
        ((dir_index++))
    done

        info ""
        info "=================================================="
        info "Survey Cycle #${survey_cycle} Complete"
        info "=================================================="
        info "   Total operations: $total_processed"

        # Show final API usage
        local final_api_count=$(load_api_state)
        local final_api_remaining=$((API_LIMIT - final_api_count))
        info "   API calls used: $final_api_count/$API_LIMIT ($final_api_remaining remaining today)"

        # Show summary statistics (Sprint 3)
        show_summary_statistics

        # Break out of infinite loop if not in survey mode
        if [[ "$SURVEY_MODE" != "true" ]]; then
            info ""
            info "=================================================="
            info "Processing complete"
            info "=================================================="
            break
        fi

        # Survey mode: prepare for next cycle
        info ""
        info "=================================================="
        info "Cycle Cleanup and Preparation"
        info "=================================================="

        # Clear survey state file to re-process all folders in next cycle
        if [[ -f "$SURVEY_STATE_FILE" ]]; then
            info "   Clearing survey state file for next cycle..."
            rm -f "$SURVEY_STATE_FILE"
            debug "Survey state file cleared: $SURVEY_STATE_FILE"
        fi

        # Increment cycle counter for next iteration
        ((survey_cycle++))

        # Calculate inter-cycle delay based on API usage
        local current_api_usage=$(load_api_state)
        local inter_cycle_delay=3600  # Default: 1 hour

        # If we used significant API quota, wait until after midnight for fresh quota
        if [[ $current_api_usage -ge 400 ]]; then
            # Calculate seconds until midnight + 5 minute buffer
            inter_cycle_delay=$(seconds_until_midnight)
            ((inter_cycle_delay += 300))  # Add 5 minute buffer after midnight

            local hours_to_wait=$((inter_cycle_delay / 3600))
            local next_start_time=$(date -v+${inter_cycle_delay}S +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d "+${inter_cycle_delay} seconds" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)

            info "   API usage is high ($current_api_usage/$API_LIMIT calls used)"
            info "   Waiting until API quota resets before next cycle..."
            info "   Next cycle starts at: $next_start_time (~${hours_to_wait}h)"
        else
            info "   API usage is low ($current_api_usage/$API_LIMIT calls used)"
            info "   Waiting 1 hour before next cycle..."
        fi

        info "   Press Ctrl+C to stop continuous survey"

        # Countdown for inter-cycle delay
        local remaining=$inter_cycle_delay
        while [[ $remaining -gt 0 ]]; do
            local time_display=$(format_time "$remaining")
            printf "\r[WAIT] Next cycle starts in: %s (hh:mm:ss)" "$time_display" >&2
            sleep 1
            ((remaining--))
        done

        # Clear countdown line
        printf "\r%-80s\r" "" >&2
        info ""
        info "=================================================="
        info "Starting Next Survey Cycle"
        info "=================================================="
        info ""
    done  # End of infinite while true loop
}

# Show version
show_version() {
    cat << EOF
Sublingual ${SCRIPT_VERSION}
Batch movie multi-language subtitle downloader with NFO caching and survey mode
Copyright (c) 2025 - MIT License
https://github.com/kitpaul/sublingual
EOF

    # Show dependency versions
    show_dependency_status "true"
}

# Show help
show_help() {
    cat << EOF
Sublingual ${SCRIPT_VERSION} - Intelligent Subtitle Downloader

ABOUT
    Sublingual is an intelligent subtitle downloader that automates the discovery,
    downloading, and organization of subtitles for your movie collection.

HOW IT WORKS
    1. IMDb Identification: Identifies movies using a multi-method approach:
       - Directory names with IMDb IDs
       - Existing NFO metadata files (Kodi/Plex/Jellyfin compatible)
       - Manual mapping file for edge cases
       - OMDb API lookups (with smart caching)
       - Web search fallback via ddgr

    2. NFO Caching: Creates/updates .nfo files to cache IMDb metadata,
       eliminating redundant API calls on subsequent runs. Compatible with
       Kodi, Plex, and Jellyfin media servers.

    3. Subtitle Download: Fetches subtitles from multiple sources:
       - Subliminal (Python package)
       - OpenSubtitles (direct integration)
       - Subdownloader (optional)

    4. Smart Organization: Renames subtitles with standardized naming:
       MovieName (Year) [Resolution].language.Language1.ext

    5. Survey Mode: Continuously monitors large collections (10,000+ movies),
       automatically detecting new additions and checking for subtitle updates.

USAGE
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS
    --folder PATH       Movie directory to process (required)
    --language CODES    Comma-separated 2-letter language codes (default: EN)
                        Examples: EN, EN,RO,FR,DE, EN,ES,IT,PT
                        Supports 35+ languages (see SUPPORTED LANGUAGES below)
    --omdb-key KEY      OMDb API key for movie identification
                        Can also be set via OMDB_API_KEY environment variable
                        Get your free key at: https://www.omdbapi.com/apikey.aspx
    --pause SECONDS     Pause between operations (default: 1)
    --survey            Enable survey mode for continuous monitoring
    --dry-run           Preview operations without making changes
    --debug             Enable verbose debug logging
    --no-rename         Keep original subtitle filenames
    --workers N         Reserved for future parallel processing (default: 4)
    --help, -h          Show this help message
    --version, -v       Show version information

ENVIRONMENT VARIABLES
    OMDB_API_KEY        OMDb API key (can be overridden by --omdb-key flag)

EXAMPLES
    # Basic usage - English subtitles
    ${SCRIPT_NAME} --folder "/Movies" --language EN --omdb-key YOUR_KEY

    # Multiple European languages
    ${SCRIPT_NAME} --folder "/Movies" --language EN,FR,DE,ES,IT --omdb-key YOUR_KEY

    # European + Asian languages
    ${SCRIPT_NAME} --folder "/Movies" --language EN,RO,AR,ZH,JA --omdb-key YOUR_KEY

    # Survey mode for continuous monitoring (large collections)
    ${SCRIPT_NAME} --folder "/Movies" --language EN,ES,PT --survey --omdb-key YOUR_KEY

    # Run in background with logging
    nohup ${SCRIPT_NAME} --folder "/Movies" --language EN,FR --survey > sublingual.log 2>&1 &

    # Dry-run mode to preview operations
    ${SCRIPT_NAME} --folder "/Movies" --language EN --dry-run --omdb-key YOUR_KEY

    # Using environment variable for API key
    export OMDB_API_KEY=your_key_here
    ${SCRIPT_NAME} --folder "/Movies" --language EN,DE,IT,PT

REQUIREMENTS
    Required Commands:
      - curl, unzip, file (typically pre-installed on macOS/Linux)

    Optional Commands:
      - subliminal: pip install subliminal
      - subdownloader: pip install subdownloader
      - ddgr: brew install ddgr (improves IMDb lookup success rate)

    API Key:
      - Free OMDb API key from: https://www.omdbapi.com/apikey.aspx
      - Limited to 500 calls/day (automatically managed by script)

KEY FEATURES
    NFO Caching:
      - Creates .nfo files compatible with Kodi, Plex, and Jellyfin
      - Eliminates redundant API calls on subsequent runs
      - Makes re-runs near-instant with zero API usage

    Survey Mode:
      - Infinite loop operation for large collections (10,000+ movies)
      - Auto-pauses at 490/500 API calls, resumes after midnight
      - Detects new movies and checks for subtitle updates continuously
      - Smart inter-cycle delays based on API usage

    Smart Movie Identification:
      - Directory names → NFO files → Manual mapping → OMDb API → Web search
      - Automatic year detection (1920-${CURRENT_YEAR})
      - Handles foreign titles and edge cases

    Quality Control:
      - Validates subtitle files (size, timestamps, encoding)
      - Detects and removes duplicates
      - Standardized naming: MovieName (Year) [Resolution].lang.Lang1.ext

FILES AND STATE
    ~/.sublingual_api_state       API call tracking (resets daily)
    ~/.sublingual_imdb_map        Manual movie-to-IMDb mappings
    ~/.sublingual_survey_state    Survey mode progress tracking

SUPPORTED LANGUAGES
    European:
      EN (English)    FR (French)     DE (German)     ES (Spanish)
      IT (Italian)    PT (Portuguese) NL (Dutch)      PL (Polish)
      RU (Russian)    EL (Greek)      TR (Turkish)    SV (Swedish)
      NO (Norwegian)  DA (Danish)     FI (Finnish)    CS (Czech)
      HU (Hungarian)  BG (Bulgarian)  HR (Croatian)   SR (Serbian)
      SK (Slovak)     SL (Slovenian)  UK (Ukrainian)  RO (Romanian)

    Asian:
      AR (Arabic)     ZH (Chinese)    JA (Japanese)   KO (Korean)
      HI (Hindi)      TH (Thai)       VI (Vietnamese) ID (Indonesian)

    Other:
      HE (Hebrew)     FA (Persian)    BN (Bengali)

    Note: Language codes are case-insensitive (en, EN, eN all work)

NOTES
    - Supported subtitle formats: .srt, .sub, .ass, .ssa, .vtt, .idx, .txt
    - Stops after first successful subtitle download per provider
    - Compatible with macOS bash 3.2 (no bash 4+ required)
    - Use Ctrl+C to stop survey mode gracefully

PROJECT
    Homepage: https://github.com/kitpaul/sublingual
    License: MIT
    Version: ${SCRIPT_VERSION}

EOF

    # Show dependency status (without versions)
    show_dependency_status "false"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # If no arguments provided, show version and help invitation
    if [[ $# -eq 0 ]]; then
        show_version
        echo ""
        echo "Run '${SCRIPT_NAME} --help' for usage information."
        exit 0
    fi

    main "$@"
fi

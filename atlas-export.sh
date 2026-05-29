#!/usr/bin/env bash
#
# atlas-export.sh — Bulk-export all collections from a MongoDB Atlas cluster.
#
# Exports every collection as line-delimited JSON, splits files that exceed a
# size threshold, and packages everything into a zip archive with the hierarchy:
#
#     <project>/<cluster>/<database>/<collection>.json
#
# Requires: mongosh, mongoexport (MongoDB Database Tools), zip, split
#

set -euo pipefail

# Restrict file permissions: only owner can read/write exported data.
umask 077

# Temp directory for config files (credentials); cleaned up on exit.
TMPDIR_SECURE=$(mktemp -d)

cleanup() {
    rm -rf "$TMPDIR_SECURE"
}

# Ensure Ctrl+C aborts the entire script and cleans up temp files.
trap 'printf "\n[ABORT] Export cancelled by user.\n" >&2; cleanup; exit 130' INT TERM
trap cleanup EXIT

# ─── Defaults ────────────────────────────────────────────────────────────────

ENV_FILE=".env"
OUTPUT_DIR="./atlas-export"
MAX_FILE_SIZE=$(( 500 * 1024 * 1024 ))   # 500 MB
FILTER=""
PROJECT=""
CLUSTER=""
HOST=""
USERNAME=""
PASSWORD=""
BACKUP_NAME=""
KEEP_RAW=false
SYSTEM_DBS="admin local config"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── Counters ────────────────────────────────────────────────────────────────

TOTAL_DBS=0
TOTAL_COLLECTIONS=0
TOTAL_EXPORTED=0
TOTAL_ERRORS=0
TOTAL_SPLITS=0

# ─── Colors (disabled when stderr is not a terminal) ─────────────────────────

if [[ -t 2 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: atlas-export.sh [OPTIONS]

Export all collections from a MongoDB Atlas cluster as compressed JSON.

REQUIRED
  --host <host>             Atlas cluster host (e.g. cluster0.abc123.mongodb.net)
  --username <user>         MongoDB username
  --password <pass>         MongoDB password
  --project <name>          Atlas project name  (top-level folder in the archive)
  --cluster <name>          Atlas cluster name   (second-level folder)

OPTIONAL
  --env-file <path>         Path to .env file               (default: .env in cwd)
  --no-env                  Skip loading .env file
  --filter <substring>      Only export databases whose name contains <substring>
                            (case-insensitive).  Example: --filter "Action_hub_"
  --output-dir <dir>        Base output directory           (default: ./atlas-export)
  --max-file-size <size>    Split threshold per file        (default: 500M)
                            Accepts K/KB, M/MB, G/GB.
  --backup-name <name>      Prefix for the zip file name    (default: none; produces <prefix>_<project>_<cluster>_<timestamp>.zip)
  --keep-raw                Keep uncompressed files after zipping
  --help                    Show this message

ENVIRONMENT / .env FILE
  The script loads a .env file (from cwd by default) before processing CLI args.
  CLI flags always override .env values.  Supported variables:

    ATLAS_HOST              Cluster host
    ATLAS_USERNAME          MongoDB username
    ATLAS_PASSWORD          MongoDB password
    ATLAS_PROJECT           Project name
    ATLAS_CLUSTER           Cluster name
    ATLAS_FILTER            Database name filter
    ATLAS_OUTPUT_DIR        Output directory
    ATLAS_BACKUP_NAME       Prefix for the zip file name
    ATLAS_MAX_FILE_SIZE     Split threshold (e.g. 500M)

EXAMPLES
  # Export everything
  atlas-export.sh \
    --host cluster0.abc123.mongodb.net \
    --username admin --password 's3cret' \
    --project MyProject --cluster Production

  # Export only databases whose name contains "Action_hub_"
  atlas-export.sh \
    --host cluster0.abc123.mongodb.net \
    --username admin --password 's3cret' \
    --project MyProject --cluster Production \
    --filter "Action_hub_"

  # Use a 100 MB split threshold
  atlas-export.sh \
    --host cluster0.abc123.mongodb.net \
    --username admin --password 's3cret' \
    --project MyProject --cluster Production \
    --max-file-size 100M
EOF
}

log_info()  { printf "${BLUE}[INFO]${NC}  %s\n"  "$*" >&2; }
log_ok()    { printf "${GREEN}[OK]${NC}    %s\n"  "$*" >&2; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*" >&2; }
log_error() { printf "${RED}[ERROR]${NC} %s\n"    "$*" >&2; }

# URL-encode a string so special characters in passwords don't break the URI.
urlencode() {
    local string="$1" i c encoded=""
    for (( i = 0; i < ${#string}; i++ )); do
        c="${string:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$encoded"
}

# Parse human-readable size string → bytes.
parse_size() {
    local raw="$1"
    local number unit
    number=$(printf '%s' "$raw" | sed 's/[^0-9.]//g')
    unit=$(printf '%s' "$raw" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    case "$unit" in
        K|KB) echo $(( ${number%.*} * 1024 )) ;;
        M|MB) echo $(( ${number%.*} * 1024 * 1024 )) ;;
        G|GB) echo $(( ${number%.*} * 1024 * 1024 * 1024 )) ;;
        "")   echo "${number%.*}" ;;
        *)    log_error "Unknown size unit in '$raw'"; exit 1 ;;
    esac
}

# Cross-platform file size in bytes.
get_file_size() {
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f%z "$1" 2>/dev/null || echo 0
    else
        stat -c%s "$1" 2>/dev/null || echo 0
    fi
}

# Bytes → human-readable string.
format_size() {
    local b=$1
    if   (( b >= 1073741824 )); then printf '%s.%sG' "$(( b/1073741824 ))" "$(( (b%1073741824)*10/1073741824 ))"
    elif (( b >= 1048576 ));    then printf '%s.%sM' "$(( b/1048576 ))"    "$(( (b%1048576)*10/1048576 ))"
    elif (( b >= 1024 ));       then printf '%sK'    "$(( b/1024 ))"
    else                             printf '%sB'    "$b"
    fi
}

# Verify required CLI tools are available.
check_prerequisites() {
    local missing=()
    for cmd in mongosh mongoexport zip split; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        log_error "Missing required tools: ${missing[*]}"
        echo >&2
        echo "  mongosh + mongoexport → https://www.mongodb.com/try/download/database-tools" >&2
        echo "  zip                   → brew install zip  /  apt install zip" >&2
        exit 1
    fi
}

# Sanitize a name for use as a filesystem path component.
# Prevents path traversal via "../" or absolute paths in db/collection names.
sanitize_name() {
    printf '%s' "$1" | tr '/\\' '__' | sed 's/^\.\.*//'
}

# Split a JSON file into numbered parts if it exceeds the threshold.
# Returns 0 if the file was split, 1 if no split was needed.
split_large_file() {
    local file="$1" max_size="$2"
    local file_size
    file_size=$(get_file_size "$file")

    (( file_size <= max_size )) && return 1

    local total_lines
    total_lines=$(wc -l < "$file" | tr -d ' ')
    (( total_lines == 0 )) && return 1

    # Aim for chunks just under the threshold.
    local lines_per_chunk=$(( total_lines * max_size / file_size ))
    (( lines_per_chunk < 1 )) && lines_per_chunk=1

    local base="${file%.json}"

    # split creates <base>.partaa, <base>.partab, …
    split -l "$lines_per_chunk" "$file" "${base}.part"

    # Rename to <base>.part001.json, .part002.json, …
    local n=1
    for part in "${base}".part*; do
        mv "$part" "$(printf '%s.part%03d.json' "$base" "$n")"
        n=$(( n + 1 ))
    done

    rm -f "$file"

    local num_parts=$(( n - 1 ))
    log_info "    Split into $num_parts parts (~$(format_size "$max_size") each)"
    return 0
}

# ─── Load .env File ──────────────────────────────────────────────────────────

# Parse --env-file / --no-env early (before full arg parsing) so the .env is
# loaded first, then CLI flags can override.
SKIP_ENV=false
for arg in "$@"; do
    case "$arg" in
        --no-env)    SKIP_ENV=true ;;
        --env-file)  ;; # value handled below
    esac
done
# Extract --env-file value if provided.
for (( i=1; i<=$#; i++ )); do
    if [[ "${!i}" == "--env-file" ]]; then
        next=$(( i + 1 ))
        ENV_FILE="${!next}"
        break
    fi
done

if [[ "$SKIP_ENV" == false && -f "$ENV_FILE" ]]; then
    # Warn if .env is readable by group or others (contains credentials).
    local_perms=""
    if [[ "$(uname)" == "Darwin" ]]; then
        local_perms=$(stat -f%Lp "$ENV_FILE" 2>/dev/null)
    else
        local_perms=$(stat -c%a "$ENV_FILE" 2>/dev/null)
    fi
    if [[ -n "$local_perms" && "$local_perms" != "600" && "$local_perms" != "400" ]]; then
        log_warn "$ENV_FILE is accessible to other users (mode $local_perms). Recommend: chmod 600 $ENV_FILE"
    fi

    log_info "Loading settings from $ENV_FILE"
    # Source only well-formed KEY=VALUE lines; ignore comments and blank lines.
    while IFS='=' read -r key value; do
        # Strip leading/trailing whitespace from key.
        key=$(printf '%s' "$key" | xargs)
        # Skip comments and empty lines.
        [[ -z "$key" || "$key" == \#* ]] && continue
        # Strip surrounding quotes and trailing whitespace from value.
        value=$(printf '%s' "$value" | sed "s/^['\"]//;s/['\"]$//;s/[[:space:]]*$//")
        case "$key" in
            ATLAS_HOST)          [[ -z "$HOST" ]]     && HOST="$value" ;;
            ATLAS_USERNAME)      [[ -z "$USERNAME" ]] && USERNAME="$value" ;;
            ATLAS_PASSWORD)      [[ -z "$PASSWORD" ]] && PASSWORD="$value" ;;
            ATLAS_PROJECT)       [[ -z "$PROJECT" ]]  && PROJECT="$value" ;;
            ATLAS_CLUSTER)       [[ -z "$CLUSTER" ]]  && CLUSTER="$value" ;;
            ATLAS_FILTER)        [[ -z "$FILTER" ]]   && FILTER="$value" ;;
            ATLAS_OUTPUT_DIR)    OUTPUT_DIR="$value" ;;
            ATLAS_BACKUP_NAME)   [[ -z "$BACKUP_NAME" ]] && BACKUP_NAME="$value" ;;
            ATLAS_MAX_FILE_SIZE) MAX_FILE_SIZE=$(parse_size "$value") ;;
        esac
    done < "$ENV_FILE"
elif [[ "$SKIP_ENV" == false && "$ENV_FILE" != ".env" ]]; then
    # User explicitly passed --env-file but file doesn't exist.
    log_error "Env file not found: $ENV_FILE"
    exit 1
fi

# ─── Argument Parsing ────────────────────────────────────────────────────────

# Show usage only if no args AND no .env was loaded.
if (( $# == 0 )) && [[ -z "$HOST" ]]; then
    usage; exit 1
fi

while (( $# )); do
    case "$1" in
        --host)          HOST="$2";      shift 2 ;;
        --username)      USERNAME="$2";  shift 2 ;;
        --password)      PASSWORD="$2";  shift 2 ;;
        --project)       PROJECT="$2";   shift 2 ;;
        --cluster)       CLUSTER="$2";   shift 2 ;;
        --filter)        FILTER="$2";    shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        --max-file-size) MAX_FILE_SIZE=$(parse_size "$2"); shift 2 ;;
        --backup-name)   BACKUP_NAME="$2"; shift 2 ;;
        --keep-raw)      KEEP_RAW=true;  shift ;;
        --env-file)      shift 2 ;;  # already handled above
        --no-env)        shift ;;    # already handled above
        --help)          usage; exit 0 ;;
        *)               log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ─── Validate Required Flags ────────────────────────────────────────────────

errors=()
[[ -z "$HOST" ]]     && errors+=("--host is required")
[[ -z "$USERNAME" ]] && errors+=("--username is required")
[[ -z "$PASSWORD" ]] && errors+=("--password is required")
[[ -z "$PROJECT" ]]  && errors+=("--project is required")
[[ -z "$CLUSTER" ]]  && errors+=("--cluster is required")

if (( ${#errors[@]} )); then
    for e in "${errors[@]}"; do log_error "$e"; done
    echo >&2; usage; exit 1
fi

check_prerequisites

# ─── Build Connection URI ────────────────────────────────────────────────────

ENCODED_USER=$(urlencode "$USERNAME")
ENCODED_PASS=$(urlencode "$PASSWORD")
URI="mongodb+srv://${ENCODED_USER}:${ENCODED_PASS}@${HOST}"
MASKED_URI="mongodb+srv://${ENCODED_USER}:****@${HOST}"

# Write a config file for mongoexport (avoids credentials in ps output).
MONGOEXPORT_CONFIG="${TMPDIR_SECURE}/mongoexport.yaml"
printf 'uri: "%s"\n' "$URI" > "$MONGOEXPORT_CONFIG"

# ─── Prepare Output Directories ─────────────────────────────────────────────

EXPORT_BASE="${OUTPUT_DIR}/${PROJECT}/${CLUSTER}"
mkdir -p "$EXPORT_BASE"

ERROR_LOG="${OUTPUT_DIR}/export-errors.log"
: > "$ERROR_LOG"

# ─── Test Connection ─────────────────────────────────────────────────────────

log_info "Connecting to ${MASKED_URI} …"

if ! mongosh "$URI" --quiet --eval 'db.adminCommand({ping:1})' &>/dev/null; then
    log_error "Connection failed. Verify host, username, and password."
    exit 1
fi
log_ok "Connected"

# ─── Discover Databases ─────────────────────────────────────────────────────

log_info "Listing databases…"

ALL_DBS=$(mongosh "$URI" --quiet --eval '
    db.adminCommand({listDatabases:1})
      .databases.map(d => d.name).join("\n")
')

# Strip system databases.
DBS=""
while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    skip=false
    for sysdb in $SYSTEM_DBS; do
        [[ "$db" == "$sysdb" ]] && { skip=true; break; }
    done
    $skip || DBS+="${db}"$'\n'
done <<< "$ALL_DBS"
DBS="${DBS%$'\n'}"           # trim trailing newline

# Apply --filter (case-insensitive substring match).
if [[ -n "$FILTER" ]]; then
    FILTERED=$(grep -i -- "$FILTER" <<< "$DBS" || true)
    if [[ -z "$FILTERED" ]]; then
        log_warn "No databases match filter '$FILTER'"
        log_info "Available databases:"
        while IFS= read -r db; do echo "  - $db" >&2; done <<< "$DBS"
        exit 0
    fi
    DBS="$FILTERED"
    log_info "Filter '$FILTER' matched $(wc -l <<< "$DBS" | tr -d ' ') database(s)"
fi

TOTAL_DBS=$(wc -l <<< "$DBS" | tr -d ' ')
log_info "Found $TOTAL_DBS database(s) to export"
while IFS= read -r db; do echo "  - $db" >&2; done <<< "$DBS"

# ─── Export Loop ─────────────────────────────────────────────────────────────

DB_NUM=0

while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    DB_NUM=$(( DB_NUM + 1 ))

    echo >&2
    log_info "[$DB_NUM/$TOTAL_DBS] Database: ${BOLD}${db}${NC}"

    DB_DIR="${EXPORT_BASE}/$(sanitize_name "$db")"
    mkdir -p "$DB_DIR"

    # List collections for this database.
    COLLECTIONS=$(mongosh "${URI}/${db}" --quiet --eval '
        db.getCollectionNames().join("\n")
    ' 2>/dev/null || true)

    if [[ -z "$COLLECTIONS" ]]; then
        log_warn "  No collections found (or access denied)"
        continue
    fi

    COL_COUNT=$(wc -l <<< "$COLLECTIONS" | tr -d ' ')
    TOTAL_COLLECTIONS=$(( TOTAL_COLLECTIONS + COL_COUNT ))
    log_info "  $COL_COUNT collection(s)"

    COL_NUM=0
    while IFS= read -r col; do
        [[ -z "$col" ]] && continue
        COL_NUM=$(( COL_NUM + 1 ))

        OUT_FILE="${DB_DIR}/$(sanitize_name "$col").json"
        log_info "  [$COL_NUM/$COL_COUNT] ${db}.${col}"

        # mongoexport writes one JSON document per line (line-delimited JSON).
        if mongoexport \
                --config="$MONGOEXPORT_CONFIG" \
                --db="$db" \
                --collection="$col" \
                --type=json \
                --out="$OUT_FILE" 2>/dev/null; then

            FILE_SIZE=$(get_file_size "$OUT_FILE")
            log_ok "    $(format_size "$FILE_SIZE")"

            if split_large_file "$OUT_FILE" "$MAX_FILE_SIZE"; then
                TOTAL_SPLITS=$(( TOTAL_SPLITS + 1 ))
            fi

            TOTAL_EXPORTED=$(( TOTAL_EXPORTED + 1 ))
        else
            log_error "    FAILED – ${db}.${col}"
            printf '[%s] FAILED: %s.%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$db" "$col" >> "$ERROR_LOG"
            TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
            rm -f "$OUT_FILE"   # remove partial output
        fi
    done <<< "$COLLECTIONS"

done <<< "$DBS"

# ─── Compress ────────────────────────────────────────────────────────────────

echo >&2
log_info "Compressing…"

if [[ -n "$BACKUP_NAME" ]]; then
    ZIP_NAME="${BACKUP_NAME}_${PROJECT}_${CLUSTER}_${TIMESTAMP}.zip"
else
    ZIP_NAME="${PROJECT}_${CLUSTER}_${TIMESTAMP}.zip"
fi
ZIP_PATH="${OUTPUT_DIR}/${ZIP_NAME}"

( cd "$OUTPUT_DIR" && zip -r -q "$ZIP_NAME" "${PROJECT}/" )

ZIP_SIZE=$(get_file_size "$ZIP_PATH")
log_ok "Archive: ${ZIP_PATH} ($(format_size "$ZIP_SIZE"))"

# ─── Cleanup ─────────────────────────────────────────────────────────────────

if [[ "$KEEP_RAW" == false ]]; then
    rm -rf "${OUTPUT_DIR:?}/${PROJECT}"
    log_info "Removed raw files (use --keep-raw to retain)"
fi

# Remove error log if empty.
[[ -s "$ERROR_LOG" ]] || rm -f "$ERROR_LOG"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo >&2
printf "${GREEN}═══════════════════════════════════════════════════════${NC}\n" >&2
printf "${GREEN}  Export Complete${NC}\n" >&2
printf "${GREEN}═══════════════════════════════════════════════════════${NC}\n" >&2
printf "  Project:       %s\n"   "$PROJECT"                     >&2
printf "  Cluster:       %s\n"   "$CLUSTER"                     >&2
printf "  Databases:     %s\n"   "$TOTAL_DBS"                   >&2
printf "  Collections:   %s exported\n" "$TOTAL_EXPORTED"       >&2
(( TOTAL_SPLITS )) && \
printf "  Split:         %s collection(s)\n" "$TOTAL_SPLITS"    >&2
(( TOTAL_ERRORS )) && \
printf "  ${RED}Errors:        %s  (see %s)${NC}\n" "$TOTAL_ERRORS" "$ERROR_LOG" >&2
printf "  Archive:       %s (%s)\n" "$ZIP_PATH" "$(format_size "$ZIP_SIZE")" >&2
printf "${GREEN}═══════════════════════════════════════════════════════${NC}\n" >&2

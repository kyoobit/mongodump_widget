#!/usr/bin/env bash

# -e: exit on error
# -u: error on undefined variables
# -o pipefail: fail pipeline if any command fails
set -euo pipefail

# Make word splitting predictable
IFS=$'\n\t';

# Required environment variables
readonly required_vars=(
    RCLONE_CONF
    OSS
    OSS_BUCKET
    OSS_PATH
    MONGO_DB
    MONGO_COL
    MONGO_URI
    MONGO_RO_USERNAME
    MONGO_RO_PASSWORD
    ENCRYPTION_PUBLIC_KEY
    RETENTION_PERIOD
)

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}


# Check that an environment variable name is set
check_env_var() {
    local varname="$1"
    if [[ -z "${!varname}" ]]; then
        fail "Missing environment variable: $varname";
    fi
}


# Check that the rclone configuration file is available and not empty
check_dependencies() {
    log "Checking dependencies";

    # Check required environment variables are available
    for var in "${required_vars[@]}"; do
        log "Checking required environment variable: '${var}'";
        check_env_var "$var";
    done

    # Check if rclone is installed
    command -v rclone >/dev/null 2>&1 || {
        fail "rclone is not installed. Aborting.";
    }

    # Check if mongodump is installed
    command -v mongodump >/dev/null 2>&1 || {
        fail "mongodump is not installed. Aborting.";
    }

    # Check if age is installed
    command -v age >/dev/null 2>&1 || {
        fail "age is not installed. Aborting.";
    }
}


# Dump the database
dump_database() {
    log "Dumping Database '${MONGO_DB}.${MONGO_COL}' to: ${DUMP_DIR}/${DUMP_FILE}";
    mongodump --uri="${MONGO_URI}" \
    --authenticationDatabase=admin \
    --db="${MONGO_DB}" \
    --collection="${MONGO_COL}" \
    --username="${MONGO_RO_USERNAME}" \
    --password="${MONGO_RO_PASSWORD}" \
    --out="${DUMP_DIR}/${DUMP_FILE}";

    log "Database '${MONGO_DB}.${MONGO_COL}' dumped to: ${DUMP_DIR}/${DUMP_FILE}";
}


# Compress the database dump file
compress_dump() {
    _dump_file_tgz="${DUMP_FILE}.tgz"

    log "Packing and compressing database dump files at: ${DUMP_DIR}/${DUMP_FILE}";
    tar --create --gzip --file="${DUMP_DIR}/${_dump_file_tgz}" --strip-components=2 "${DUMP_DIR}/${DUMP_FILE}";

    log "Database dump files packed/compressed at: ${DUMP_DIR}/${_dump_file_tgz}";
    log "Removing the unpacked/compressed database dump files at: ${DUMP_DIR}/${DUMP_FILE}";
    rm -rf "${DUMP_DIR}/${DUMP_FILE}";

    DUMP_FILE="${_dump_file_tgz}";
}


# Encrypt the database dump file
encrypt_dump() {
    _dump_file_encrypted="${DUMP_FILE}.enc";

    log "Encrypting the database dump file: ${DUMP_DIR}/${DUMP_FILE}";
    age --recipient="${ENCRYPTION_PUBLIC_KEY}" \
    --output="${DUMP_DIR}/${_dump_file_encrypted}" \
    "${DUMP_DIR}/${DUMP_FILE}";

    log "Encrypted database dump file at: ${DUMP_DIR}/${_dump_file_encrypted}";
    log "Removing the unprotected database dump file: ${DUMP_DIR}/${DUMP_FILE}";
    rm "${DUMP_DIR}/${DUMP_FILE}"

    DUMP_FILE="${_dump_file_encrypted}";
}


# Upload the database dump file to remote storage
upload_dump() {
    log "Uploading the database dump file '${DUMP_FILE}' to: ${OSS}:${OSS_BUCKET}${OSS_PATH}";
    rclone --config "${RCLONE_CONF}" copy "${DUMP_DIR}/${DUMP_FILE}" "${OSS}:${OSS_BUCKET}${OSS_PATH}";

    log "Database dump file uploaded: ${OSS}:${OSS_BUCKET}${OSS_PATH}/${DUMP_FILE}";
}


# Remove previous database dump files that are beyond a retention period
remove_previous_dumps() {
    log "Removing prior dump files at '${OSS}:${OSS_BUCKET}${OSS_PATH}' beyond the retention period of: '${RETENTION_PERIOD}'";

    # Convert the retention setting to seconds
    _retention_num=$(echo "$RETENTION_PERIOD" | sed 's|[dhm]||');
    case "$RETENTION_PERIOD" in
        *d)
            # Convert days to seconds
            _max_retention_sec=$((_retention_num * 86400))
        ;;
        *h)
            # Convert hours to seconds
            _max_retention_sec=$((_retention_num * 3600))
        ;;
        *m)
            # Convert minutes to seconds
            _max_retention_sec=$((_retention_num * 60))
        ;;
        *)
            fail "Unable to handle retention value: '$RETENTION_PERIOD'. Aborting."
        ;;
    esac
    log "Using a maximum retention seconds of: ${_max_retention_sec} (${RETENTION_PERIOD})";

    log "Fetch a list of database dump files at: ${OSS}:${OSS_BUCKET}${OSS_PATH}";
    readarray -t _prior_dumps < <(rclone --config "${RCLONE_CONF}" ls "${OSS}:${OSS_BUCKET}${OSS_PATH}" | awk '{print $NF}');
    log "${#_prior_dumps[@]} database dump files at: ${OSS}:${OSS_BUCKET}${OSS_PATH}";

    _now=$(date '+%s');
    log "Comparing database dump file timestamps against: ${_now} ($(date -d "@${_now}"))";
    for _dump in "${_prior_dumps[@]}"; do
        _timestamp=$(echo "${_dump}" | sed -E 's|^.*-([0-9]+)\..*$|\1|');
        _dump_age=$((_now - _timestamp));
        if [[ "${_dump_age}" -gt "${_max_retention_sec}" ]]; then
            log "Dump file '${_dump}' has aged ${_dump_age} seconds ($(date -d "@${_timestamp}"))";
            log "Dump file '${_dump}' is beyond the ${_max_retention_sec} seconds (${RETENTION_PERIOD}) retention period";
            log "Removing dump file at: ${OSS}:${OSS_BUCKET}${OSS_PATH}/${_dump}";
            rclone --config "${RCLONE_CONF}" delete "${OSS}:${OSS_BUCKET}${OSS_PATH}/${_dump}";
        fi
    done

    exit 0;
}


# main
RCLONE_CONF="/etc/rclone/rclone.conf";
DUMP_DIR="$(mktemp -d)";
trap 'rm -rf "${DUMP_DIR}"' EXIT;
DUMP_FILE="dump-$(date '+%s')";
check_dependencies;
dump_database;
compress_dump;
encrypt_dump;
upload_dump;
remove_previous_dumps;

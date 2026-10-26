#!/usr/bin/env bash
# =============================================================================
#  backup.sh — Lab 06: Automated Backup System (Ubuntu 24.04 / WSL2)
# =============================================================================
#  Backs up /etc and /var/log (or custom sources) into timestamped .tar.gz
#  archives, with:
#    - free disk space check before every run
#    - integrity verification (tar -tzf + SHA-256)
#    - retention policy (7 days by default)
#    - detailed logging to /var/log/backup.log
#    - lock against concurrent executions (flock)
#    - daily cron job installation (--install-cron)
#
#  Usage:
#    sudo ./backup.sh                     # immediate backup
#    sudo ./backup.sh --dry-run           # simulation
#    sudo ./backup.sh --list              # list archives
#    sudo ./backup.sh --verify            # verify checksums
#    sudo ./backup.sh --install-cron      # daily job at 02:15
#    sudo ./backup.sh --uninstall-cron    # remove the cron job
#
#  Author : Marwane — Lab 06
#  License: MIT
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"

# -----------------------------------------------------------------------------
# Configuration — overridden by the environment, then by CLI options
# -----------------------------------------------------------------------------
BACKUP_DIR="${BACKUP_DIR:-/var/backups/lab06}"
LOG_FILE="${BACKUP_LOG_FILE:-/var/log/backup.log}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
MIN_FREE_MB="${MIN_FREE_MB:-200}"
CRON_TIME="${CRON_TIME:-02:15}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-backup}"
LOG_MAX_BYTES=$((5 * 1024 * 1024))

readonly CRON_FILE="/etc/cron.d/lab06-backup"
readonly INSTALLED_SCRIPT="/usr/local/sbin/backup.sh"

SOURCES=()
if [[ -n "${BACKUP_SOURCES:-}" ]]; then
  IFS=', ' read -r -a SOURCES <<<"${BACKUP_SOURCES}"
else
  SOURCES=(/etc /var/log)
fi
EXCLUDES=()

DRY_RUN=0
QUIET=0
MODE="backup"
PARTIAL=""
SECONDS=0

# -----------------------------------------------------------------------------
# Colors / output
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION — automated backup (Lab 06)

Usage: sudo ./$SCRIPT_NAME [options]

Modes:
      --install-cron      Install the daily cron job (default 02:15)
      --uninstall-cron    Remove the cron job
      --list              List archives and their sizes
      --verify            Verify the integrity (SHA-256) of all archives
  -n, --dry-run           Simulate: no archive, no file modified
  -q, --quiet             Log without console output (cron mode)

Parameters:
      --sources LIST      Comma-separated directories
                          (default: /etc,/var/log)
      --dest DIR          Archive directory (default: $BACKUP_DIR)
      --retention DAYS    Retention in days (default: $RETENTION_DAYS)
      --min-free MB       Minimum free space required (default: ${MIN_FREE_MB} MB)
      --exclude PATTERN   tar pattern to exclude (repeatable)
      --cron-time HH:MM   Daily job time (default: $CRON_TIME)
  -h, --help              Show this help
  -V, --version           Show the version

Environment variables:
  BACKUP_DIR, BACKUP_LOG_FILE, BACKUP_SOURCES, RETENTION_DAYS,
  MIN_FREE_MB, CRON_TIME, ARCHIVE_PREFIX

Examples:
  sudo ./$SCRIPT_NAME --dry-run
  sudo ./$SCRIPT_NAME --sources /etc,/home --retention 14
  sudo ./$SCRIPT_NAME --install-cron --cron-time 03:30
  sudo ./$SCRIPT_NAME --list
EOF
}

usage_error() {
  printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  printf 'Try: %s --help\n' "$SCRIPT_NAME" >&2
  exit 2
}

log() {
  local level="$1"; shift
  local msg="$*"
  local ts color=""

  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$msg" >>"$LOG_FILE" 2>/dev/null || true

  if (( QUIET )); then
    return 0
  fi

  case "$level" in
    OK)    color="$C_GREEN"  ;;
    WARN)  color="$C_YELLOW" ;;
    ERROR) color="$C_RED"    ;;
    INFO)  color="$C_BLUE"   ;;
  esac
  if [[ -n "$color" ]]; then
    printf '%s[%s]%s %s\n' "$color" "$level" "$C_RESET" "$msg"
  else
    printf '%s[%s]%s %s\n' "$C_DIM" "$level" "$C_RESET" "$msg"
  fi
}

die() { log ERROR "$*"; exit 1; }

on_error() {
  local code=$1 line=$2
  log ERROR "unexpected failure (line $line, code $code)"
}

cleanup() {
  if [[ -n "${PARTIAL:-}" && -f "${PARTIAL}" ]]; then
    rm -f -- "$PARTIAL" "${PARTIAL}.err" 2>/dev/null || true
  fi
}

trap 'on_error $? $LINENO' ERR
trap cleanup EXIT
trap 'log ERROR "interrupted by a signal"; cleanup; exit 130' INT TERM

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
run() {
  if (( DRY_RUN )); then
    log INFO "[dry] $*"
    return 0
  fi
  "$@"
}

have_systemd() { [[ -d /run/systemd/system ]]; }

require_root() {
  if (( EUID != 0 )); then
    printf '%s[ERROR]%s this script must run as root: sudo %s\n' \
      "$C_RED" "$C_RESET" "$SCRIPT_NAME" >&2
    exit 1
  fi
}

join_by_space() {
  local IFS=' '
  printf '%s' "$*"
}

human_mb() { printf '%s' "$(( ${1:-0} / 1024 ))"; }

validate_config() {
  [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "invalid retention: $RETENTION_DAYS"
  (( RETENTION_DAYS >= 1 )) || die "retention must be at least 1 day"

  [[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || die "invalid free-space threshold: $MIN_FREE_MB"

  [[ "$ARCHIVE_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid archive prefix: $ARCHIVE_PREFIX"

  [[ "$CRON_TIME" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || die "invalid cron time (HH:MM expected): $CRON_TIME"

  [[ "$BACKUP_DIR" == /* ]] || die "the destination directory must be an absolute path"

  (( ${#SOURCES[@]} > 0 )) || die "no source defined"

  local src
  for src in "${SOURCES[@]}"; do
    [[ "$src" == /* ]] || die "source is not absolute: $src"
    [[ "$src" != "/" ]] || die "source '/' is refused (whole-system archive)"
    [[ "$BACKUP_DIR/" != "$src/"* ]] || die "the backup directory must not be inside a source ($src)"
  done
}

init_logging() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || die "cannot create $dir"
  fi
  if [[ ! -e "$LOG_FILE" ]]; then
    touch "$LOG_FILE" || die "cannot create $LOG_FILE"
  fi
  chmod 640 "$LOG_FILE" 2>/dev/null || true

  # Simple rotation: one generation, beyond 5 MB
  if (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    log INFO "log rotation: $LOG_FILE → $LOG_FILE.1"
  fi
}

acquire_lock() {
  local lock_file="/run/lock/lab06-backup.lock"
  if [[ ! -d /run/lock ]]; then
    mkdir -p /run/lock 2>/dev/null || lock_file="/tmp/lab06-backup.lock"
  fi
  exec 9>"$lock_file"
  if ! flock -n 9; then
    die "another backup is already running (lock: $lock_file)"
  fi
  log INFO "lock acquired: $lock_file"
}

# -----------------------------------------------------------------------------
# Disk space check
# -----------------------------------------------------------------------------
check_disk_space() {
  local -a effective=("$@")
  local estimate_kb=0 kb src free_kb target required_kb

  for src in "${effective[@]}"; do
    kb="$(du -sk -- "$src" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    estimate_kb=$((estimate_kb + kb))
  done

  # 50 MB margin for metadata + MIN_FREE_MB floor
  required_kb=$((estimate_kb + 50 * 1024))
  if (( required_kb < MIN_FREE_MB * 1024 )); then
    required_kb=$((MIN_FREE_MB * 1024))
  fi

  target="$BACKUP_DIR"
  while [[ ! -d "$target" ]]; do
    target="$(dirname "$target")"
  done

  free_kb="$(df -Pk -- "$target" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "$free_kb" ]] || { log ERROR "cannot read free space for $target"; return 1; }

  log INFO "disk space: $(human_mb "$free_kb") MB free, $(human_mb "$required_kb") MB required (sources ≈ $(human_mb "$estimate_kb") MB)"

  if (( free_kb < required_kb )); then
    log ERROR "insufficient space: $(human_mb "$free_kb") MB free < $(human_mb "$required_kb") MB required"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------
run_backup() {
  log INFO "=== backup start (retention ${RETENTION_DAYS} day(s)) ==="
  acquire_lock

  local -a effective=()
  local src
  for src in "${SOURCES[@]}"; do
    if [[ -e "$src" ]]; then
      effective+=("$src")
    else
      log WARN "missing source, skipped: $src"
    fi
  done
  (( ${#effective[@]} > 0 )) || die "no existing source to back up"

  if ! check_disk_space "${effective[@]}"; then
    die "backup cancelled: insufficient disk space"
  fi

  local timestamp name archive tmp
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  name="${ARCHIVE_PREFIX}-${timestamp}.tar.gz"
  archive="$BACKUP_DIR/$name"

  # Two runs within the same second: incremental suffix
  local suffix=1
  while [[ -e "$archive" ]]; do
    name="${ARCHIVE_PREFIX}-${timestamp}-${suffix}.tar.gz"
    archive="$BACKUP_DIR/$name"
    suffix=$((suffix + 1))
  done

  tmp="$archive.partial.$$"

  if (( DRY_RUN )); then
    log INFO "[dry] would create $archive"
    log INFO "[dry] sources: $(join_by_space "${effective[@]}")"
    log INFO "[dry] would prune archives older than ${RETENTION_DAYS} day(s)"
    log INFO "simulation complete — no changes made"
    return 0
  fi

  run mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"

  local -a tar_args=(-czpf "$tmp" --numeric-owner)
  local ex
  for ex in "${EXCLUDES[@]}"; do
    tar_args+=("--exclude=$ex")
  done
  for src in "${effective[@]}"; do
    tar_args+=(-C / "${src#/}")
  done

  log INFO "archiving $(join_by_space "${effective[@]}") → $name"
  PARTIAL="$tmp"

  local rc=0
  local tar_err="${tmp}.err"
  set +e
  tar "${tar_args[@]}" 2>"$tar_err"
  rc=$?
  set -e

  if (( rc > 1 )); then
    log ERROR "tar failed (code $rc)"
    sed 's/^/    /' "$tar_err" >>"$LOG_FILE" 2>/dev/null || true
    tail -n 3 "$tar_err" >&2 || true
    rm -f "$tmp" "$tar_err"
    PARTIAL=""
    return 1
  elif (( rc == 1 )); then
    log WARN "tar reported files changed while reading (code 1) — archive kept"
  fi
  rm -f "$tar_err"

  # Archive integrity before publication
  if ! tar -tzf "$tmp" >/dev/null 2>&1; then
    log ERROR "corrupted archive: tar -tzf verification failed"
    rm -f "$tmp"
    PARTIAL=""
    return 1
  fi
  log OK "archive integrity verified (tar -tzf)"

  chmod 600 "$tmp"
  mv -f "$tmp" "$archive"
  PARTIAL=""

  if ( cd "$BACKUP_DIR" && sha256sum "$name" >"$name.sha256" ); then
    chmod 600 "$archive.sha256"
    log OK "SHA-256 checksum: ${name}.sha256"
  else
    log WARN "could not generate the SHA-256 checksum"
  fi

  log OK "archive created: $archive ($(du -h -- "$archive" | cut -f1))"

  prune_backups

  log OK "backup completed in ${SECONDS}s"
}

# -----------------------------------------------------------------------------
# Retention
# -----------------------------------------------------------------------------
prune_backups() {
  local deleted=0 f partial

  while IFS= read -r -d '' f; do
    rm -f -- "$f" "${f}.sha256"
    log INFO "retention: removing $(basename "$f") (> ${RETENTION_DAYS} day(s))"
    deleted=$((deleted + 1))
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
             -name "${ARCHIVE_PREFIX}-*.tar.gz" \
             -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

  # Leftovers from interrupted runs
  while IFS= read -r -d '' partial; do
    rm -f -- "$partial"
    log WARN "cleaning up a partial file: $(basename "$partial")"
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
             -name '*.partial.*' -mtime +0 -print0 2>/dev/null)

  log INFO "retention: $deleted archive(s) removed"
}

# -----------------------------------------------------------------------------
# Read-only modes
# -----------------------------------------------------------------------------
list_backups() {
  local f count=0
  if [[ ! -d "$BACKUP_DIR" ]]; then
    log WARN "backup directory does not exist: $BACKUP_DIR"
    return 0
  fi

  printf '%-20s %10s  %s\n' "DATE" "SIZE" "ARCHIVE"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    printf '%-20s %10s  %s\n' \
      "$(date -r "$f" '+%F %R')" \
      "$(du -h -- "$f" | cut -f1)" \
      "$(basename "$f")"
    count=$((count + 1))
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
             -name "${ARCHIVE_PREFIX}-*.tar.gz" -print 2>/dev/null | sort)

  printf '\n%s archive(s) — retention: %s day(s)\n' "$count" "$RETENTION_DAYS"
}

verify_backups() {
  local total=0 failed=0 f name

  if [[ ! -d "$BACKUP_DIR" ]]; then
    die "backup directory does not exist: $BACKUP_DIR"
  fi

  log INFO "verifying archives in $BACKUP_DIR"

  while IFS= read -r f; do
    name="$(basename "$f")"
    total=$((total + 1))
    if ( cd "$BACKUP_DIR" && sha256sum -c "$name" >/dev/null 2>&1 ); then
      log OK "SHA-256 valid: ${name%.sha256}"
    else
      log ERROR "SHA-256 invalid: ${name%.sha256}"
      failed=$((failed + 1))
    fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${ARCHIVE_PREFIX}-*.tar.gz.sha256" -print 2>/dev/null | sort)

  # Archives without a checksum
  while IFS= read -r f; do
    if [[ ! -f "${f}.sha256" ]]; then
      log WARN "archive without checksum: $(basename "$f")"
    fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${ARCHIVE_PREFIX}-*.tar.gz" -print 2>/dev/null)

  log INFO "verification complete: $total archive(s), $failed failure(s)"
  (( failed == 0 )) || return 1
}

# -----------------------------------------------------------------------------
# Cron job
# -----------------------------------------------------------------------------
write_cron_file() {
  local content="$1"
  local tmp
  tmp="$(mktemp)"

  printf '%s\n' "$content" >"$tmp"

  if (( DRY_RUN )); then
    log INFO "[dry] would write $CRON_FILE (0644 root:root):"
    sed 's/^/    | /' "$tmp"
  else
    install -o root -g root -m 0644 "$tmp" "$CRON_FILE"
    log OK "cron file installed: $CRON_FILE"
  fi
  rm -f "$tmp"
}

install_cron() {
  local hour minute sources_str content target
  hour="${CRON_TIME%%:*}"
  minute="${CRON_TIME#*:}"
  hour=$((10#$hour))
  minute=$((10#$minute))
  sources_str="$(join_by_space "${SOURCES[@]}")"
  target="$INSTALLED_SCRIPT"

  log INFO "installing the daily cron job at ${CRON_TIME}"
  log INFO "installed script: $target"

  run install -d -m 0755 /usr/local/sbin
  if [[ "$SCRIPT_PATH" != "$target" ]]; then
    run install -o root -g root -m 0750 "$SCRIPT_PATH" "$target"
  else
    log INFO "the script is already at the target location"
  fi

  log INFO "preparing the backup directory and log file"
  run mkdir -p "$BACKUP_DIR"
  run chmod 700 "$BACKUP_DIR"
  run mkdir -p "$(dirname "$LOG_FILE")"
  if (( ! DRY_RUN )); then
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
  fi

  content="# Lab 06 — Automated Backup System (generated by $SCRIPT_NAME v$SCRIPT_VERSION)
# Daily backup: $CRON_TIME
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=\"\"

BACKUP_DIR=\"$BACKUP_DIR\"
BACKUP_LOG_FILE=\"$LOG_FILE\"
RETENTION_DAYS=\"$RETENTION_DAYS\"
MIN_FREE_MB=\"$MIN_FREE_MB\"
BACKUP_SOURCES=\"$sources_str\"

$minute $hour * * * root $target --quiet"

  write_cron_file "$content"

  if (( DRY_RUN )); then
    log INFO "simulation complete — cron and service unchanged"
    return 0
  fi

  if ! command -v cron >/dev/null 2>&1; then
    log WARN "cron daemon missing: sudo apt install cron"
  elif have_systemd; then
    if systemctl enable --now cron >/dev/null 2>&1; then
      log OK "cron service enabled and started"
    else
      log WARN "cron could not be enabled: sudo systemctl enable --now cron"
    fi
  else
    if service cron start >/dev/null 2>&1; then
      log OK "cron service started (without systemd)"
    else
      log WARN "cron could not be started: sudo service cron start"
    fi
  fi

  log OK "cron job installed: $minute $hour * * * root $target --quiet"
  log INFO "log: $LOG_FILE — check with: sudo $target --list"
}

uninstall_cron() {
  if [[ -f "$CRON_FILE" ]]; then
    run rm -f "$CRON_FILE"
    log OK "cron job removed: $CRON_FILE"
  else
    log WARN "no cron job installed ($CRON_FILE)"
  fi
  log INFO "the installed script ($INSTALLED_SCRIPT) and archives are kept"
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)      usage; exit 0 ;;
      -V|--version)   printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      -n|--dry-run)   DRY_RUN=1; shift ;;
      -q|--quiet)     QUIET=1; shift ;;
      --install-cron) MODE="install-cron"; shift ;;
      --uninstall-cron) MODE="uninstall-cron"; shift ;;
      --list)         MODE="list"; shift ;;
      --verify)       MODE="verify"; shift ;;
      --sources)
        [[ $# -ge 2 ]] || usage_error "--sources requires a list"
        IFS=', ' read -r -a SOURCES <<<"$2"; shift 2 ;;
      --sources=*)
        IFS=', ' read -r -a SOURCES <<<"${1#*=}"; shift ;;
      --dest|--backup-dir)
        [[ $# -ge 2 ]] || usage_error "$1 requires a path"
        BACKUP_DIR="$2"; shift 2 ;;
      --dest=*|--backup-dir=*)
        BACKUP_DIR="${1#*=}"; shift ;;
      --retention)
        [[ $# -ge 2 ]] || usage_error "--retention requires a number of days"
        RETENTION_DAYS="$2"; shift 2 ;;
      --retention=*)
        RETENTION_DAYS="${1#*=}"; shift ;;
      --min-free)
        [[ $# -ge 2 ]] || usage_error "--min-free requires a value in MB"
        MIN_FREE_MB="$2"; shift 2 ;;
      --min-free=*)
        MIN_FREE_MB="${1#*=}"; shift ;;
      --exclude)
        [[ $# -ge 2 ]] || usage_error "--exclude requires a pattern"
        EXCLUDES+=("$2"); shift 2 ;;
      --exclude=*)
        EXCLUDES+=("${1#*=}"); shift ;;
      --cron-time)
        [[ $# -ge 2 ]] || usage_error "--cron-time requires HH:MM"
        CRON_TIME="$2"; shift 2 ;;
      --cron-time=*)
        CRON_TIME="${1#*=}"; shift ;;
      *)
        usage_error "unknown option: $1" ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root
  init_logging
  validate_config

  log INFO "=== $SCRIPT_NAME v$SCRIPT_VERSION — mode: $MODE ==="
  (( DRY_RUN )) && log INFO "simulation mode (--dry-run): no real changes"

  case "$MODE" in
    install-cron)
      install_cron
      ;;
    uninstall-cron)
      uninstall_cron
      ;;
    list)
      list_backups
      ;;
    verify)
      verify_backups
      ;;
    backup)
      run_backup
      ;;
    *)
      die "unknown mode: $MODE"
      ;;
  esac
}

main "$@"

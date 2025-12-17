#!/usr/bin/env bash
#
# backup_restore.sh - Cross-distribution backup and restore utility
#
# Supports: Fedora, Ubuntu/Debian, openSUSE (including Leap 16+)
# Features: Incremental backups, smart retention, checksum verification,
#           flatpak support, systemd timer integration
#
# Usage: backup_restore.sh [--dry-run] [--selective] {backup|restore|menu|init|help}
#
# For initial setup, run: backup_restore.sh init
#
set -eo pipefail

SCRIPT_VERSION="1.0.0"

# === Configuration File Support ===
# Config locations (in order of precedence):
#   1. Environment variable CONFIG_FILE
#   2. ~/.config/backup-restore/config
#   3. /etc/backup-restore/config
#   4. Built-in defaults

load_config() {
  local config_locations=(
    "${CONFIG_FILE:-}"
    "${XDG_CONFIG_HOME:-$HOME/.config}/backup-restore/config"
    "/etc/backup-restore/config"
  )

  for cfg in "${config_locations[@]}"; do
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
      # shellcheck disable=SC1090
      . "$cfg"
      CONFIG_LOADED="$cfg"
      return 0
    fi
  done
  CONFIG_LOADED=""
  return 0
}

# Load config file first (if exists)
load_config

# === Configuration with Defaults ===
# These can be overridden via config file or environment variables

# User configuration
USER_NAME="${USER_NAME:-$(whoami)}"
HOME_DIR="${HOME_DIR:-/home/$USER_NAME}"
DRY_RUN="${DRY_RUN:-false}"

# Backup destination
MOUNT_BASE="${MOUNT_BASE:-/mnt/backup}"

TODAY="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$MOUNT_BASE/backups/backup_${TODAY}"

# Smart retention configuration
MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-50}"  # Minimum free space to maintain (GB)
MIN_BACKUPS_TO_KEEP="${MIN_BACKUPS_TO_KEEP:-3}"  # Never go below this number of backups
MAX_BACKUPS="${MAX_BACKUPS:-30}"  # Maximum number of backups to keep regardless of space

# Filenames (kept stable across distros)
PKG_LIST="packages.txt"              # names only
FLATPAK_LIST="flatpaks.txt"
REPO_REPORT="repos_enabled.txt"
REPOS_ARCHIVE="repos_and_keys.tar.gz"
LOG_FILE="$MOUNT_BASE/backup.log"

# Paths for capturing service/timer/script
SERVICE_NAME="${SERVICE_NAME:-home-backup.service}"
TIMER_NAME="${TIMER_NAME:-home-backup.timer}"
SERVICE_SRC="/etc/systemd/system/${SERVICE_NAME}"
TIMER_SRC="/etc/systemd/system/${TIMER_NAME}"
SCRIPT_SRC="/usr/local/sbin/backup_restore.sh"
SYSTEMD_SAVE_DIR="$BACKUP_DIR/systemd"
BIN_SAVE_DIR="$BACKUP_DIR/bin"

# ===== FSTAB Configuration (Optional) =====
# Set BACKUP_FSTAB_ENABLED=true to enable backup drive fstab management
# Set NAS_ENABLED=true to enable NAS mount fstab management
BACKUP_FSTAB_ENABLED="${BACKUP_FSTAB_ENABLED:-true}"
BACKUP_MOUNT_POINT="${BACKUP_MOUNT_POINT:-/mnt/backup}"
BACKUP_FSTAB_OPTIONS="${BACKUP_FSTAB_OPTIONS:-ext4  nofail,x-systemd.automount,x-systemd.idle-timeout=60  0  2}"

NAS_ENABLED="${NAS_ENABLED:-false}"
NAS_SHARE="${NAS_SHARE:-//nas.local/share}"
NAS_MOUNT_POINT="${NAS_MOUNT_POINT:-/mnt/nas}"
NAS_CREDENTIALS_FILE="${NAS_CREDENTIALS_FILE:-/home/$USER_NAME/.config/backup-restore/nas.cred}"
NAS_FSTAB_OPTIONS="${NAS_FSTAB_OPTIONS:-cifs  credentials=\$NAS_CREDENTIALS_FILE,rw,_netdev,noauto,x-systemd.automount  0  0}"

# Exclusions (patterns are relative when used with tar -C "$HOME_DIR" .)
# Can be customized in config file
EXCLUDE=(
  "--exclude=.cache"
  "--exclude=.local/share/Trash"
  "--exclude=.local/share/Steam"
  "--exclude=Downloads"
  "--exclude=*.tmp"
  "--exclude=*.bak"
)

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY-RUN] $msg"
  else
    echo "$msg" | tee -a "$LOG_FILE"
  fi
}

run_cmd() {
  if [ "$DRY_RUN" = "true" ]; then
    log "Would run: $*"
    return 0
  else
    "$@"
  fi
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { log "Error: required command '$1' not found"; exit 1; }; }
ensure_dirs() { mkdir -p "$MOUNT_BASE"; }

require_mount() {
  if [ ! -d "$MOUNT_BASE" ]; then
    log "Error: $MOUNT_BASE not found. Is your backup location available?"
    exit 1
  fi
}

require_root_for_system_ops() {
  if [ "$EUID" -ne 0 ]; then
    log "This action modifies /etc or installs packages and requires root. Re-run with sudo."
    exit 1
  fi
}

latest_backup_dir() {
  find "$MOUNT_BASE/backups" -maxdepth 1 -type d -name "backup_*" -printf "%T@ %p\n" 2>/dev/null | sort -nr | cut -d' ' -f2- | head -n1
}

previous_backup_dir() {
  local candidates
  candidates=$(find "$MOUNT_BASE/backups" -maxdepth 1 -type d -name "backup_*" -printf "%T@ %p\n" 2>/dev/null | sort -nr | cut -d' ' -f2-)
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    [ "$d" = "$BACKUP_DIR" ] && continue
    if [ -d "$d/home" ]; then
      echo "$d"; return
    fi
  done <<< "$candidates"
}

is_cifs() {
  local tgt="$1" fstype
  if fstype="$(findmnt -no FSTYPE --target "$tgt" 2>/dev/null)"; then :; else
    fstype="$(stat -f -c %T "$tgt" 2>/dev/null || echo unknown)"
  fi
  case "$fstype" in cifs|smb3|smb2|smbfs|smb) return 0 ;; *) return 1 ;; esac
}

supports_hardlinks() {
  local test_src test_dst
  test_src="$(mktemp "$MOUNT_BASE/.hl_test_src.XXXXXX" 2>/dev/null)" || return 1
  test_dst="$MOUNT_BASE/.hl_test_dst.$(basename "$test_src")"
  local fstype opts
  fstype="$(findmnt -no FSTYPE --target "$MOUNT_BASE" 2>/dev/null || true)"
  opts="$(findmnt -no OPTIONS --target "$MOUNT_BASE" 2>/dev/null || true)"
  log "Hardlink probe: FS=$fstype OPTS=$opts PATH=$MOUNT_BASE"
  if ! ln "$test_src" "$test_dst" 2>/dev/null; then
    log "Hardlink probe: ln() failed in $MOUNT_BASE (FS may not support hard links)"
    rm -f "$test_src"; return 1
  fi
  rm -f "$test_src" "$test_dst"
  log "Hardlink probe: success"
  return 0
}

run_as_user() {
  local user="$USER_NAME"
  if [ "$EUID" -eq 0 ]; then
    if command -v sudo >/dev/null 2>&1; then sudo -u "$user" -- "$@"; else runuser -u "$user" -- "$@"; fi
  else
    "$@"
  fi
}

# --- Distro detection ---
DISTRO_ID="unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
fi
is_fedora() { [[ "$DISTRO_ID" =~ ^(fedora|rhel|centos|rocky|almalinux)$ ]]; }
is_ubuntu() { [[ "$DISTRO_ID" =~ ^(ubuntu|debian|linuxmint|pop)$ ]]; }
is_opensuse() { [[ "$DISTRO_ID" =~ ^(opensuse|opensuse-leap|opensuse-tumbleweed|sles|sled)$ ]]; }
is_leap16_or_newer() {
  is_opensuse || return 1
  local version="${VERSION_ID:-0}"
  # Compare major version (handles 16.0, 16.1, etc.)
  [[ "${version%%.*}" -ge 16 ]] 2>/dev/null
}

# === Package/repo helpers per distro ===
export_packages() {
  if is_fedora; then
    if command -v dnf5 >/dev/null 2>&1; then
      log "Exporting user-installed DNF5 packages (names only)..."
      if ! dnf5 repoquery --userinstalled --qf '%{name}\n' > "$BACKUP_DIR/$PKG_LIST"; then
        log "dnf5 repoquery failed; falling back to rpm -qa"
        rpm -qa --queryformat '%{NAME}\n' > "$BACKUP_DIR/$PKG_LIST"
      fi
    else
      log "dnf5 not found; using rpm -qa"
      rpm -qa --queryformat '%{NAME}\n' > "$BACKUP_DIR/$PKG_LIST"
    fi
  elif is_ubuntu; then
    log "Exporting manually-installed APT packages (names only)..."
    if command -v apt-mark >/dev/null 2>&1; then
      apt-mark showmanual | sed 's/:amd64$//' | sort -u > "$BACKUP_DIR/$PKG_LIST"
      [ -s "$BACKUP_DIR/$PKG_LIST" ] || dpkg-query -W -f='${binary:Package}\n' | sort -u > "$BACKUP_DIR/$PKG_LIST"
    else
      dpkg-query -W -f='${binary:Package}\n' | sort -u > "$BACKUP_DIR/$PKG_LIST"
    fi
  elif is_opensuse; then
    log "Exporting installed zypper packages (names only)..."
    if command -v zypper >/dev/null 2>&1; then
      # Get explicitly installed packages (not auto-installed as dependencies)
      # Leap 16+ uses different repo structure, but zypper search works the same
      zypper search --installed-only -t package 2>/dev/null | awk -F'|' '/^i/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | sort -u > "$BACKUP_DIR/$PKG_LIST"
      # Fallback to rpm if zypper output is empty
      [ -s "$BACKUP_DIR/$PKG_LIST" ] || rpm -qa --queryformat '%{NAME}\n' | sort -u > "$BACKUP_DIR/$PKG_LIST"
    else
      log "zypper not found; using rpm -qa"
      rpm -qa --queryformat '%{NAME}\n' | sort -u > "$BACKUP_DIR/$PKG_LIST"
    fi
  else
    log "Unknown distro; saving generic package list if possible..."
    {
      (command -v rpm >/dev/null 2>&1 && rpm -qa --queryformat '%{NAME}\n') \
        || (command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${binary:Package}\n') \
        || true
    } > "$BACKUP_DIR/$PKG_LIST"
  fi
  [ -s "$BACKUP_DIR/$PKG_LIST" ] || { log "Error: $PKG_LIST is empty"; exit 1; }
  log "Saved package list -> $PKG_LIST"
}

repo_report_and_archive() {
  if is_fedora; then
    if command -v dnf5 >/dev/null 2>&1; then
      log "Saving enabled repo report..."
      dnf5 repolist --enabled > "$BACKUP_DIR/$REPO_REPORT" || true
    fi
    log "Archiving repo definitions and RPM GPG keys..."
    { tar -czf "$BACKUP_DIR/$REPOS_ARCHIVE" -C / etc/yum.repos.d etc/pki/rpm-gpg 2>/dev/null \
      || tar -czf "$BACKUP_DIR/$REPOS_ARCHIVE" -C / etc/yum.repos.d 2>/dev/null; } || true
  elif is_ubuntu; then
    log "Saving enabled APT sources list..."
    { grep -hR ^deb /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
        | sed 's/#.*$//' | sed '/^\s*$/d'; } > "$BACKUP_DIR/$REPO_REPORT" || true
    log "Archiving APT sources and keyrings..."
    tar -czf "$BACKUP_DIR/$REPOS_ARCHIVE" \
      -C / \
      etc/apt/sources.list \
      etc/apt/sources.list.d \
      etc/apt/trusted.gpg.d \
      etc/apt/keyrings 2>/dev/null || true
  elif is_opensuse; then
    log "Saving enabled zypper repo list..."
    zypper repos -d 2>/dev/null > "$BACKUP_DIR/$REPO_REPORT" || true
    log "Archiving zypper repos and GPG keys..."
    # Leap 16+ uses openSUSE-repos for automatic repo management via RIS (Repository Index Service)
    # Include both traditional repos.d and the new zypp.conf settings
    local repo_paths=(etc/zypp/repos.d)
    [ -d /etc/zypp/services.d ] && repo_paths+=(etc/zypp/services.d)
    [ -f /etc/zypp/zypp.conf ] && repo_paths+=(etc/zypp/zypp.conf)
    [ -d /usr/share/zypp/keys ] && repo_paths+=(usr/share/zypp/keys)
    [ -d /usr/share/gpg-keys ] && repo_paths+=(usr/share/gpg-keys)
    tar -czf "$BACKUP_DIR/$REPOS_ARCHIVE" -C / "${repo_paths[@]}" 2>/dev/null \
      || tar -czf "$BACKUP_DIR/$REPOS_ARCHIVE" -C / etc/zypp/repos.d 2>/dev/null || true
  fi
  [ -s "$BACKUP_DIR/$REPOS_ARCHIVE" ] && log "Saved $REPOS_ARCHIVE" || log "Warning: Could not archive repo files/keys (try running backup with sudo)."
}

restore_repos_and_keys() {
  local SRC_DIR="$1"
  if [ -f "$SRC_DIR/$REPOS_ARCHIVE" ] && [ -s "$SRC_DIR/$REPOS_ARCHIVE" ]; then
    log "Restoring repository definitions and keys to / ..."
    run_cmd tar -xzf "$SRC_DIR/$REPOS_ARCHIVE" -C /
    if is_fedora; then
      log "Importing GPG keys referenced by .repo files..."
      if [ "$DRY_RUN" != "true" ]; then
        awk -F= '/^\s*gpgkey\s*=/{print $2}' /etc/yum.repos.d/*.repo 2>/dev/null \
          | tr ',' '\n' | sed 's|^file:||' | while read -r key; do
              [ -n "$key" ] && [ -f "$key" ] && rpm --import "$key" || true
            done
        command -v dnf5 >/dev/null 2>&1 && dnf5 -y makecache || true
      else
        log "Would import GPG keys and refresh metadata cache"
      fi
    elif is_ubuntu; then
      [ "$DRY_RUN" != "true" ] && { apt-get update -y || apt-get update || true; } || log "Would run: apt-get update"
    elif is_opensuse; then
      log "Refreshing zypper repos..."
      if [ "$DRY_RUN" != "true" ]; then
        # Import GPG keys for repos (check both old and new key locations)
        shopt -s nullglob
        for key in /usr/share/gpg-keys/*.asc /usr/share/gpg-keys/*.gpg /usr/share/zypp/keys/*.asc /usr/share/zypp/keys/*.gpg; do
          [ -f "$key" ] && rpm --import "$key" 2>/dev/null || true
        done
        shopt -u nullglob
        # Leap 16+ supports parallel downloads, refresh benefits from this automatically
        zypper --gpg-auto-import-keys refresh || true
      else
        log "Would import GPG keys and refresh zypper repos"
      fi
    fi
  else
    log "Warning: $REPOS_ARCHIVE not found; skipping repo restore."
  fi
}

install_packages_from_list() {
  local SRC_DIR="$1"
  if [ ! -f "$SRC_DIR/$PKG_LIST" ]; then
    log "Warning: $PKG_LIST not found; skipping package restore."; return 0
  fi

  local pkg_count
  pkg_count=$(grep -cE '^[^#[:space:]]' "$SRC_DIR/$PKG_LIST" 2>/dev/null || echo 0)
  log "Found $pkg_count packages to restore"

  if is_fedora; then
    if [ "$DRY_RUN" != "true" ]; then
      command -v dnf5 >/dev/null 2>&1 || dnf -y install dnf5 || true
      log "Restoring RPM packages from $PKG_LIST ..."
      grep -E '^[^#[:space:]]' "$SRC_DIR/$PKG_LIST" | sort -u | xargs -r dnf5 install -y --skip-unavailable \
        || log "Some packages failed to install; continuing."
    else
      log "Would install dnf5 if needed"
      log "Would restore $pkg_count RPM packages"
    fi
  elif is_ubuntu; then
    log "Restoring APT packages from $PKG_LIST ..."
    if [ "$DRY_RUN" != "true" ]; then
      xargs -r -a "$SRC_DIR/$PKG_LIST" apt-get install -y --no-install-recommends \
        || log "Some packages failed to install; continuing."
    else
      log "Would restore $pkg_count APT packages"
    fi
  elif is_opensuse; then
    log "Restoring zypper packages from $PKG_LIST ..."
    if [ "$DRY_RUN" != "true" ]; then
      # Install all packages in a single zypper call to avoid multiple snapshots
      # Use --download-in-advance to leverage Leap 16's parallel download support
      local zypper_opts="--non-interactive install --no-recommends"
      if is_leap16_or_newer; then
        zypper_opts="--non-interactive install --no-recommends --download-in-advance"
        log "Using Leap 16+ optimizations (parallel downloads enabled)"
      fi
      grep -E '^[^#[:space:]]' "$SRC_DIR/$PKG_LIST" | sort -u | xargs -r zypper $zypper_opts \
        || log "Some packages failed to install; continuing."
      log "Package restoration completed (some packages may have been skipped if unavailable)."
    else
      log "Would restore $pkg_count zypper packages"
    fi
  fi
}

ensure_flatpak_installed() {
  if ! command -v flatpak >/dev/null 2>&1; then
    log "Installing flatpak..."
    if is_fedora; then
      if command -v dnf5 >/dev/null 2>&1; then dnf5 install -y flatpak || { log "Error: Failed to install flatpak"; exit 1; }
      else dnf install -y flatpak || { log "Error: Failed to install flatpak"; exit 1; }
      fi
    elif is_ubuntu; then
      apt-get update -y || true
      apt-get install -y flatpak || { log "Error: Failed to install flatpak"; exit 1; }
    elif is_opensuse; then
      zypper --non-interactive install flatpak || { log "Error: Failed to install flatpak"; exit 1; }
    else
      log "Unknown distro; cannot auto-install flatpak."
    fi
  fi
  log "Ensuring Flathub exists..."
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
}

export_flatpaks_to() {
  local outfile="$1"
  : > "$outfile"
  if command -v flatpak >/dev/null 2>&1; then
    run_as_user flatpak list --app --columns=application > "$outfile" 2>/dev/null || true
  fi
  if [ ! -s "$outfile" ]; then
    local user_flatpak_dir="$HOME_DIR/.local/share/flatpak/app"
    if [ -d "$user_flatpak_dir" ]; then
      find "$user_flatpak_dir" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" | sort -u > "$outfile" || true
    fi
  fi
  [ -s "$outfile" ] && log "Saved flatpaks -> $(basename "$outfile")" || log "No Flatpaks detected for user '$USER_NAME' (created empty list)."
}

# ---------- NEW: capture service, timer, script, and fstab lines into README ----------
capture_systemd_and_script() {
  if [ "$DRY_RUN" = "true" ]; then
    log "Would capture systemd units and backup script"
    [ -f "$SERVICE_SRC" ] && log "  - Would copy $SERVICE_SRC"
    [ -f "$TIMER_SRC" ] && log "  - Would copy $TIMER_SRC"
    [ -f "$SCRIPT_SRC" ] && log "  - Would copy $SCRIPT_SRC"
    return 0
  fi

  mkdir -p "$SYSTEMD_SAVE_DIR" "$BIN_SAVE_DIR"

  if [ -f "$SERVICE_SRC" ]; then
    install -D -m 0644 "$SERVICE_SRC" "$SYSTEMD_SAVE_DIR/$SERVICE_NAME"
  else
    systemctl cat "$SERVICE_NAME" > "$SYSTEMD_SAVE_DIR/$SERVICE_NAME" 2>/dev/null || true
  fi

  if [ -f "$TIMER_SRC" ]; then
    install -D -m 0644 "$TIMER_SRC" "$SYSTEMD_SAVE_DIR/$TIMER_NAME"
  else
    systemctl cat "$TIMER_NAME" > "$SYSTEMD_SAVE_DIR/$TIMER_NAME" 2>/dev/null || true
  fi

  if [ -f "$SCRIPT_SRC" ]; then
    install -D -m 0750 "$SCRIPT_SRC" "$BIN_SAVE_DIR/backup_restore.sh"
  fi

  {
    echo "These files and config were captured automatically:"
    echo
    echo "systemd units:"
    echo "  - $SERVICE_NAME"
    echo "  - $TIMER_NAME"
    echo
    echo "script:"
    echo "  - bin/backup_restore.sh"
    echo
    echo "fstab suggestions (UUIDs detected dynamically at restore):"
    echo "  UUID=<auto-detect>  $BACKUP_FSTAB_TEMPLATE"
    echo "  $NAS_FSTAB_TEMPLATE (with uid=<auto>,gid=<auto>)"
  } > "$SYSTEMD_SAVE_DIR/README.txt"

  log "Captured systemd units and script into $SYSTEMD_SAVE_DIR and $BIN_SAVE_DIR"
}

# ---------- NEW: Smart retention policy ----------
get_free_space_gb() {
  local free_kb
  free_kb=$(df "$MOUNT_BASE" | awk 'NR==2 {print $4}')
  echo $((free_kb / 1024 / 1024))
}

get_backup_size_gb() {
  local backup_dir="$1"
  local size_kb
  size_kb=$(du -sk "$backup_dir" 2>/dev/null | awk '{print $1}')
  echo $((size_kb / 1024 / 1024))
}

estimate_new_backup_size_gb() {
  # Estimate based on home directory size plus overhead
  local home_size_kb
  home_size_kb=$(du -sk "$HOME_DIR" 2>/dev/null | awk '{print $1}')
  local estimate_gb=$((home_size_kb / 1024 / 1024 + 1))  # Add 1GB for metadata/packages
  echo "$estimate_gb"
}

smart_retention_cleanup() {
  log "Starting smart retention cleanup..."
  
  # Get list of existing backups sorted by age (oldest first)
  local backup_dirs
  backup_dirs=$(find "$MOUNT_BASE/backups" -maxdepth 1 -type d -name "backup_*" -printf "%T@ %p\n" 2>/dev/null | sort -n | cut -d' ' -f2-)
  
  local backup_count
  backup_count=$(echo "$backup_dirs" | grep -c "backup_" 2>/dev/null || echo 0)
  # Handle empty result
  [[ "$backup_count" =~ ^[0-9]+$ ]] || backup_count=0
  
  log "Found $backup_count existing backups"
  
  # Check if we've exceeded maximum backups
  if [ "$backup_count" -ge "$MAX_BACKUPS" ]; then
    log "Maximum backup limit ($MAX_BACKUPS) reached. Removing oldest backups..."
    local to_remove=$((backup_count - MAX_BACKUPS + 1))
    echo "$backup_dirs" | head -n "$to_remove" | while read -r dir; do
      [ -n "$dir" ] && [ -d "$dir" ] && {
        log "Removing backup (max limit): $dir"
        run_cmd rm -rf "$dir"
      }
    done
    # Refresh the list
    backup_dirs=$(find "$MOUNT_BASE/backups" -maxdepth 1 -type d -name "backup_*" -printf "%T@ %p\n" 2>/dev/null | sort -n | cut -d' ' -f2-)
    backup_count=$(echo "$backup_dirs" | grep -c "backup_" || echo 0)
  fi
  
  # Check available space
  local free_space_gb
  free_space_gb=$(get_free_space_gb)
  local estimated_backup_gb
  estimated_backup_gb=$(estimate_new_backup_size_gb)
  
  log "Current free space: ${free_space_gb}GB"
  log "Estimated new backup size: ${estimated_backup_gb}GB"
  log "Minimum free space required: ${MIN_FREE_SPACE_GB}GB"
  
  # Calculate space needed
  local space_needed_gb=$((MIN_FREE_SPACE_GB + estimated_backup_gb))
  
  # Remove old backups if needed to make space
  while [ "$free_space_gb" -lt "$space_needed_gb" ] && [ "$backup_count" -gt "$MIN_BACKUPS_TO_KEEP" ]; do
    # Get the oldest backup
    local oldest_backup
    oldest_backup=$(echo "$backup_dirs" | head -n1)
    
    if [ -z "$oldest_backup" ] || [ ! -d "$oldest_backup" ]; then
      break
    fi
    
    local backup_size_gb
    backup_size_gb=$(get_backup_size_gb "$oldest_backup")
    
    log "Insufficient space. Removing oldest backup to free ${backup_size_gb}GB: $oldest_backup"
    run_cmd rm -rf "$oldest_backup"
    
    # Update counters
    free_space_gb=$((free_space_gb + backup_size_gb))
    backup_count=$((backup_count - 1))
    
    # Refresh the list
    backup_dirs=$(find "$MOUNT_BASE/backups" -maxdepth 1 -type d -name "backup_*" -printf "%T@ %p\n" 2>/dev/null | sort -n | cut -d' ' -f2-)
  done
  
  if [ "$free_space_gb" -lt "$space_needed_gb" ]; then
    log "WARNING: Unable to free enough space. Free: ${free_space_gb}GB, Needed: ${space_needed_gb}GB"
    log "Consider adjusting MIN_FREE_SPACE_GB or manually removing old backups"
  else
    log "Retention cleanup complete. Free space: ${free_space_gb}GB, Backups remaining: $backup_count"
  fi
  
  # Display retention summary
  log "Retention policy summary:"
  log "  - Min backups to keep: $MIN_BACKUPS_TO_KEEP"
  log "  - Max backups allowed: $MAX_BACKUPS"
  log "  - Min free space target: ${MIN_FREE_SPACE_GB}GB"
  log "  - Current backup count: $backup_count"
  log "  - Current free space: ${free_space_gb}GB"
}

# ---------- NEW: prompt to add fstab lines on restore ----------
prompt_and_update_fstab() {
  require_root_for_system_ops

  # Check if any fstab management is enabled
  if [ "$BACKUP_FSTAB_ENABLED" != "true" ] && [ "$NAS_ENABLED" != "true" ]; then
    log "fstab management disabled in configuration, skipping."
    return 0
  fi

  # Dynamically detect backup drive UUID
  local backup_uuid="" backup_device=""

  if [ -d "$MOUNT_BASE" ]; then
    backup_device=$(df "$MOUNT_BASE" | awk 'NR==2 {print $1}')
    if [ -n "$backup_device" ]; then
      backup_uuid=$(blkid -s UUID -o value "$backup_device" 2>/dev/null || lsblk -no UUID "$backup_device" 2>/dev/null || true)
    fi
  fi

  # Get current user's UID and GID dynamically
  local user_uid user_gid
  user_uid=$(id -u "$USER_NAME" 2>/dev/null || echo "1000")
  user_gid=$(id -g "$USER_NAME" 2>/dev/null || echo "1000")

  # Build fstab lines with detected values
  local backup_fstab_line=""
  local nas_fstab_block=""

  if [ "$BACKUP_FSTAB_ENABLED" = "true" ]; then
    if [ -n "$backup_uuid" ]; then
      backup_fstab_line="UUID=${backup_uuid}  ${BACKUP_MOUNT_POINT}  ${BACKUP_FSTAB_OPTIONS}"
      log "Detected backup drive UUID: $backup_uuid"
    else
      log "Warning: Could not detect backup drive UUID. Using device path instead."
      backup_fstab_line="${backup_device}  ${BACKUP_MOUNT_POINT}  ${BACKUP_FSTAB_OPTIONS}"
    fi
  fi

  # NAS line with dynamic UID/GID (only if enabled)
  if [ "$NAS_ENABLED" = "true" ]; then
    local nas_opts="${NAS_FSTAB_OPTIONS//\$NAS_CREDENTIALS_FILE/$NAS_CREDENTIALS_FILE}"
    nas_fstab_block="#
# NAS mount (auto-configured by backup_restore.sh)
#
${NAS_SHARE}  ${NAS_MOUNT_POINT}  ${nas_opts/,rw,/,rw,uid=${user_uid},gid=${user_gid},}"
  fi

  echo
  echo "Proposed /etc/fstab additions:"
  if [ -n "$backup_fstab_line" ]; then
    echo "1) Backup drive: $backup_fstab_line"
  fi
  if [ -n "$nas_fstab_block" ]; then
    echo "2) NAS mount:"
    echo "$nas_fstab_block" | sed 's/^/   /'
  fi
  echo
  echo "Detected: UID=$user_uid, GID=$user_gid for user '$USER_NAME'"
  echo

  read -r -p "Add these to /etc/fstab now? [y/N]: " ans
  case "${ans:-}" in
    y|Y|yes|YES)
      # Backup fstab before modification
      local fstab_backup="/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
      cp /etc/fstab "$fstab_backup"
      log "Backed up /etc/fstab to $fstab_backup"

      # Create mount points
      [ "$BACKUP_FSTAB_ENABLED" = "true" ] && mkdir -p "$BACKUP_MOUNT_POINT"
      [ "$NAS_ENABLED" = "true" ] && mkdir -p "$NAS_MOUNT_POINT"

      # Ensure CIFS support if NAS is enabled
      if [ "$NAS_ENABLED" = "true" ]; then
        if is_fedora; then
          command -v mount.cifs >/dev/null 2>&1 || dnf5 install -y cifs-utils || dnf install -y cifs-utils || true
        elif is_ubuntu; then
          command -v mount.cifs >/dev/null 2>&1 || apt-get update -y || true
          command -v mount.cifs >/dev/null 2>&1 || apt-get install -y cifs-utils || true
        elif is_opensuse; then
          command -v mount.cifs >/dev/null 2>&1 || zypper --non-interactive install cifs-utils || true
        fi
      fi

      # Append backup line if not already present (idempotent)
      if [ "$BACKUP_FSTAB_ENABLED" = "true" ] && [ -n "$backup_fstab_line" ]; then
        if ! grep -q "$BACKUP_MOUNT_POINT" /etc/fstab; then
          echo "$backup_fstab_line" >> /etc/fstab
        else
          log "Backup mount already exists in /etc/fstab, skipping."
        fi
      fi

      # For the NAS block, insert if the share line isn't present
      if [ "$NAS_ENABLED" = "true" ] && [ -n "$nas_fstab_block" ]; then
        if ! grep -Fq "$NAS_SHARE" /etc/fstab; then
          printf "%s\n" "$nas_fstab_block" >> /etc/fstab
        else
          log "NAS mount already exists in /etc/fstab, skipping."
        fi
      fi

      # Verify credentials file permissions (only if NAS enabled)
      if [ "$NAS_ENABLED" = "true" ]; then
        if [ -f "$NAS_CREDENTIALS_FILE" ]; then
          local cred_perms
          cred_perms=$(stat -c %a "$NAS_CREDENTIALS_FILE")
          if [ "$cred_perms" != "600" ] && [ "$cred_perms" != "400" ]; then
            log "WARNING: $NAS_CREDENTIALS_FILE has insecure permissions ($cred_perms). Setting to 600..."
            chmod 600 "$NAS_CREDENTIALS_FILE"
            chown "$USER_NAME:$USER_NAME" "$NAS_CREDENTIALS_FILE"
          fi
        else
          log "Note: NAS credentials file not found at $NAS_CREDENTIALS_FILE"
          log "Create it with secure permissions before mounting:"
          log "  mkdir -p $(dirname "$NAS_CREDENTIALS_FILE")"
          log "  touch $NAS_CREDENTIALS_FILE && chmod 600 $NAS_CREDENTIALS_FILE"
          log "  Then add: username=YOUR_USER and password=YOUR_PASS (one per line)"
        fi
      fi

      systemctl daemon-reload

      # Try mounting now (automounts will also trigger on access)
      if [ "$BACKUP_FSTAB_ENABLED" = "true" ]; then
        mountpoint -q "$BACKUP_MOUNT_POINT" || mount "$BACKUP_MOUNT_POINT" || true
      fi
      if [ "$NAS_ENABLED" = "true" ]; then
        mountpoint -q "$NAS_MOUNT_POINT" || mount "$NAS_MOUNT_POINT" || true
      fi

      log "/etc/fstab updated and mounts attempted."
      ;;
    *) log "Skipped /etc/fstab modification."; ;;
  esac
}

# ---------- CHECKSUM VERIFICATION ----------
generate_checksums() {
  local backup_dir="$1"
  log "Generating checksums for backup verification..."
  
  if [ "$DRY_RUN" = "true" ]; then
    log "Would generate SHA256 checksums in $backup_dir/checksums.sha256"
    return 0
  fi
  
  cd "$backup_dir" || return 1
  
  # Generate checksums for all files
  find . -type f ! -name "checksums.sha256" -exec sha256sum {} \; > checksums.sha256
  
  log "Generated checksums for $(wc -l < checksums.sha256) files"
  cd - > /dev/null || true
}

verify_checksums() {
  local backup_dir="$1"
  
  if [ ! -f "$backup_dir/checksums.sha256" ]; then
    log "Warning: No checksums file found in $backup_dir"
    return 1
  fi
  
  log "Verifying backup integrity with checksums..."
  
  if [ "$DRY_RUN" = "true" ]; then
    log "Would verify checksums from $backup_dir/checksums.sha256"
    return 0
  fi
  
  cd "$backup_dir" || return 1
  
  if sha256sum -c checksums.sha256 --quiet 2>/dev/null; then
    log "Checksum verification PASSED - backup integrity confirmed"
    cd - > /dev/null || true
    return 0
  else
    log "ERROR: Checksum verification FAILED - backup may be corrupted"
    sha256sum -c checksums.sha256 2>&1 | grep FAILED | head -10
    cd - > /dev/null || true
    return 1
  fi
}

# ---------- SELECTIVE RESTORE ----------
select_restore_components() {
  echo
  echo "Select components to restore:"
  echo "1) Packages only"
  echo "2) Home directory only"
  echo "3) Flatpaks only"
  echo "4) System config (repos, systemd units, fstab)"
  echo "5) Everything (full restore)"
  echo "6) Custom selection"
  echo
  read -r -p "Enter your choice [1-6]: " choice
  
  RESTORE_PACKAGES="false"
  RESTORE_HOME="false"
  RESTORE_FLATPAKS="false"
  RESTORE_SYSTEM="false"
  
  case "$choice" in
    1) RESTORE_PACKAGES="true" ;;
    2) RESTORE_HOME="true" ;;
    3) RESTORE_FLATPAKS="true" ;;
    4) RESTORE_SYSTEM="true" ;;
    5) 
      RESTORE_PACKAGES="true"
      RESTORE_HOME="true"
      RESTORE_FLATPAKS="true"
      RESTORE_SYSTEM="true"
      ;;
    6)
      read -r -p "Restore packages? [y/N]: " ans
      [ "${ans,,}" = "y" ] && RESTORE_PACKAGES="true"
      
      read -r -p "Restore home directory? [y/N]: " ans
      [ "${ans,,}" = "y" ] && RESTORE_HOME="true"
      
      read -r -p "Restore flatpaks? [y/N]: " ans
      [ "${ans,,}" = "y" ] && RESTORE_FLATPAKS="true"
      
      read -r -p "Restore system config? [y/N]: " ans
      [ "${ans,,}" = "y" ] && RESTORE_SYSTEM="true"
      ;;
    *)
      log "Invalid choice. Exiting."
      exit 1
      ;;
  esac
  
  log "Selected for restore:"
  [ "$RESTORE_PACKAGES" = "true" ] && log "  - Packages"
  [ "$RESTORE_HOME" = "true" ] && log "  - Home directory"
  [ "$RESTORE_FLATPAKS" = "true" ] && log "  - Flatpaks"
  [ "$RESTORE_SYSTEM" = "true" ] && log "  - System configuration"
}

# ---------- BACKUP ----------
do_backup() {
  ensure_dirs
  require_mount
  require_cmd tar
  require_cmd find
  require_cmd rsync || true

  # Run smart retention cleanup BEFORE creating new backup
  smart_retention_cleanup

  # Always create backup dir structure (even in dry-run) so export functions can write temp data
  mkdir -p "$BACKUP_DIR/home"
  log "Detected distro: $DISTRO_ID (version: ${VERSION_ID:-unknown})"
  is_leap16_or_newer && log "Leap 16+ detected: using optimized settings (parallel downloads, SELinux support)"
  log "Starting backup to $BACKUP_DIR"

  export_packages
  repo_report_and_archive

  log "Exporting installed Flatpaks for user '$USER_NAME'..."
  export_flatpaks_to "$BACKUP_DIR/$FLATPAK_LIST"

  # Capture units, script, and fstab suggestions
  capture_systemd_and_script

  if is_cifs "$MOUNT_BASE"; then
    log "CIFS detected - using tar archive to preserve xattrs/ACLs/SELinux"
    # Conditionally add SELinux flag if system supports it
    local SELINUX_FLAG=""
    if [ -d /sys/fs/selinux ] && command -v getenforce >/dev/null 2>&1; then
      SELINUX_FLAG="--selinux"
      log "SELinux detected - preserving security contexts"
    fi
    run_cmd tar --xattrs --acls $SELINUX_FLAG -cpf "$BACKUP_DIR/home.tar" "${EXCLUDE[@]}" -C "$HOME_DIR" .
    log "Created $BACKUP_DIR/home.tar"
    run_cmd tar -tf "$BACKUP_DIR/home.tar" > "$BACKUP_DIR/home.manifest" || true
  else
    require_cmd rsync
    log "Backing up $HOME_DIR with rsync (preserving xattrs/ACLs)..."
    PREV="$(previous_backup_dir || true)"
    if [ -z "${PREV:-}" ]; then
      log "No previous snapshot with 'home/' found -> full copy"
    fi
    if [ -n "${PREV:-}" ] && supports_hardlinks; then
      log "Using incremental snapshot with --link-dest -> $PREV/home"
      run_cmd rsync -aAXv --delete --numeric-ids --link-dest="$PREV/home" \
            --info=stats2 --human-readable \
            "${EXCLUDE[@]}" "$HOME_DIR/" "$BACKUP_DIR/home/"
    else
      log "Proceeding without --link-dest (no suitable previous snapshot or no hardlink support)"
      run_cmd rsync -aAXv --delete --numeric-ids \
            --info=stats2 --human-readable \
            "${EXCLUDE[@]}" "$HOME_DIR/" "$BACKUP_DIR/home/"
    fi
  fi

  # Generate checksums for verification
  if [ "$DRY_RUN" != "true" ]; then
    generate_checksums "$BACKUP_DIR"
  fi
  
  # Clean up dry-run backup directory
  if [ "$DRY_RUN" = "true" ]; then
    log "Dry-run complete. Cleaning up temporary backup directory..."
    rm -rf "$BACKUP_DIR"
    log "Backup dry-run finished successfully. No changes were made."
  else
    log "Backup completed successfully."
    # Final retention summary
    local final_count
    final_count=$(find "$MOUNT_BASE/backups" -maxdepth 1 -type d -name "backup_*" | wc -l)
    local final_free_gb
    final_free_gb=$(get_free_space_gb)
    log "Final status: $final_count backups, ${final_free_gb}GB free space"
  fi
}

# ---------- RESTORE ----------
do_restore() {
  log "do_restore() called with SELECTIVE=$SELECTIVE"
  require_root_for_system_ops
  log "Root check passed"
  require_mount
  log "Mount check passed"

  local SRC_DIR
  SRC_DIR="$(latest_backup_dir)"
  [ -n "$SRC_DIR" ] || { log "Error: No backups found in $MOUNT_BASE/backups"; return 1; }
  log "Detected distro: $DISTRO_ID (version: ${VERSION_ID:-unknown})"
  is_leap16_or_newer && log "Leap 16+ detected: using optimized settings (parallel downloads, SELinux support)"
  log "Restoring from latest backup: $SRC_DIR"

  # Verify backup integrity first
  if [ "$DRY_RUN" != "true" ]; then
    verify_checksums "$SRC_DIR" || {
      read -r -p "Checksum verification failed. Continue anyway? [y/N]: " ans
      [ "${ans,,}" != "y" ] && { log "Restore cancelled by user."; return 1; }
    }
  fi
  
  # Handle selective restore
  if [ "$SELECTIVE" = "true" ]; then
    select_restore_components
    log "Proceeding with selective restore..."
  else
    # Default to full restore
    RESTORE_PACKAGES="true"
    RESTORE_HOME="true"
    RESTORE_FLATPAKS="true"
    RESTORE_SYSTEM="true"
    log "Proceeding with full restore..."
  fi

  if [ "$RESTORE_PACKAGES" = "true" ]; then
    log "Restoring packages..."
    echo
    echo "WARNING: Package restoration is distro-specific and may fail or cause issues"
    echo "if restoring to a different distribution or version than the backup source."
    echo
    read -r -p "Continue with package restore? [y/N]: " ans
    if [ "${ans,,}" = "y" ]; then
      restore_repos_and_keys "$SRC_DIR"
      install_packages_from_list "$SRC_DIR"
    else
      log "Package restore skipped by user."
    fi
  fi
  
  if [ "$RESTORE_FLATPAKS" = "true" ]; then
    log "Restoring flatpaks..."
    if [ -f "$SRC_DIR/$FLATPAK_LIST" ]; then
      local flatpak_count
      flatpak_count=$(grep -c . "$SRC_DIR/$FLATPAK_LIST" 2>/dev/null || echo 0)
      log "Restoring $flatpak_count flatpaks..."
      ensure_flatpak_installed
      while IFS= read -r app; do
        [ -n "$app" ] && run_cmd flatpak install -y flathub "$app" || true
      done < "$SRC_DIR/$FLATPAK_LIST"
    else
      log "Warning: $FLATPAK_LIST not found; skipping flatpak restore."
    fi
  fi

  log "Checking home directory restore (RESTORE_HOME=$RESTORE_HOME)..."
  if [ "$RESTORE_HOME" = "true" ]; then
    log "Starting home directory restore..."
    if [ -f "$SRC_DIR/home.tar" ]; then
      log "Restoring /home from tar archive (preserves xattrs/ACLs)..."
      log "Destination: $HOME_DIR/"

      # Conditionally add SELinux flag if system supports it
      local SELINUX_FLAG=""
      if [ -d /sys/fs/selinux ] && command -v getenforce >/dev/null 2>&1; then
        SELINUX_FLAG="--selinux"
        log "SELinux detected - will restore security contexts"
      else
        log "SELinux not detected - skipping SELinux contexts (safe for AppArmor systems)"
      fi

      # Safety check - warn if destination has existing files
      if [ -d "$HOME_DIR" ] && [ "$(ls -A "$HOME_DIR" 2>/dev/null)" ]; then
        log "WARNING: $HOME_DIR is not empty and will be merged with backup data"
        if [ "$DRY_RUN" != "true" ]; then
          read -r -p "Continue with home directory restore? [y/N]: " ans
          [ "${ans,,}" != "y" ] && { log "Home restore skipped by user."; } || {
            run_cmd tar --xattrs --acls $SELINUX_FLAG -xvpf "$SRC_DIR/home.tar" -C "$HOME_DIR"
          }
        else
          log "Would extract tar archive to $HOME_DIR"
        fi
      else
        run_cmd tar --xattrs --acls $SELINUX_FLAG -xvpf "$SRC_DIR/home.tar" -C "$HOME_DIR"
      fi

    elif [ -d "$SRC_DIR/home" ]; then
      log "Restoring $HOME_DIR with rsync..."
      log "Source: $SRC_DIR/home/"
      log "Destination: $HOME_DIR/"

      # Ensure destination user exists
      if ! id "$USER_NAME" &>/dev/null; then
        log "ERROR: User '$USER_NAME' does not exist on this system!"
        log "Create the user first or set USER_NAME environment variable to the target user"
        return 1
      fi

      # Safety check - warn if destination has existing files
      if [ -d "$HOME_DIR" ] && [ "$(ls -A "$HOME_DIR" 2>/dev/null)" ]; then
        log "WARNING: $HOME_DIR is not empty and will be merged with backup data"
        if [ "$DRY_RUN" != "true" ]; then
          read -r -p "Continue with home directory restore? [y/N]: " ans
          [ "${ans,,}" != "y" ] && { log "Home restore skipped by user."; } || {
            # Note: We do NOT use --delete during restore to avoid accidentally removing
            # files that were excluded during backup
            log "Starting rsync restore (this may take a while)..."
            rsync -aAXv --info=progress2,stats2 --human-readable \
              "$SRC_DIR/home/" "$HOME_DIR/"

            log "Home directory restore completed. Setting ownership..."
            chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR"
          }
        else
          log "Would rsync from $SRC_DIR/home/ to $HOME_DIR/"
          log "Would set ownership to $USER_NAME:$USER_NAME"
        fi
      else
        # Empty destination, safe to proceed without confirmation
        log "Starting rsync restore (this may take a while)..."
        run_cmd rsync -aAXv --info=progress2,stats2 --human-readable \
          "$SRC_DIR/home/" "$HOME_DIR/"

        log "Home directory restore completed. Setting ownership..."
        run_cmd chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR"
      fi
    else
      log "Warning: No home data found to restore."
    fi
  fi

  # Restore systemd units + script (if present)
  if [ "$RESTORE_SYSTEM" = "true" ] && { [ -d "$SRC_DIR/systemd" ] || [ -d "$SRC_DIR/bin" ]; }; then
    log "Restoring systemd units and backup script..."

    if [ -f "$SRC_DIR/bin/backup_restore.sh" ]; then
      log "Restoring backup script to /usr/local/sbin/backup_restore.sh"
      run_cmd install -D -m 0750 -o root -g root "$SRC_DIR/bin/backup_restore.sh" "/usr/local/sbin/backup_restore.sh"
    fi

    if [ -f "$SRC_DIR/systemd/$SERVICE_NAME" ]; then
      log "Restoring systemd service: $SERVICE_NAME"
      run_cmd install -D -m 0644 -o root -g root "$SRC_DIR/systemd/$SERVICE_NAME" "/etc/systemd/system/$SERVICE_NAME"
    fi

    if [ -f "$SRC_DIR/systemd/$TIMER_NAME" ]; then
      log "Restoring systemd timer: $TIMER_NAME"
      run_cmd install -D -m 0644 -o root -g root "$SRC_DIR/systemd/$TIMER_NAME" "/etc/systemd/system/$TIMER_NAME"
    fi

    if [ "$DRY_RUN" != "true" ]; then
      systemctl daemon-reload
      systemctl enable --now "$TIMER_NAME" || true
    else
      log "Would reload systemd and enable $TIMER_NAME"
    fi

    log "Systemd units and script restored."
  fi

  # PROMPT to add fstab lines (creates dirs, appends if missing, reloads, mounts)
  if [ "$RESTORE_SYSTEM" = "true" ]; then
    prompt_and_update_fstab
  fi

  log "Restore completed."
}

# ---------- INTERACTIVE MENU ----------
show_main_menu() {
  while true; do
    echo
    echo "======================================"
    echo "   Backup/Restore Main Menu"
    echo "======================================"
    echo "1) Run backup"
    echo "2) Run full restore"
    echo "3) Run selective restore"
    echo "4) Verify latest backup checksums"
    echo "5) Show backup statistics"
    echo "6) Help"
    echo "7) Exit"
    echo
    read -r -p "Enter your choice [1-7]: " menu_choice

    case "$menu_choice" in
      1)
        log "Starting backup..."
        if do_backup; then
          log "Backup complete. Returning to menu..."
        else
          log "Backup failed. Returning to menu..."
        fi
        ;;
      2)
        SELECTIVE="false"
        log "Starting full restore..."
        if do_restore; then
          log "Restore complete. Returning to menu..."
        else
          log "Restore failed or cancelled. Returning to menu..."
        fi
        ;;
      3)
        SELECTIVE="true"
        log "Starting selective restore..."
        if do_restore; then
          log "Selective restore complete. Returning to menu..."
        else
          log "Selective restore failed or cancelled. Returning to menu..."
        fi
        SELECTIVE="false"  # Reset for next time
        ;;
      4)
        log "Verifying latest backup checksums..."
        _menu_latest="$(latest_backup_dir)"
        if [ -n "$_menu_latest" ]; then
          if verify_checksums "$_menu_latest"; then
            log "Checksum verification completed successfully."
          else
            log "Checksum verification failed."
          fi
        else
          log "No backups found to verify."
        fi
        unset _menu_latest
        ;;
      5)
        show_backup_stats
        ;;
      6)
        show_help
        ;;
      7)
        log "Exiting..."
        exit 0
        ;;
      *)
        echo "Invalid choice. Please enter 1-7."
        ;;
    esac
  done
}

show_backup_stats() {
  require_mount
  local backup_count
  backup_count=$(find "$MOUNT_BASE/backups" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | wc -l)
  local free_gb
  free_gb=$(get_free_space_gb)
  local latest
  latest="$(latest_backup_dir)"

  echo
  echo "======================================"
  echo "   Backup Statistics"
  echo "======================================"
  echo "Backup location: $MOUNT_BASE"
  echo "Total backups: $backup_count"
  echo "Free space: ${free_gb}GB"
  echo "Latest backup: ${latest:-None}"

  if [ -n "$latest" ]; then
    local backup_size_gb
    backup_size_gb=$(get_backup_size_gb "$latest")
    echo "Latest backup size: ${backup_size_gb}GB"
    echo "Latest backup date: $(basename "$latest" | sed 's/backup_//')"
  fi

  echo
  echo "Retention policy:"
  echo "  Min backups to keep: $MIN_BACKUPS_TO_KEEP"
  echo "  Max backups allowed: $MAX_BACKUPS"
  echo "  Min free space target: ${MIN_FREE_SPACE_GB}GB"
  echo
}

# ---------- INIT / SETUP ----------
do_init() {
  echo
  echo "======================================"
  echo "   Backup/Restore Setup Wizard"
  echo "======================================"
  echo
  echo "This wizard will create a configuration file for your backup settings."
  echo

  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/backup-restore"
  local config_file="$config_dir/config"

  if [ -f "$config_file" ]; then
    echo "Existing configuration found at: $config_file"
    read -r -p "Overwrite existing configuration? [y/N]: " ans
    [ "${ans,,}" != "y" ] && { echo "Setup cancelled."; return 0; }
  fi

  # Gather configuration
  echo
  echo "--- Basic Settings ---"
  echo

  read -r -p "Username to backup [$(whoami)]: " input_user
  local cfg_user="${input_user:-$(whoami)}"

  read -r -p "Home directory [/home/$cfg_user]: " input_home
  local cfg_home="${input_home:-/home/$cfg_user}"

  echo
  echo "--- Backup Location ---"
  echo
  echo "Enter the path where backups will be stored."
  echo "This can be a local mount point or network share."
  read -r -p "Backup location [/mnt/backup]: " input_mount
  local cfg_mount="${input_mount:-/mnt/backup}"

  echo
  echo "--- Retention Policy ---"
  echo

  read -r -p "Minimum free space to maintain (GB) [50]: " input_min_space
  local cfg_min_space="${input_min_space:-50}"

  read -r -p "Minimum backups to always keep [3]: " input_min_backups
  local cfg_min_backups="${input_min_backups:-3}"

  read -r -p "Maximum backups to store [30]: " input_max_backups
  local cfg_max_backups="${input_max_backups:-30}"

  echo
  echo "--- fstab Configuration ---"
  echo

  read -r -p "Manage backup drive in /etc/fstab? [Y/n]: " input_fstab
  local cfg_fstab_enabled="true"
  [ "${input_fstab,,}" = "n" ] && cfg_fstab_enabled="false"

  local cfg_nas_enabled="false"
  local cfg_nas_share=""
  local cfg_nas_mount=""
  local cfg_nas_cred=""

  read -r -p "Configure a NAS/CIFS mount? [y/N]: " input_nas
  if [ "${input_nas,,}" = "y" ]; then
    cfg_nas_enabled="true"
    read -r -p "NAS share path (e.g., //nas.local/share): " cfg_nas_share
    read -r -p "NAS mount point [/mnt/nas]: " input_nas_mount
    cfg_nas_mount="${input_nas_mount:-/mnt/nas}"
    read -r -p "NAS credentials file [$config_dir/nas.cred]: " input_nas_cred
    cfg_nas_cred="${input_nas_cred:-$config_dir/nas.cred}"
  fi

  echo
  echo "--- Exclusions ---"
  echo
  echo "Default exclusions: .cache, .local/share/Trash, .local/share/Steam, Downloads, *.tmp, *.bak"
  read -r -p "Use default exclusions? [Y/n]: " input_excl
  local cfg_custom_excl=""
  if [ "${input_excl,,}" = "n" ]; then
    echo "Enter exclusion patterns (comma-separated, e.g., '.cache,Downloads,*.log'):"
    read -r cfg_custom_excl
  fi

  # Create config directory
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"

  # Write configuration file
  cat > "$config_file" <<EOF
# backup_restore.sh configuration file
# Generated by setup wizard on $(date)
#
# This file is sourced by backup_restore.sh
# All values can also be set via environment variables

# === User Configuration ===
USER_NAME="$cfg_user"
HOME_DIR="$cfg_home"

# === Backup Location ===
MOUNT_BASE="$cfg_mount"

# === Retention Policy ===
MIN_FREE_SPACE_GB="$cfg_min_space"
MIN_BACKUPS_TO_KEEP="$cfg_min_backups"
MAX_BACKUPS="$cfg_max_backups"

# === fstab Configuration ===
BACKUP_FSTAB_ENABLED="$cfg_fstab_enabled"
BACKUP_MOUNT_POINT="$cfg_mount"
# BACKUP_FSTAB_OPTIONS="ext4  nofail,x-systemd.automount,x-systemd.idle-timeout=60  0  2"

# === NAS Configuration (optional) ===
NAS_ENABLED="$cfg_nas_enabled"
EOF

  if [ "$cfg_nas_enabled" = "true" ]; then
    cat >> "$config_file" <<EOF
NAS_SHARE="$cfg_nas_share"
NAS_MOUNT_POINT="$cfg_nas_mount"
NAS_CREDENTIALS_FILE="$cfg_nas_cred"
# NAS_FSTAB_OPTIONS="cifs  credentials=\$NAS_CREDENTIALS_FILE,rw,_netdev,noauto,x-systemd.automount  0  0"
EOF
  else
    cat >> "$config_file" <<EOF
# NAS_SHARE="//nas.local/share"
# NAS_MOUNT_POINT="/mnt/nas"
# NAS_CREDENTIALS_FILE="$config_dir/nas.cred"
EOF
  fi

  if [ -n "$cfg_custom_excl" ]; then
    cat >> "$config_file" <<EOF

# === Custom Exclusions ===
# Uncomment and modify the EXCLUDE array as needed
# EXCLUDE=(
EOF
    IFS=',' read -ra excl_arr <<< "$cfg_custom_excl"
    for excl in "${excl_arr[@]}"; do
      excl="$(echo "$excl" | xargs)"  # trim whitespace
      echo "#   \"--exclude=$excl\"" >> "$config_file"
    done
    echo "# )" >> "$config_file"
  fi

  chmod 600 "$config_file"

  echo
  echo "======================================"
  echo "   Configuration Complete!"
  echo "======================================"
  echo
  echo "Configuration saved to: $config_file"
  echo

  # Create NAS credentials file template if NAS enabled
  if [ "$cfg_nas_enabled" = "true" ] && [ ! -f "$cfg_nas_cred" ]; then
    echo "Creating NAS credentials template at: $cfg_nas_cred"
    mkdir -p "$(dirname "$cfg_nas_cred")"
    cat > "$cfg_nas_cred" <<EOF
# NAS credentials file
# Replace with your actual username and password
username=YOUR_USERNAME
password=YOUR_PASSWORD
# domain=WORKGROUP  # Optional, uncomment if needed
EOF
    chmod 600 "$cfg_nas_cred"
    echo "IMPORTANT: Edit $cfg_nas_cred with your actual NAS credentials!"
    echo
  fi

  echo "Next steps:"
  echo "  1. Ensure your backup location ($cfg_mount) is mounted"
  echo "  2. Run '$0 backup' to create your first backup"
  echo "  3. (Optional) Set up automated backups with systemd timer"
  echo
  echo "To set up automated daily backups:"
  echo "  sudo cp $0 /usr/local/sbin/backup_restore.sh"
  echo "  sudo chmod 750 /usr/local/sbin/backup_restore.sh"
  echo "  # Then create systemd service and timer (see README for examples)"
  echo
}

show_help() {
  cat <<E2U
backup_restore.sh v${SCRIPT_VERSION} - Cross-distribution backup and restore utility

Usage: $0 [OPTIONS] {backup|restore|menu|init|help}

Options:
  --dry-run     Test mode - show what would be done without making changes
  --selective   Interactive mode to choose what to restore (restore only)
  --version     Show version number

Commands:
  init     - Interactive setup wizard to create configuration file
  menu     - Interactive menu for multiple operations (default if no command given)
  backup   - Create a new backup
             * Saves package list, repository config, GPG keys, Flatpaks
             * Backs up home directory (rsync with hardlinks or tar for CIFS)
             * Uses smart retention policy to manage disk space
             * Auto-detects Fedora, Ubuntu/Debian, and openSUSE

  restore  - Restore from the latest backup
             * Restores repositories, keys, and packages
             * Restores home directory (with ownership correction)
             * Restores systemd units for automated backups
             * Optionally updates /etc/fstab for mount points

  help     - Show this help message

Configuration:
  Config file locations (in order of precedence):
    1. \$CONFIG_FILE environment variable
    2. ~/.config/backup-restore/config
    3. /etc/backup-restore/config

  Run '$0 init' to create a configuration file interactively.

  Environment variables (override config file):
    USER_NAME            - User to backup (default: current user)
    HOME_DIR             - Home directory path
    MOUNT_BASE           - Backup destination path
    MIN_FREE_SPACE_GB    - Minimum free space to maintain (default: 50)
    MIN_BACKUPS_TO_KEEP  - Minimum backups to keep (default: 3)
    MAX_BACKUPS          - Maximum backups to store (default: 30)
    DRY_RUN              - Set to 'true' for test mode

Supported Distributions:
  - Fedora, RHEL, CentOS, Rocky, AlmaLinux (dnf/dnf5)
  - Ubuntu, Debian, Linux Mint, Pop!_OS (apt)
  - openSUSE Leap, Tumbleweed, SLES (zypper)

Examples:
  $0 init                    # Run setup wizard
  $0 backup                  # Create a backup
  $0 --dry-run backup        # Test backup without changes
  $0 restore                 # Full restore from latest backup
  $0 --selective restore     # Choose what to restore
  $0 menu                    # Interactive menu

For more information, see the README.md file.
E2U
}

# ---------- ENTRY ----------
ACTION="${1:-menu}"
SELECTIVE="${SELECTIVE:-false}"

# Parse command line options
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --selective)
      SELECTIVE="true"
      shift
      ;;
    --version|-v)
      echo "backup_restore.sh v${SCRIPT_VERSION}"
      exit 0
      ;;
    backup|restore|menu|init)
      ACTION="$1"
      shift
      ;;
    help|--help|-h)
      ACTION="help"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      ACTION="help"
      break
      ;;
  esac
done

# Show config status
if [ -n "$CONFIG_LOADED" ]; then
  log "Configuration loaded from: $CONFIG_LOADED"
fi

case "$ACTION" in
  init)
    do_init
    ;;
  backup)
    [ "$DRY_RUN" = "true" ] && log "DRY RUN MODE - No changes will be made"
    do_backup
    ;;
  restore)
    [ "$DRY_RUN" = "true" ] && log "DRY RUN MODE - No changes will be made"
    do_restore
    ;;
  menu)
    [ "$DRY_RUN" = "true" ] && log "DRY RUN MODE - No changes will be made"
    show_main_menu
    ;;
  help|*)
    show_help
    exit 0
    ;;
esac
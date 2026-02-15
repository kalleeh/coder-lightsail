#!/usr/bin/env bash
# backup.sh - Back up essential user data on the standalone dev box.
#
# Usage:
#   ./backup.sh                                        # Create backup
#   ./backup.sh /path/to/backups                       # Create backup in custom dir
#   ./backup.sh --restore backup-20260215-120000.tar.gz  # Restore from backup
#
# Run ON the remote server. Backs up projects, shell configs, SSH keys,
# git config, and installed package list. Keeps the last 7 backups.

set -euo pipefail

KEEP=7

# ── Restore mode ──────────────────────────────────────────────────────
if [[ "${1:-}" == "--restore" ]]; then
    ARCHIVE="${2:?Usage: $0 --restore <backup-file.tar.gz>}"
    if [[ ! -f "$ARCHIVE" ]]; then
        echo "Error: file not found: $ARCHIVE"
        exit 1
    fi
    echo "Restoring from $ARCHIVE ..."
    tar xzf "$ARCHIVE" -C "$HOME"
    echo "Restore complete."
    exit 0
fi

# ── Backup mode ───────────────────────────────────────────────────────
BACKUP_DIR="${1:-$HOME/backups}"
mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$BACKUP_DIR/backup-${TIMESTAMP}.tar.gz"
PKG_LIST=$(mktemp)

# Capture installed packages for reproducibility.
dpkg --get-selections > "$PKG_LIST" 2>/dev/null || true

# Collect paths that actually exist.
SOURCES=()
for item in \
    "$HOME/projects" \
    "$HOME/.zshrc" \
    "$HOME/.tmux.conf" \
    "$HOME/.config/starship.toml" \
    "$HOME/.config/kiro" \
    "$HOME/.ssh" \
    "$HOME/.gitconfig" \
    "$PKG_LIST"; do
    if [[ -e "$item" ]]; then
        SOURCES+=("$item")
    fi
done

if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "Nothing to back up."
    rm -f "$PKG_LIST"
    exit 0
fi

# Build the archive. Paths are stored relative to $HOME so restore is
# a simple extract into $HOME.
tar czf "$ARCHIVE" \
    -C "$HOME" \
    "${SOURCES[@]/#$HOME\//}" \
    -C "$(dirname "$PKG_LIST")" \
    "$(basename "$PKG_LIST")" \
    2>/dev/null

rm -f "$PKG_LIST"

# ── Rotation ──────────────────────────────────────────────────────────
# Keep only the newest $KEEP backups matching our naming pattern.
mapfile -t OLD < <(
    ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1))
)
for f in "${OLD[@]}"; do
    rm -f "$f"
done

# ── Summary ───────────────────────────────────────────────────────────
SIZE="$(du -h "$ARCHIVE" | cut -f1)"
echo "Backup complete: $ARCHIVE ($SIZE)"

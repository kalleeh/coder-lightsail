#!/usr/bin/env bash
# backup.sh - Back up essential user data on the standalone dev box.
#
# Usage:
#   ./backup.sh                                        # Create backup
#   ./backup.sh /path/to/backups                       # Create backup in custom dir
#   ./backup.sh --restore backup-20260215-120000.tar.gz  # Restore from backup
#   ./backup.sh --list                                 # List available backups
#
# Run ON the remote server. Backs up projects, shell configs, SSH keys,
# git config, and installed package list. Keeps the last 7 backups.

set -euo pipefail

KEEP=7
BACKUP_DIR="${HOME}/backups"

# ── List mode ─────────────────────────────────────────────────────────
if [[ "${1:-}" == "--list" ]]; then
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "No backups found (directory doesn't exist: $BACKUP_DIR)"
        exit 0
    fi
    echo "Available backups in $BACKUP_DIR:"
    ls -lh "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null || echo "  (none)"
    exit 0
fi

# ── Restore mode ──────────────────────────────────────────────────────
if [[ "${1:-}" == "--restore" ]]; then
    ARCHIVE="${2:?Usage: $0 --restore <backup-file.tar.gz>}"
    if [[ ! -f "$ARCHIVE" ]]; then
        echo "Error: file not found: $ARCHIVE"
        echo ""
        echo "Available backups:"
        ls -1 "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null || echo "  (none)"
        exit 1
    fi
    echo "Restoring from $ARCHIVE ..."
    echo "This will overwrite existing files. Press Ctrl-C to cancel."
    sleep 3
    tar xzf "$ARCHIVE" -C "$HOME"
    echo "✓ Restore complete."
    echo ""
    echo "Note: Package list was restored to ~/dpkg-selections.txt"
    echo "To reinstall packages: sudo dpkg --set-selections < ~/dpkg-selections.txt && sudo apt-get dselect-upgrade"
    exit 0
fi

# ── Backup mode ───────────────────────────────────────────────────────
if [[ -n "${1:-}" && "$1" != "--"* ]]; then
    BACKUP_DIR="$1"
fi
mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$BACKUP_DIR/backup-${TIMESTAMP}.tar.gz"
PKG_LIST="$HOME/dpkg-selections.txt"

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
    "$HOME/.ai-credentials" \
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

echo "Creating backup..."
echo "  Sources: ${#SOURCES[@]} items"

# Build the archive. Paths are stored relative to $HOME so restore is
# a simple extract into $HOME.
tar czf "$ARCHIVE" \
    -C "$HOME" \
    "${SOURCES[@]/#$HOME\//}" \
    2>/dev/null

# ── Rotation ──────────────────────────────────────────────────────────
# Keep only the newest $KEEP backups matching our naming pattern.
mapfile -t OLD < <(
    ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1))
)
if [[ ${#OLD[@]} -gt 0 ]]; then
    echo "  Removing ${#OLD[@]} old backup(s)..."
    for f in "${OLD[@]}"; do
        rm -f "$f"
    done
fi

# ── Summary ───────────────────────────────────────────────────────────
SIZE="$(du -h "$ARCHIVE" | cut -f1)"
echo "✓ Backup complete: $ARCHIVE ($SIZE)"
echo ""
echo "To restore: ./backup.sh --restore $ARCHIVE"
echo "To list backups: ./backup.sh --list"

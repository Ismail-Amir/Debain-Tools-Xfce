#!/usr/bin/env bash

# install-appimage.sh – Extract and install an AppImage with desktop integration
# Compatible with GNOME, Xfce, KDE Plasma, and other freedesktop environments.
# Logs per‑app information for easy uninstallation, including source AppImage path.

set -euo pipefail

# ----- Configuration -----
USER_APPS_DIR="$HOME/.local/share/appimages"          # extracted apps go here (user)
USER_DESKTOP_DIR="$HOME/.local/share/applications"
USER_ICON_DIR="$HOME/.local/share/icons"

SYSTEM_APPS_DIR="/opt"                                # system-wide apps
SYSTEM_DESKTOP_DIR="/usr/share/applications"
SYSTEM_ICON_DIR="/usr/share/icons"

# ----- Per‑app log directory (always under real user's home) -----
# Determine the real user's home even when running with sudo
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi
LOG_DIR="$REAL_HOME/.local/share/installed-appimages"
mkdir -p "$LOG_DIR"

# ----- Coloured output helpers -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error()   { echo -e "${RED}Error: $*${NC}" >&2; }
success() { echo -e "${GREEN}$*${NC}"; }
info()    { echo -e "${YELLOW}$*${NC}"; }

# ----- Cleanup temporary extraction directory on exit -----
cleanup_extract_dir() {
    if [[ -n "${EXTRACT_DIR:-}" && -d "$EXTRACT_DIR" ]]; then
        rm -rf "$EXTRACT_DIR"
    fi
}
trap cleanup_extract_dir EXIT

# ----- Pause on exit to keep terminal open when run from .desktop launcher -----
pause_on_exit() {
    if [[ -z "${NO_PAUSE:-}" ]] && [[ -t 0 ]]; then
        echo
        read -p "Press Enter to close this window..." -r
    fi
}
trap pause_on_exit EXIT

# ----- Detect desktop environment -----
detect_de() {
    if [[ "$XDG_CURRENT_DESKTOP" =~ .*(GNOME|Unity|XFCE|MATE|Cinnamon|LXQt|Pantheon).* ]]; then
        echo "gtk"
    elif [[ "$XDG_CURRENT_DESKTOP" =~ .*(KDE|Plasma).* ]]; then
        echo "kde"
    else
        echo "other"
    fi
}

# ----- Write per‑app log file (as the real user) -----
write_log() {
    local app_name="$1"
    local target_dir="$2"
    local desktop_file="$3"
    local icon_path="$4"
    local source_path="$5"
    local log_file="$LOG_DIR/${app_name,,}.log"  # lowercase name with .log

    {
        echo "# App: $app_name"
        echo "# Installed: $(date -Iseconds)"
        echo "Directory: $target_dir"
        echo "Desktop: $desktop_file"
        if [[ -n "$icon_path" ]]; then
            echo "Icon: $icon_path"
        fi
        echo "Source: $source_path"
    } > "$log_file"
}

# ----- Usage -----
usage() {
    cat <<EOF
╔═══════════════════════════════════════════════════════════════════╗
║         AppImage Installer - Extract and Install AppImages        ║
╚═══════════════════════════════════════════════════════════════════╝

This script extracts an AppImage and installs it on your system with
full desktop integration. It will:
  • Extract the AppImage contents
  • Install the application to ~/.local/share/appimages/ (user) or /opt/ (system)
  • Create a proper .desktop launcher in your applications menu
  • Copy the application icon to the appropriate location
  • Log all installed files for easy removal

Usage:
  $0 APPIMAGE_FILE

Options:
  -h, --help    Show this help message

Examples:
  # Install a single AppImage (you'll be prompted for user/system)
  $0 KeePassXC-2.7.4-x86_64.AppImage

  # Double-click usage: create a desktop launcher that runs this script
  # Create a file called "Install AppImage.desktop" with:
  #
  # [Desktop Entry]
  # Type=Application
  # Name=Install AppImage
  # Exec=/path/to/install-appimage.sh %f
  # Terminal=true
  # MimeType=application/vnd.appimage;
  #
  # Then set it as the default application for .AppImage files.

EOF
    exit 0
}

# ----- Parse arguments -----
if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

APPIMAGE="$1"
shift

if [[ ! -f "$APPIMAGE" ]]; then
    error "File not found: $APPIMAGE"
    exit 1
fi

# ----- Improved AppImage detection (search first 4KB for ELF magic) -----
if ! dd if="$APPIMAGE" bs=4096 count=1 2>/dev/null | grep -a -q $'\x7fELF'; then
    info "Warning: $APPIMAGE does not contain ELF magic within the first 4KB. Proceeding anyway..."
    info "The extraction step will confirm if it's a valid AppImage."
fi

# ----- Ask installation mode -----
echo "Install for:"
echo "  1) Current user only (no sudo)"
echo "  2) System wide (requires sudo)"
read -rp "Choice [1/2]: " choice

case "$choice" in
    1)
        INSTALL_MODE="user"
        BASE_DIR="$USER_APPS_DIR"
        DESKTOP_DIR="$USER_DESKTOP_DIR"
        ICON_BASE_DIR="$USER_ICON_DIR"
        SUDO=""
        ;;
    2)
        INSTALL_MODE="system"
        BASE_DIR="$SYSTEM_APPS_DIR"
        DESKTOP_DIR="$SYSTEM_DESKTOP_DIR"
        ICON_BASE_DIR="$SYSTEM_ICON_DIR"
        SUDO="sudo"
        ;;
    *)
        error "Invalid choice. Exiting."
        exit 1
        ;;
esac

# ----- Create target directories if they don't exist -----
mkdir -p "$BASE_DIR"
mkdir -p "$DESKTOP_DIR"
mkdir -p "$ICON_BASE_DIR"

# ----- Extract the AppImage -----
info "Extracting $APPIMAGE ..."
chmod +x "$APPIMAGE"
EXTRACT_DIR="$(mktemp -d)"
cd "$EXTRACT_DIR"
if ! "$APPIMAGE" --appimage-extract > /tmp/appimage-extract.log 2>&1; then
    error "Extraction failed. The file may not be a valid AppImage."
    error "Details from --appimage-extract:"
    cat /tmp/appimage-extract.log >&2
    rm -f /tmp/appimage-extract.log
    exit 1
fi
rm -f /tmp/appimage-extract.log

# The extracted content is always in a directory called squashfs-root
if [[ ! -d squashfs-root ]]; then
    error "Extraction did not produce a 'squashfs-root' directory."
    exit 1
fi

# ----- Determine application name from the extracted .desktop file -----
APP_NAME=""
DESKTOP_FOUND=""
EXTRACTED_ROOT="$EXTRACT_DIR/squashfs-root"
# First try the root directory
desktop_files=("$EXTRACTED_ROOT"/*.desktop)
if [[ ${#desktop_files[@]} -eq 1 && -f "${desktop_files[0]}" ]]; then
    DESKTOP_FOUND="${desktop_files[0]}"
fi
# If not found, look into usr/share/applications/
if [[ -z "$DESKTOP_FOUND" && -d "$EXTRACTED_ROOT/usr/share/applications" ]]; then
    desktop_files=("$EXTRACTED_ROOT/usr/share/applications"/*.desktop)
    if [[ ${#desktop_files[@]} -eq 1 && -f "${desktop_files[0]}" ]]; then
        DESKTOP_FOUND="${desktop_files[0]}"
    fi
fi

if [[ -n "$DESKTOP_FOUND" ]]; then
    # Extract the Name property from the .desktop file
    DESKTOP_NAME="$(grep -m1 '^Name=' "$DESKTOP_FOUND" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -n "$DESKTOP_NAME" ]]; then
        APP_NAME="$DESKTOP_NAME"
    fi
fi

# Fallback to filename-based name if not found
if [[ -z "$APP_NAME" ]]; then
    APP_NAME="$(basename "$APPIMAGE" .AppImage)"
    APP_NAME="${APP_NAME%%.*}"   # remove further extensions if any (e.g. .appimage)
    APP_NAME="${APP_NAME^}"       # capitalise first letter (simple)
fi

# ----- Move the extracted directory to its final place -----
TARGET_DIR="$BASE_DIR/$APP_NAME"
if [[ -e "$TARGET_DIR" ]]; then
    info "Target directory $TARGET_DIR already exists."
    read -rp "Overwrite existing installation? [y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        info "Skipping installation of $APP_NAME."
        exit 0
    fi
    info "Removing existing installation..."
    # Remove the old directory
    $SUDO rm -rf "$TARGET_DIR"
    # Remove the old desktop file
    OLD_DESKTOP="$DESKTOP_DIR/${APP_NAME,,}.desktop"
    [[ -f "$OLD_DESKTOP" ]] && $SUDO rm -f "$OLD_DESKTOP"
    # Remove the old log file (as real user)
    OLD_LOG="$LOG_DIR/${APP_NAME,,}.log"
    [[ -f "$OLD_LOG" ]] && rm -f "$OLD_LOG"
fi
$SUDO mv squashfs-root "$TARGET_DIR"
cd /
# EXTRACT_DIR will be cleaned up by trap

# ----- Locate a .desktop file inside the extracted tree -----
DESKTOP_FILE=""
# First try the root directory
desktop_files=("$TARGET_DIR"/*.desktop)
if [[ ${#desktop_files[@]} -eq 1 && -f "${desktop_files[0]}" ]]; then
    DESKTOP_FILE="${desktop_files[0]}"
fi
# If not found, look into usr/share/applications/
if [[ -z "$DESKTOP_FILE" && -d "$TARGET_DIR/usr/share/applications" ]]; then
    desktop_files=("$TARGET_DIR/usr/share/applications"/*.desktop)
    if [[ ${#desktop_files[@]} -eq 1 && -f "${desktop_files[0]}" ]]; then
        DESKTOP_FILE="${desktop_files[0]}"
    fi
fi

# ----- If no .desktop file exists, abort and clean up -----
if [[ -z "$DESKTOP_FILE" ]]; then
    error "No .desktop file found inside the AppImage. Cannot install."
    $SUDO rm -rf "$TARGET_DIR"
    exit 1
fi

# ----- Determine icon name from .desktop file (if available) -----
ICON_NAME_FROM_DESKTOP=""
ICON_LINE="$(grep -E '^Icon=' "$DESKTOP_FILE" | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -n "$ICON_LINE" ]]; then
    # If it's a path, take basename; otherwise keep as is
    ICON_NAME_FROM_DESKTOP="$(basename "$ICON_LINE")"
    # Remove file extension if present (icon names are usually without extension)
    ICON_NAME_FROM_DESKTOP="${ICON_NAME_FROM_DESKTOP%.*}"
fi

# ----- Locate an icon file -----
ICON_SOURCE=""
ICON_FILENAME=""

# Function to search for an icon file by name (without extension)
find_icon_file() {
    local name="$1"
    local dir="$TARGET_DIR"
    # Use find with -print -quit to get first match, handling spaces safely
    find "$dir" -type f \( -name "${name}.png" -o -name "${name}.svg" -o -name "${name}.xpm" -o -name "${name}.ico" \) -print -quit 2>/dev/null
}

if [[ -n "$ICON_NAME_FROM_DESKTOP" ]]; then
    ICON_SOURCE="$(find_icon_file "$ICON_NAME_FROM_DESKTOP")"
fi

# If still not found, try .DirIcon or any png/svg
if [[ -z "$ICON_SOURCE" ]]; then
    if [[ -f "$TARGET_DIR/.DirIcon" ]]; then
        ICON_SOURCE="$TARGET_DIR/.DirIcon"
        ICON_NAME_FROM_DESKTOP="$APP_NAME"
    else
        # Look for any png or svg in usr/share/icons
        if [[ -d "$TARGET_DIR/usr/share/icons" ]]; then
            ICON_SOURCE="$(find "$TARGET_DIR/usr/share/icons" -type f \( -name "*.png" -o -name "*.svg" \) -print -quit 2>/dev/null)"
        fi
        if [[ -z "$ICON_SOURCE" ]]; then
            # Fallback: any png/svg anywhere
            ICON_SOURCE="$(find "$TARGET_DIR" -type f \( -name "*.png" -o -name "*.svg" \) -print -quit 2>/dev/null)"
        fi
        # Set icon name from the found file (without extension)
        if [[ -n "$ICON_SOURCE" ]]; then
            ICON_NAME_FROM_DESKTOP="$(basename "$ICON_SOURCE")"
            ICON_NAME_FROM_DESKTOP="${ICON_NAME_FROM_DESKTOP%.*}"
        else
            ICON_NAME_FROM_DESKTOP="$APP_NAME"
        fi
    fi
fi

# ----- Smart icon installation with fallback -----
# This function tries to place the icon in the standard hicolor theme.
# If that fails (e.g., missing index.theme for user mode), it falls back
# to copying directly to the root icon directory.
install_icon_standard() {
    local icon_source="$1"
    local icon_basename="$2"
    local base_dir="$3"
    local sudo_cmd="$4"
    local installed_path=""
    local icon_name=""
    local use_theme=true

    # Determine MIME type and dimensions
    local mime_type
    mime_type=$(file --mime-type -b "$icon_source")
    local size=""
    local subdir=""

    # Check if we have ImageMagick for precise size detection
    if command -v identify >/dev/null 2>&1; then
        case "$mime_type" in
            image/svg+xml)
                subdir="scalable/apps"
                ;;
            image/png|image/x-png)
                size=$(identify -format "%w" "$icon_source" 2>/dev/null)
                if [[ -n "$size" && "$size" -gt 0 ]]; then
                    subdir="${size}x${size}/apps"
                else
                    subdir="48x48/apps"
                fi
                ;;
            *)
                subdir="48x48/apps"
                ;;
        esac
    else
        # Fallback without ImageMagick
        case "$mime_type" in
            image/svg+xml)
                subdir="scalable/apps"
                ;;
            image/png|image/x-png)
                size=$(file "$icon_source" | grep -oE '[0-9]+ x [0-9]+' | head -1 | cut -d' ' -f1)
                if [[ -n "$size" && "$size" -gt 0 ]]; then
                    subdir="${size}x${size}/apps"
                else
                    subdir="48x48/apps"
                fi
                ;;
            *)
                subdir="48x48/apps"
                ;;
        esac
    fi

    # Determine the target path using the theme
    local hicolor_dir="$base_dir/hicolor"
    local dest_dir="$hicolor_dir/$subdir"
    local theme_target="$dest_dir/$icon_basename"

    # For user mode, require index.theme to exist to use the theme
    if [[ "$INSTALL_MODE" == "user" ]]; then
        if [[ ! -f "$hicolor_dir/index.theme" ]]; then
            use_theme=false
            # Print warning to stderr so it doesn't get captured
            echo -e "${YELLOW}User hicolor theme missing index.theme; falling back to simple icon placement.${NC}" >&2
        fi
    fi

    if $use_theme; then
        # Install into the theme subdirectory
        $sudo_cmd mkdir -p "$dest_dir"
        $sudo_cmd cp "$icon_source" "$theme_target"
        installed_path="$theme_target"
        icon_name="${icon_basename%.*}"
        
        # Update icon cache for the hicolor theme if we used it
        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            if [[ "$INSTALL_MODE" == "system" ]]; then
                if [[ -d "/usr/share/icons/hicolor" ]]; then
                    $sudo_cmd gtk-update-icon-cache -f /usr/share/icons/hicolor
                fi
            else
                if [[ -d "$HOME/.local/share/icons/hicolor" ]]; then
                    gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
                fi
            fi
        fi
    else
        # Fallback: copy directly to the root icon directory (old behaviour)
        local root_target="$base_dir/$icon_basename"
        $sudo_cmd cp "$icon_source" "$root_target"
        installed_path="$root_target"
        icon_name="${icon_basename%.*}"
    fi

    # Return the installed path and the name for .desktop
    echo "$installed_path|$icon_name"
}

# ----- Install the icon if found -----
ICON_PATH=""
ICON_NAME_FOR_DESKTOP=""
if [[ -n "$ICON_SOURCE" ]]; then
    info "Found icon: $ICON_SOURCE"
    ICON_FILENAME="$(basename "$ICON_SOURCE")"
    result=$(install_icon_standard "$ICON_SOURCE" "$ICON_FILENAME" "$ICON_BASE_DIR" "$SUDO")
    ICON_PATH="${result%|*}"
    ICON_NAME_FOR_DESKTOP="${result#*|}"
else
    info "No suitable icon found. You may need to set one manually later."
    ICON_NAME_FOR_DESKTOP="$APP_NAME"
fi

# ----- Modify the .desktop file -----
TMP_DESKTOP="$(mktemp)"
cp "$DESKTOP_FILE" "$TMP_DESKTOP"

# Update Exec line to point to the absolute AppRun
if [[ -f "$TARGET_DIR/AppRun" ]]; then
    NEW_EXEC="$TARGET_DIR/AppRun"
else
    NEW_EXEC="$TARGET_DIR/AppRun"  # will likely fail, but keep as is
fi
sed -i "s|^Exec=.*|Exec=$NEW_EXEC|" "$TMP_DESKTOP"

# Remove TryExec line (prevents menu hiding when binary not in PATH)
sed -i '/^TryExec=/d' "$TMP_DESKTOP"

# Update Icon line to use the icon name (without path)
if [[ -n "$ICON_NAME_FOR_DESKTOP" ]]; then
    if grep -q '^Icon=' "$TMP_DESKTOP"; then
        sed -i "s|^Icon=.*|Icon=$ICON_NAME_FOR_DESKTOP|" "$TMP_DESKTOP"
    else
        # Insert after [Desktop Entry] or at the end
        sed -i '/^\[Desktop Entry\]/a Icon='"$ICON_NAME_FOR_DESKTOP" "$TMP_DESKTOP"
    fi
fi

# ----- Install the .desktop file -----
DESKTOP_TARGET="$DESKTOP_DIR/${APP_NAME,,}.desktop"
$SUDO cp "$TMP_DESKTOP" "$DESKTOP_TARGET"
rm -f "$TMP_DESKTOP"

# ----- Make the main binary executable (if AppRun exists) -----
if [[ -f "$TARGET_DIR/AppRun" ]]; then
    $SUDO chmod +x "$TARGET_DIR/AppRun"
fi

# ----- Get absolute path of the original AppImage for logging -----
# Use realpath if available, otherwise fallback to readlink -f
if command -v realpath >/dev/null 2>&1; then
    SOURCE_ABS="$(realpath "$APPIMAGE")"
else
    SOURCE_ABS="$(readlink -f "$APPIMAGE")"
fi

# ----- Write per‑app log file (as the real user) -----
write_log "$APP_NAME" "$TARGET_DIR" "$DESKTOP_TARGET" "$ICON_PATH" "$SOURCE_ABS"

# ----- Update desktop database (all environments) -----
if command -v update-desktop-database >/dev/null 2>&1; then
    if [[ "$INSTALL_MODE" == "system" ]]; then
        $SUDO update-desktop-database "$DESKTOP_DIR"
    else
        update-desktop-database "$DESKTOP_DIR"
    fi
fi

# ----- Environment‑specific cache updates (KDE etc.) -----
DE="$(detect_de)"
case "$DE" in
    kde)
        # KDE Plasma: run kbuildsycoca5 or kbuildsycoca6
        if command -v kbuildsycoca6 >/dev/null 2>&1; then
            info "Updating KDE menu cache (kbuildsycoca6)..."
            kbuildsycoca6 --noincremental
        elif command -v kbuildsycoca5 >/dev/null 2>&1; then
            info "Updating KDE menu cache (kbuildsycoca5)..."
            kbuildsycoca5 --noincremental
        else
            info "KDE detected but kbuildsycoca not found. You may need to log out and back in."
        fi
        ;;
    gtk)
        # GTK environments already handled by icon cache update in install_icon_standard
        ;;
    other)
        info "Desktop environment not specifically detected. The launcher should appear after logging out and back in."
        ;;
esac

# ----- Print final information -----
success "
Installation completed!
"
echo "   Application name: $APP_NAME"
echo "Extracted directory: $TARGET_DIR"
echo "           Launcher: $DESKTOP_TARGET"
if [[ -n "$ICON_PATH" ]]; then
    echo "               Icon: $ICON_PATH"
fi
echo "           Log file: $LOG_DIR/${APP_NAME,,}.log"
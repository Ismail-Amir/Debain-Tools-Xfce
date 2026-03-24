#!/usr/bin/env bash

# uninstall-appimage.sh – Remove a previously installed AppImage
# Uses the per‑app log files created by install-appimage.sh

set -euo pipefail

# ----- Configuration -----
REAL_HOME="${HOME}"
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
LOG_DIR="$REAL_HOME/.local/share/installed-appimages"

# ----- Coloured output helpers -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error()   { echo -e "${RED}Error: $*${NC}" >&2; }
success() { echo -e "${GREEN}$*${NC}"; }
info()    { echo -e "${YELLOW}$*${NC}"; }

# ----- Check if log directory exists -----
if [[ ! -d "$LOG_DIR" ]]; then
    error "Cannot find installtions log directory ~/.local/share/installed-appimages"
    info "Either the installter script is not installed, or you have never installed
any AppImage application yet!"
    exit 1
fi

# ----- Collect installed apps from log files -----
mapfile -t log_files < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" | sort)

if [[ ${#log_files[@]} -eq 0 ]]; then
    error "No installations log found at ~/.local/share/installed-appimages"
    info "Either you deleted all the installed applications using this tool,
 or logs where deleted by other methods!"
    exit 1
fi

# ----- Build an associative array mapping numbers to log files -----
declare -A app_names
declare -A app_logs
index=1
info "Please note that this tool removes the extracted data during installation only!
Cache, logs, or other data created during runtime might still present after 
uninstallation and need other tools or manual methods to be removed.
"
echo "Installed AppImages:"
for log in "${log_files[@]}"; do
    # Extract app name from the log file (first line "# App: ...")
    app_name=$(grep -m1 '^# App:' "$log" | sed 's/^# App: //')
    if [[ -z "$app_name" ]]; then
        # fallback: use filename without .log
        app_name=$(basename "$log" .log)
    fi
    app_names[$index]="$app_name"
    app_logs[$index]="$log"
    printf "  %3d) %s\n" "$index" "$app_name"
    ((index++))
done

# ----- Prompt user for choice -----
read -rp "Enter the number of the app to uninstall (or q to quit): " choice

if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    echo "Aborted."
    exit 0
fi

if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ -z "${app_names[$choice]:-}" ]]; then
    error "Invalid selection."
    exit 1
fi

selected_log="${app_logs[$choice]}"
selected_name="${app_names[$choice]}"

# ----- Parse the log file to get paths -----
target_dir=$(grep '^Directory:' "$selected_log" | sed 's/^Directory: //')
desktop_file=$(grep '^Desktop:' "$selected_log" | sed 's/^Desktop: //')
icon_path=$(grep '^Icon:' "$selected_log" | sed 's/^Icon: //')
# If icon_path is empty, that's fine.

# ----- Confirm deletion -----
echo
echo "You are about to uninstall: $selected_name"
echo "     Directory: $target_dir"
echo "  Desktop file: $desktop_file"
if [[ -n "$icon_path" ]]; then
    echo "          Icon: $icon_path"
fi
echo "      Log file: $selected_log"
read -rp "Proceed? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ----- Perform deletion (using sudo if needed) -----
# Determine if system‑wide installation (check if target_dir is under /opt)
if [[ "$target_dir" == /opt/* ]]; then
    SUDO="sudo"
else
    SUDO=""
fi

# Remove extracted directory
if [[ -n "$target_dir" && -d "$target_dir" ]]; then
    info "Removing $target_dir ..."
    $SUDO rm -rf "$target_dir"
else
    info "Directory $target_dir not found (already removed?)."
fi

# Remove desktop file
if [[ -n "$desktop_file" && -f "$desktop_file" ]]; then
    info "Removing $desktop_file ..."
    $SUDO rm -f "$desktop_file"
else
    info "Desktop file $desktop_file not found."
fi

# Remove icon file
if [[ -n "$icon_path" && -f "$icon_path" ]]; then
    info "Removing $icon_path ..."
    $SUDO rm -f "$icon_path"
else
    info "Icon $icon_path not found."
fi

# Remove the log file
info "Removing log file $selected_log ..."
rm -f "$selected_log"

# ----- Update caches -----
# Detect desktop environment (simplified)
DE="other"
if [[ "$XDG_CURRENT_DESKTOP" =~ .*(GNOME|Unity|XFCE|MATE|Cinnamon|LXQt|Pantheon).* ]]; then
    DE="gtk"
elif [[ "$XDG_CURRENT_DESKTOP" =~ .*(KDE|Plasma).* ]]; then
    DE="kde"
fi

# Update desktop database
if command -v update-desktop-database >/dev/null 2>&1; then
    # Determine desktop directory from the log's desktop file path
    desktop_dir=$(dirname "$desktop_file")
    if [[ -n "$desktop_dir" ]]; then
        if [[ "$desktop_dir" == /usr/share/applications ]]; then
            $SUDO update-desktop-database "$desktop_dir"
        else
            update-desktop-database "$desktop_dir"
        fi
    fi
fi

# Update icon caches
if [[ "$DE" == "gtk" ]]; then
    if [[ -d "/usr/share/icons/hicolor" ]] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
        $SUDO gtk-update-icon-cache -f /usr/share/icons/hicolor
    fi
elif [[ "$DE" == "kde" ]]; then
    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        info "Updating KDE menu cache (kbuildsycoca6)..."
        kbuildsycoca6 --noincremental
    elif command -v kbuildsycoca5 >/dev/null 2>&1; then
        info "Updating KDE menu cache (kbuildsycoca5)..."
        kbuildsycoca5 --noincremental
    fi
fi

success "Uninstalled $selected_name"
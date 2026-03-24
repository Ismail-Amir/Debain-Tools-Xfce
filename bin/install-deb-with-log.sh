#!/usr/bin/env bash
set -e

PKGFILE="$1"
LOGDIR="$HOME/.local/share/deb-install-logs"

mkdir -p "$LOGDIR"

# Canonical Debian package name
PKGNAME=$(dpkg-deb -f "$PKGFILE" Package)
LOG="$LOGDIR/${PKGNAME}.log"

echo "========================================" | tee -a "$LOG"
echo "=== Installation started: $(date)" | tee -a "$LOG"
echo "Package file: $PKGFILE" | tee -a "$LOG"
echo "Package name: $PKGNAME" | tee -a "$LOG"
echo | tee -a "$LOG"

dpkg-query -W -f='${Package}\n' | sort > /tmp/pkg-before.$$

sudo -S apt-get install "$PKGFILE" </dev/tty 2>&1 | tee -a "$LOG"

dpkg-query -W -f='${Package}\n' | sort > /tmp/pkg-after.$$

echo | tee -a "$LOG"
echo "=== Newly installed packages ===" | tee -a "$LOG"
comm -13 /tmp/pkg-before.$$ /tmp/pkg-after.$$ | tee -a "$LOG"

echo | tee -a "$LOG"
echo "=== Primary package ===" | tee -a "$LOG"
echo "$PKGNAME" | tee -a "$LOG"

rm -f /tmp/pkg-before.$$ /tmp/pkg-after.$$

echo | tee -a "$LOG"
echo "Log file: $LOG" | tee -a "$LOG"

#!/usr/bin/env bash

# Get the vcpkg binary location from environment
VCPKG_ROOT="${VCPKG_ROOT:-}"

if [ -z "$VCPKG_ROOT" ]; then
  echo "Error: VCPKG_ROOT environment variable is not set."
  echo "Please export VCPKG_ROOT to the vcpkg directory."
  read -p "Press Enter to exit..."
  exit 1
fi

# Change to the vcpkg directory
cd "$VCPKG_ROOT" || {
  echo "Failed to cd into $VCPKG_ROOT"
  read -p "Press Enter to exit..."
  exit 1
}

# Run updates
echo "Pulling latest vcpkg..."
git pull

echo -e "\nRunning vcpkg update..."
./vcpkg update

# Keep the terminal open
echo -e "\nDone. Press Enter to close."
read -p ""

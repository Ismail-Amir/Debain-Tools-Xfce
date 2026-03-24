#!/usr/bin/env bash
#
# C++ Project Initializer
# Creates a cross-platform C++ project with CMake, vcpkg, Clangd, and VS Code support.
# Usage: ./init_cpp_project.sh
#

set -o pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------
print_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_info() {
    echo -e "${BLUE}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

exit_with_error() {
    print_error "$1"
    exit 1
}

# ----------------------------------------------------------------------
# Prerequisite check
# ----------------------------------------------------------------------
print_info "Checking prerequisites..."

missing_tools=()
check_command cmake || missing_tools+=("cmake")
check_command g++   || missing_tools+=("g++ (GCC)")
check_command clangd || missing_tools+=("clangd")
if [ -z "$VCPKG_ROOT" ]; then
    missing_tools+=("VCPKG_ROOT environment variable not set")
fi

if [ ${#missing_tools[@]} -ne 0 ]; then
    print_error "The following prerequisites are missing:"
    for tool in "${missing_tools[@]}"; do
        echo "  - $tool"
    done
    exit 1
fi
print_success "All prerequisites satisfied."

# ----------------------------------------------------------------------
# User input
# ----------------------------------------------------------------------
print_info "Please provide the following information."

# Project name
while true; do
    read -p "Project name (alphanumeric, underscore, hyphen only): " project_name
    if [[ "$project_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        break
    else
        print_error "Invalid project name. Use only letters, numbers, underscore, or hyphen."
    fi
done

# Project location (default current directory)
read -p "Location (default: current directory): " location
if [ -z "$location" ]; then
    location="."
fi

# Normalize and create project directory
project_dir="$location/$project_name"
parent_dir=$(dirname "$project_dir")
if [ ! -d "$parent_dir" ]; then
    exit_with_error "Parent directory '$parent_dir' does not exist."
fi

if mkdir -p "$project_dir" 2>/dev/null; then
    print_success "Directory created: $project_dir"
else
    exit_with_error "Failed to create directory '$project_dir'. Check permissions."
fi

cd "$project_dir" || exit_with_error "Cannot enter project directory."

# Project type
echo "Select project type:"
echo "  1) executable"
echo "  2) static library"
echo "  3) shared library"
read -p "Choose (default: executable): " type_choice
case "$type_choice" in
    2) project_type="static" ;;
    3) project_type="shared" ;;
    *) project_type="executable" ;;  # also handles empty or invalid
esac
print_info "Project type: $project_type"

# C++ standard
read -p "C++ standard (17/20/23) [20]: " cpp_std
if [[ -z "$cpp_std" ]]; then
    cpp_std="20"
elif [[ ! "$cpp_std" =~ ^(17|20|23)$ ]]; then
    print_warning "Invalid standard. Using 20."
    cpp_std="20"
fi

# vcpkg integration
vcpkg_integration="no"
vcpkg_mode=""
deps=()
read -p "Integrate vcpkg? (y/n) [n]: " vcpkg_choice
if [[ "$vcpkg_choice" =~ ^[Yy]$ ]]; then
    vcpkg_integration="yes"
    echo "Select vcpkg mode:"
    echo "  1) classic (toolchain only)"
    echo "  2) manifest (with vcpkg.json)"
    read -p "Choose (default: manifest): " vcpkg_mode_choice
    if [[ -z "$vcpkg_mode_choice" || "$vcpkg_mode_choice" == "2" ]]; then
        vcpkg_mode="manifest"
    elif [[ "$vcpkg_mode_choice" == "1" ]]; then
        vcpkg_mode="classic"
    else
        print_warning "Invalid choice. Using manifest."
        vcpkg_mode="manifest"
    fi
    read -p "List vcpkg dependencies (comma-separated, e.g. fmt,spdlog): " vcpkg_deps
    # Split and trim
    IFS=',' read -ra deps_array <<< "$vcpkg_deps"
    for dep in "${deps_array[@]}"; do
        dep_trimmed=$(echo "$dep" | xargs)
        if [ -n "$dep_trimmed" ]; then
            deps+=("$dep_trimmed")
        fi
    done
fi

# Unit tests
read -p "Include a tests directory with a sample test? (y/n) [n]: " tests_choice
if [[ "$tests_choice" =~ ^[Yy]$ ]]; then
    include_tests="yes"
else
    include_tests="no"
fi

# Git repository
read -p "Initialize a git repository? (y/n) [y]: " git_init_choice
if [[ "$git_init_choice" =~ ^[Nn]$ ]]; then
    git_init="no"
else
    git_init="yes"
    if ! check_command git; then
        print_warning "git not found. Skipping repository initialization."
        git_init="no"
    fi
fi

# .gitignore
read -p "Add a .gitignore file? (y/n) [y]: " gitignore_choice
if [[ "$gitignore_choice" =~ ^[Nn]$ ]]; then
    add_gitignore="no"
else
    add_gitignore="yes"
fi

# README.md
read -p "Add a README.md file? (y/n) [y]: " readme_choice
if [[ "$readme_choice" =~ ^[Nn]$ ]]; then
    add_readme="no"
else
    add_readme="yes"
fi

# License file
read -p "Add a license file (MIT)? (y/n) [n]: " license_choice
if [[ "$license_choice" =~ ^[Yy]$ ]]; then
    add_license="yes"
else
    add_license="no"
fi

# VS Code settings
read -p "Add VS Code workspace settings (for clangd)? (y/n) [n]: " vscode_choice
if [[ "$vscode_choice" =~ ^[Yy]$ ]]; then
    add_vscode="yes"
else
    add_vscode="no"
fi

# .clang-format
read -p "Add a .clang-format file (LLVM style)? (y/n) [n]: " clangformat_choice
if [[ "$clangformat_choice" =~ ^[Yy]$ ]]; then
    add_clangformat="yes"
else
    add_clangformat="no"
fi

# ----------------------------------------------------------------------
# Create directory structure
# ----------------------------------------------------------------------
print_info "Creating directory structure..."

mkdir -p src
if [ "$project_type" != "executable" ]; then
    mkdir -p include
fi
if [ "$include_tests" = "yes" ] && [ "$project_type" != "executable" ]; then
    mkdir -p tests
fi
if [ "$add_vscode" = "yes" ]; then
    mkdir -p .vscode
fi

# ----------------------------------------------------------------------
# Generate source files
# ----------------------------------------------------------------------
print_info "Generating source files..."

# main.cpp or library files
if [ "$project_type" = "executable" ]; then
    # Create src/main.cpp
    cat > src/main.cpp <<EOF
#include <iostream>

int main() {
    std::cout << "Hello from $project_name!" << std::endl;
    return 0;
}
EOF
else
    # Library: create include/library.hpp and src/library.cpp
    lib_guard=$(echo "$project_name" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')_HPP
    cat > include/library.hpp <<EOF
#ifndef $lib_guard
#define $lib_guard

namespace $project_name {

void hello();

} // namespace $project_name

#endif // $lib_guard
EOF

    cat > src/library.cpp <<EOF
#include "library.hpp"
#include <iostream>

namespace $project_name {

void hello() {
    std::cout << "Hello from $project_name library!" << std::endl;
}

} // namespace $project_name
EOF
fi

# Sample test (if requested and project is library)
if [ "$include_tests" = "yes" ] && [ "$project_type" != "executable" ]; then
    cat > tests/test_library.cpp <<EOF
#include "library.hpp"

int main() {
    $project_name::hello();
    return 0;
}
EOF
fi

# ----------------------------------------------------------------------
# Generate CMakeLists.txt
# ----------------------------------------------------------------------
print_info "Generating CMakeLists.txt..."

# Build find_package lines and target link libraries (with actual newlines)
find_packages=""
target_libs=""
if [ "$vcpkg_integration" = "yes" ] && [ ${#deps[@]} -gt 0 ]; then
    for dep in "${deps[@]}"; do
        find_packages+="find_package($dep REQUIRED)"$'\n'
        # Assume target name is <dep>::<dep> (common for vcpkg ports)
        target_libs+="    $dep::$dep"$'\n'
    done
fi

# Determine target type and source files
if [ "$project_type" = "executable" ]; then
    target_cmd="add_executable(\${PROJECT_NAME} src/main.cpp)"
    # Only add target_link_libraries if there are dependencies
    if [ -n "$target_libs" ]; then
        link_cmd="target_link_libraries(\${PROJECT_NAME} PRIVATE"$'\n'"${target_libs})"
    else
        link_cmd=""
    fi
else
    target_cmd="add_library(\${PROJECT_NAME} $([ "$project_type" = "shared" ] && echo "SHARED" || echo "STATIC") src/library.cpp)"
    # For libraries, set include directories
    include_cmd="target_include_directories(\${PROJECT_NAME} PUBLIC \${CMAKE_CURRENT_SOURCE_DIR}/include)"
    if [ -n "$target_libs" ]; then
        link_cmd="target_link_libraries(\${PROJECT_NAME} PRIVATE"$'\n'"${target_libs})"
    else
        link_cmd=""
    fi
fi

# Build tests if requested
tests_cmd=""
if [ "$include_tests" = "yes" ]; then
    if [ "$project_type" = "executable" ]; then
        # For executable, just add a test that runs the executable
        tests_cmd="enable_testing()"$'\n'"add_test(NAME \${PROJECT_NAME}_test COMMAND \$<TARGET_FILE:\${PROJECT_NAME}>)"
    else
        # For library, create a test executable that links the library
        tests_cmd="add_executable(\${PROJECT_NAME}_test tests/test_library.cpp)"$'\n'
        tests_cmd+="target_link_libraries(\${PROJECT_NAME}_test PRIVATE \${PROJECT_NAME})"$'\n'
        tests_cmd+="enable_testing()"$'\n'
        tests_cmd+="add_test(NAME \${PROJECT_NAME}_test COMMAND \${PROJECT_NAME}_test)"
    fi
fi

# Write CMakeLists.txt
cat > CMakeLists.txt <<EOF
cmake_minimum_required(VERSION 3.15)
project($project_name VERSION 0.1.0 LANGUAGES CXX)

# C++ standard
set(CMAKE_CXX_STANDARD $cpp_std)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Find dependencies
$find_packages
# Main target
$target_cmd

$(if [ -n "$include_cmd" ]; then echo "$include_cmd"; fi)

$(if [ -n "$link_cmd" ]; then echo "$link_cmd"; fi)

# Tests
$tests_cmd

# ----------------------------------------------------------------------
# Clangd support: generate .clangd file pointing to current build dir
# ----------------------------------------------------------------------
$(if [ "$add_vscode" = "yes" ]; then
    echo "configure_file(\${CMAKE_CURRENT_SOURCE_DIR}/.clangd.in \${CMAKE_CURRENT_SOURCE_DIR}/.clangd @ONLY)"
fi)
EOF

# ----------------------------------------------------------------------
# Generate CMakePresets.json
# ----------------------------------------------------------------------
print_info "Generating CMakePresets.json..."

# Build base preset (hidden) with common cache variables
base_cache='{
      "name": "base",
      "hidden": true,
      "binaryDir": "${sourceDir}/build/${presetName}",
      "cacheVariables": {
        "CMAKE_CXX_STANDARD": "'"$cpp_std"'",
        "CMAKE_CXX_STANDARD_REQUIRED": "ON",
        "CMAKE_EXPORT_COMPILE_COMMANDS": "ON"'

if [ "$vcpkg_integration" = "yes" ]; then
    base_cache+=',
        "CMAKE_TOOLCHAIN_FILE": "$env{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"'
fi

base_cache+='
      }
    }'

# Generate configure presets for each OS and configuration (Debug/Release)
configure_presets="[$base_cache,"

for os in windows linux macos; do
    for config in Debug Release; do
        # Build condition for OS
        case $os in
            windows) condition='{ "type": "equals", "lhs": "${hostSystemName}", "rhs": "Windows" }' ;;
            linux)   condition='{ "type": "equals", "lhs": "${hostSystemName}", "rhs": "Linux" }' ;;
            macos)   condition='{ "type": "equals", "lhs": "${hostSystemName}", "rhs": "Darwin" }' ;;
        esac

        # Preset name: e.g., windows-debug, windows-release
        preset_name="${os}-$(echo $config | tr '[:upper:]' '[:lower:]')"

        configure_presets+='
  {
    "name": "'$preset_name'",
    "inherits": "base",
    "condition": '"$condition"',
    "cacheVariables": {
      "CMAKE_BUILD_TYPE": "'$config'"
    }
  },'
    done
done

# Remove trailing comma and close array
configure_presets="${configure_presets%,}]"

# Build presets: each just points to the corresponding configure preset
build_presets="["
for os in windows linux macos; do
    for config in Debug Release; do
        preset_name="${os}-$(echo $config | tr '[:upper:]' '[:lower:]')"
        build_presets+='
  {
    "name": "'$preset_name'",
    "configurePreset": "'$preset_name'"
  },'
    done
done
build_presets="${build_presets%,}]"

# Write final CMakePresets.json
cat > CMakePresets.json <<EOF
{
  "version": 3,
  "configurePresets": $configure_presets,
  "buildPresets": $build_presets
}
EOF

# ----------------------------------------------------------------------
# Generate vcpkg.json if manifest mode
# ----------------------------------------------------------------------
if [ "$vcpkg_integration" = "yes" ] && [ "$vcpkg_mode" = "manifest" ]; then
    print_info "Generating vcpkg.json..."
    if [ ${#deps[@]} -gt 0 ]; then
        # Build dependencies list
        deps_json=""
        for dep in "${deps[@]}"; do
            deps_json+='    { "name": "'$dep'" },'
        done
        deps_json="[${deps_json%,}]"
    else
        deps_json="[]"
    fi
    cat > vcpkg.json <<EOF
{
  "name": "$project_name",
  "version": "0.1.0",
  "dependencies": $deps_json
}
EOF
fi

# ----------------------------------------------------------------------
# Generate build scripts
# ----------------------------------------------------------------------
print_info "Generating build scripts..."

# build.sh (Unix)
cat > build.sh <<'EOF'
#!/bin/bash
# Detect OS
OS=$(uname -s)
case "$OS" in
    Linux*)     os=linux ;;
    Darwin*)    os=macos ;;
    *)          echo "Unsupported OS: $OS"; exit 1 ;;
esac

# Build Debug and Release
for config in debug release; do
    preset="${os}-${config}"
    echo "Configuring with preset: $preset"
    cmake --preset $preset
    echo "Building $config..."
    cmake --build --preset $preset
done
EOF
chmod +x build.sh

# build.bat (Windows)
cat > build.bat <<'EOF'
@echo off
set os=windows
for %%c in (debug release) do (
    echo Configuring with preset: %os%-%%c
    cmake --preset %os%-%%c
    echo Building %%c...
    cmake --build --preset %os%-%%c
)
EOF

# ----------------------------------------------------------------------
# Generate .gitignore
# ----------------------------------------------------------------------
if [ "$add_gitignore" = "yes" ]; then
    print_info "Generating .gitignore..."
    cat > .gitignore <<'EOF'
# Build directories
build/
*/build/
CMakeFiles/
CMakeCache.txt
cmake_install.cmake
Makefile
*.cmake

# Compiled files
*.o
*.obj
*.exe
*.dll
*.so
*.dylib
*.a
*.lib

# IDE
.vscode/
.idea/
*.swp
*.swo
*~

# vcpkg
vcpkg_installed/

# clangd generated file
.clangd
EOF
fi

# ----------------------------------------------------------------------
# Generate README.md
# ----------------------------------------------------------------------
if [ "$add_readme" = "yes" ]; then
    print_info "Generating README.md..."
    cat > README.md <<EOF
# $project_name

A C++ project generated with the C++ Project Initializer.

## Features
- CMake build system
- Cross-platform support (Windows, Linux, macOS)
- vcpkg for dependency management
- Clangd LSP support
- VS Code integration

## Building
### Linux / macOS
Run the build script:
\`\`\`
./build.sh
\`\`\`

### Windows
Run the batch file:
\`\`\`
build.bat
\`\`\`

Alternatively, use CMake directly:
\`\`\`
cmake --preset <preset>
cmake --build --preset <preset>
\`\`\`
Available presets: \`windows-debug\`, \`windows-release\`, \`linux-debug\`, \`linux-release\`, \`macos-debug\`, \`macos-release\`.

## Dependencies
$([ "$vcpkg_integration" = "yes" ] && echo "Managed via vcpkg." || echo "No external dependencies (vcpkg not used).")

## License
$([ "$add_license" = "yes" ] && echo "MIT License. See LICENSE file." || echo "No license specified.")
EOF
fi

# ----------------------------------------------------------------------
# Generate LICENSE (MIT)
# ----------------------------------------------------------------------
if [ "$add_license" = "yes" ]; then
    print_info "Generating LICENSE (MIT)..."
    year=$(date +%Y)
    cat > LICENSE <<EOF
MIT License

Copyright (c) $year $project_name

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
fi

# ----------------------------------------------------------------------
# Generate .clang-format
# ----------------------------------------------------------------------
if [ "$add_clangformat" = "yes" ]; then
    print_info "Generating .clang-format (LLVM style)..."
    cat > .clang-format <<'EOF'
BasedOnStyle: LLVM
IndentWidth: 4
UseTab: Never
BreakBeforeBraces: Allman
AllowShortFunctionsOnASingleLine: None
EOF
fi

# ----------------------------------------------------------------------
# Generate .clangd.in template (if VS Code settings enabled)
# ----------------------------------------------------------------------
if [ "$add_vscode" = "yes" ]; then
    print_info "Generating .clangd.in template..."
    cat > .clangd.in <<'EOF'
# This file is generated by CMake. Do not edit manually.
# It tells clangd where to find the compilation database for the current build.
CompileFlags:
  CompilationDatabase: @CMAKE_BINARY_DIR@
EOF
fi

# ----------------------------------------------------------------------
# Generate VS Code settings (including CMake Tools default target)
# ----------------------------------------------------------------------
if [ "$add_vscode" = "yes" ]; then
    print_info "Generating .vscode/settings.json..."
    cat > .vscode/settings.json <<EOF
{
    "C_Cpp.intelliSenseEngine": "disabled",
    "clangd.path": "clangd",
    "clangd.arguments": [
        "--background-index",
        "--clang-tidy"
    ],
    "files.associations": {
        "*.cpp": "cpp",
        "*.hpp": "cpp"
    },
    "cmake.defaultTarget": "$project_name",
    "cmake.buildBeforeRun": true
}
EOF
fi

# ----------------------------------------------------------------------
# Classic mode: check if dependencies are installed and offer to install
# ----------------------------------------------------------------------
if [ "$vcpkg_integration" = "yes" ] && [ "$vcpkg_mode" = "classic" ] && [ ${#deps[@]} -gt 0 ]; then
    print_info "Checking vcpkg classic mode dependencies..."
    # Locate vcpkg executable
    if [ -x "$VCPKG_ROOT/vcpkg" ]; then
        VCPKG_CMD="$VCPKG_ROOT/vcpkg"
    elif check_command vcpkg; then
        VCPKG_CMD="vcpkg"
    else
        print_warning "vcpkg executable not found. Cannot verify dependencies."
    fi

    if [ -n "$VCPKG_CMD" ]; then
        installed=$("$VCPKG_CMD" list | awk '{print $1}')
        missing_deps=()
        for dep in "${deps[@]}"; do
            if ! echo "$installed" | grep -q "^$dep"; then
                missing_deps+=("$dep")
            fi
        done
        if [ ${#missing_deps[@]} -gt 0 ]; then
            print_warning "The following vcpkg dependencies are not installed: ${missing_deps[*]}"
            read -p "Install them now? (y/n): " install_choice
            if [[ "$install_choice" =~ ^[Yy]$ ]]; then
                for dep in "${missing_deps[@]}"; do
                    print_info "Installing $dep..."
                    "$VCPKG_CMD" install "$dep" || print_error "Failed to install $dep"
                done
            else
                print_warning "Dependencies not installed. Build may fail."
            fi
        else
            print_success "All vcpkg dependencies are already installed."
        fi
    fi
fi

# ----------------------------------------------------------------------
# Git initialization
# ----------------------------------------------------------------------
if [ "$git_init" = "yes" ]; then
    print_info "Initializing git repository..."
    git init >/dev/null 2>&1
    git add . >/dev/null 2>&1
    git commit -m "Initial commit: C++ project structure" >/dev/null 2>&1
    print_success "Git repository initialized and initial commit created."
fi

# ----------------------------------------------------------------------
# Final message
# ----------------------------------------------------------------------
print_success "Project '$project_name' successfully created at: $project_dir"
print_info "Next steps:"
echo "  cd $project_dir"
if [ "$vcpkg_integration" = "yes" ] && [ "$vcpkg_mode" = "manifest" ] && [ ${#deps[@]} -gt 0 ]; then
    echo "  vcpkg install (if not using manifest mode automatically)"
fi
echo "  ./build.sh   (on Linux/macOS) or build.bat (on Windows)"
echo "  code .       (to open in VS Code)"

exit 0
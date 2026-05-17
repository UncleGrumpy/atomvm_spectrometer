#!/bin/sh
# generate_fun_data.sh
#
# Regenerates supported_functions.data with version information
# by scanning each AtomVM release tag and branch.
#
# Usage: ./generate_fun_data.sh <path-to-atomvm-dir>
#
# SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
# SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later

set -e

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <path-to-atomvm-dir>"
    exit 1
fi

ATOMVM_DIR="$1"
# POSIX-compatible way to get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPECTROMETER="${SCRIPT_DIR}/_build/default/bin/spectrometer"
TMP_BASE_DIR="$(mktemp -d)"
TMP_CACHE_DIR="${TMP_BASE_DIR}/spectrometer_version_cache"
mkdir -p "${TMP_CACHE_DIR}"

# Ensure cleanup on any exit (including early termination from set -e)
trap 'rm -rf "${TMP_BASE_DIR}"' EXIT

if [ ! -d "${ATOMVM_DIR}/.git" ]; then
    echo "Error: ${ATOMVM_DIR} does not appear to be a valid AtomVM git repository"
    exit 1
fi

echo "=== AtomVM Version Data Regeneration ==="
echo "Spectrometer:   ${SPECTROMETER}"
echo "AtomVM directory: ${ATOMVM_DIR}"
echo "Cache directory:  ${TMP_CACHE_DIR}"
echo ""

# Step 1: (re)build the escript
echo "=== Building atomvm_spectrometer escript ==="
cd "${SCRIPT_DIR}"
rebar3 escriptize
echo ""

# Step 2: cd into AtomVM local checkout directory
cd "${ATOMVM_DIR}"

# Step 3: Sync latest changes
echo "=== Syncing AtomVM repository ==="
git switch main --quiet 2>/dev/null || { echo "Warning: Could not switch to main"; }
git pull || echo "Warning: git pull failed, continuing anyway"
git fetch --tags || echo "Warning: git fetch --tags failed, continuing anyway"
echo ""

# Set output file path (cache directory created via mkdir -p)
OUTPUT_FILE="${TMP_CACHE_DIR}/supported_functions.data"

# Step 4: Scan main branch (stored as {unreleased, <<"main">>})
echo '=== Scanning branch: main (stored as {unreleased, <<"main">>}) ==='
if git checkout "main" --quiet 2>/dev/null; then
    "${SPECTROMETER}" update \
        --atomvm-dir "${ATOMVM_DIR}" \
        --branch "main" \
        --cache "${TMP_CACHE_DIR}" \
        --output "${OUTPUT_FILE}" \
        --force \
        --no-tests
    echo ""
else
    echo "Warning: Could not checkout main"
fi

# Step 5: Scan release-0.7 branch (stored as {unreleased, <<"0.7.x">>})
echo '=== Scanning branch: release-0.7 (stored as {unreleased, <<"0.7.x">>}) ==='
git fetch origin --quiet 2>/dev/null
if git show-ref --verify --quiet refs/remotes/origin/release-0.7; then
    if git checkout "release-0.7" --quiet 2>/dev/null; then
        "${SPECTROMETER}" update \
            --atomvm-dir "${ATOMVM_DIR}" \
            --branch "release-0.7" \
            --cache "${TMP_CACHE_DIR}" \
            --output "${OUTPUT_FILE}" \
            --force \
            --no-tests
        echo ""
    else
        echo "Warning: Failed to checkout release-0.7, skipping..."
    fi
else
    echo "Warning: Could not checkout release-0.7"
fi

# Step 6: Scan each tag (release is derived automatically from --tag)
# Using POSIX-compatible iteration over a simple list
for TAG in v0.7.0-alpha.1 v0.6.6 v0.6.5 v0.6.4 v0.6.3 v0.6.2 v0.6.1 v0.6.0 v0.5.0; do
    echo "=== Scanning tag: ${TAG} ==="
    git checkout "${TAG}" --quiet 2>/dev/null || { echo "Warning: Could not checkout ${TAG}"; continue; }
    "${SPECTROMETER}" update \
        --atomvm-dir "${ATOMVM_DIR}" \
        --tag "${TAG}" \
        --cache "${TMP_CACHE_DIR}" \
        --output "${OUTPUT_FILE}" \
        --force \
        --no-tests
    echo ""
done

# Step 7: Copy result to project priv/
DEST_FILE="${SCRIPT_DIR}/priv/supported_functions.data"
if [ ! -f "${OUTPUT_FILE}" ]; then
    echo "Error: Generated file not found at ${OUTPUT_FILE}"
    exit 1
fi
echo "=== Copying result to ${SCRIPT_DIR}/priv/supported_functions.data ==="
mkdir -p "${SCRIPT_DIR}/priv"
# POSIX-compatible check if files are the same (compare content)
if [ -f "${DEST_FILE}" ] && cmp -s "${OUTPUT_FILE}" "${DEST_FILE}"; then
    echo "Files are identical, no copy needed"
else
    if [ -f "${DEST_FILE}" ]; then
        BACKUP_TS="$(date +%Y%m%d%H%M)"
        echo "Backing up existing ${DEST_FILE} to ${DEST_FILE}.${BACKUP_TS}.bak"
        mv "${DEST_FILE}" "${DEST_FILE}.${BACKUP_TS}.bak"
    fi
    cp "${OUTPUT_FILE}" "${DEST_FILE}"
fi

echo ""
echo "Done! Version data written to ${DEST_FILE}"

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

# Step 5: Scan latest release branch (stored as {unreleased, <<"X.Y.x">>})
echo '=== Discovering latest release branch ==='
git fetch origin --quiet 2>/dev/null

# Find the most recent release-X.X branch from remote
LATEST_RELEASE_BRANCH=""
LATEST_RELEASE_VER=0

for BRANCH in $(git branch -r | grep -E 'origin/release-[0-9]+\.[0-9]+$' | sed 's|origin/||'); do
    # Extract version number: release-0.7 -> 0.7 -> convert to comparable integer
    VER=$(echo "${BRANCH}" | sed 's/^release-//')
    MAJOR=$(echo "${VER}" | cut -d. -f1)
    MINOR=$(echo "${VER}" | cut -d. -f2)
    VER_INT=$((MAJOR * 100 + MINOR))

    if [ "${VER_INT}" -gt "${LATEST_RELEASE_VER}" ]; then
        LATEST_RELEASE_VER="${VER_INT}"
        LATEST_RELEASE_BRANCH="${BRANCH}"
    fi
done

if [ -n "${LATEST_RELEASE_BRANCH}" ]; then
    VER_SUFFIX=$(echo "${LATEST_RELEASE_BRANCH}" | sed 's/^release-//')
    echo "=== Scanning branch: ${LATEST_RELEASE_BRANCH} (stored as {unreleased, <<${VER_SUFFIX}.x>>}) ==="
    if git show-ref --verify --quiet "refs/remotes/origin/${LATEST_RELEASE_BRANCH}"; then
        if git checkout "${LATEST_RELEASE_BRANCH}" --quiet 2>/dev/null; then
            "${SPECTROMETER}" update \
                --atomvm-dir "${ATOMVM_DIR}" \
                --branch "${LATEST_RELEASE_BRANCH}" \
                --cache "${TMP_CACHE_DIR}" \
                --output "${OUTPUT_FILE}" \
                --force \
                --no-tests
            echo ""
        else
            echo "Warning: Failed to checkout ${LATEST_RELEASE_BRANCH}, skipping..."
        fi
    else
        echo "Warning: Could not verify ${LATEST_RELEASE_BRANCH}"
    fi
else
    echo "Warning: No release-X.X branch found"
fi

# Step 6: Generate tag list from git
# Fetch latest tags and filter according to precedence rules
echo "=== Fetching and filtering git tags ==="
git fetch --tags --quiet 2>/dev/null || echo "Warning: git fetch --tags failed"

# Build list of tags to process:
# - Release tags (vX.Y.Z) are included
# - Pre-release tags are only included if no matching release tag exists
# - For unreleased versions, only the newest pre-release is kept per precedence
TMP_TAG_FILE="${TMP_CACHE_DIR}/tags_to_scan.txt"
: > "${TMP_TAG_FILE}"

# Store all tags, categorized
TMP_RELEASE_TAGS="${TMP_CACHE_DIR}/release_tags.txt"
TMP_PRERELEASE_TAGS="${TMP_CACHE_DIR}/prerelease_tags.txt"
: > "${TMP_RELEASE_TAGS}"
: > "${TMP_PRERELEASE_TAGS}"

# Extract tags and categorize them
# Pre-release tags contain -alpha, -beta, or -rc after the version
# Use git's native sorting for portability (git >= 2.0 supports --sort=v:refname)
# Fall back to no sort on older git versions (lexical order is acceptable)
if git tag -l --sort=v:refname "v*.*.*" 2>/dev/null | head -1 >/dev/null 2>&1; then
    TAGS=$(git tag -l --sort=v:refname "v*.*.*" 2>/dev/null)
else
    TAGS=$(git tag -l "v*.*.*" 2>/dev/null)
fi
for TAG in ${TAGS}; do
    case "${TAG}" in
        *[-_]alpha.*|*[-_]beta.*|*[-_]rc.*)
            # Pre-release tag (v1.2.3-alpha.1, v1.2.3-rc.2, etc.)
            echo "${TAG}" >> "${TMP_PRERELEASE_TAGS}"
            ;;
        v*.*.*)
            # Release tag (v1.2.3)
            echo "${TAG}" >> "${TMP_RELEASE_TAGS}"
            ;;
        *)
            echo "Fatal error, no release tags found"
            exit 1
            ;;
    esac
done

# Process tags: for each version, prefer release over pre-release
# Build a list of versions we've seen
TMP_VERSIONS="${TMP_CACHE_DIR}/versions.txt"
: > "${TMP_VERSIONS}"

# First pass: collect all base versions from release tags
while IFS= read -r REL_TAG; do
    # Extract base version: v1.2.3 -> 1.2.3
    BASE_VER=$(echo "${REL_TAG}" | sed 's/^v//')
    echo "${BASE_VER}" >> "${TMP_VERSIONS}"
    echo "${REL_TAG}" >> "${TMP_TAG_FILE}"
done < "${TMP_RELEASE_TAGS}"

# Second pass: process pre-release tags for unreleased versions
# Group by version base, keep only the newest per group based on precedence
# Track processed version bases to avoid duplicates
PROCESSED_BASES="${TMP_CACHE_DIR}/processed_bases.txt"
: > "${PROCESSED_BASES}"

# Read prerelease tags into a variable to avoid shellcheck SC2094 warning
PRE_TAGS_LIST=$(cat "${TMP_PRERELEASE_TAGS}")

for PRE_TAG in ${PRE_TAGS_LIST}; do
    # Extract version base from pre-release: v1.2.3-alpha.1 -> v1.2.3
    VERSION_BASE=$(echo "${PRE_TAG}" | sed -E 's/^(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/')

    # Skip if a release tag exists for this version
    if grep -qx "${VERSION_BASE#v}" "${TMP_VERSIONS}" 2>/dev/null; then
        continue
    fi

    # Skip if we've already processed this version base
    if grep -qx "${VERSION_BASE}" "${PROCESSED_BASES}" 2>/dev/null; then
        continue
    fi

    # Mark this version base as processed
    echo "${VERSION_BASE}" >> "${PROCESSED_BASES}"

    # Get all pre-release tags for this version base
    PRE_TAGS_FOR_VER=$(echo "${PRE_TAGS_LIST}" | grep "^${VERSION_BASE}-" 2>/dev/null || true)

    if [ -z "${PRE_TAGS_FOR_VER}" ]; then
        continue
    fi

    # Find the best (newest) pre-release per version base based on precedence
    # Precedence: rc > beta > alpha
    # Within each type, pick the highest number
    BEST_RC=""
    BEST_BETA=""
    BEST_ALPHA=""
    RC_NUM=0
    BETA_NUM=0
    ALPHA_NUM=0

    for PT in ${PRE_TAGS_FOR_VER}; do
        PR_TYPE=$(echo "${PT}" | sed -E 's/.*-(alpha|beta|rc)\.[0-9]+/\1/')
        PR_NUM=$(echo "${PT}" | sed -E 's/.*-(alpha|beta|rc)\.([0-9]+)/\2/')

        case "${PR_TYPE}" in
            rc)
                if [ "${PR_NUM}" -gt "${RC_NUM}" ]; then
                    RC_NUM="${PR_NUM}"
                    BEST_RC="${PT}"
                fi
                ;;
            beta)
                if [ "${PR_NUM}" -gt "${BETA_NUM}" ]; then
                    BETA_NUM="${PR_NUM}"
                    BEST_BETA="${PT}"
                fi
                ;;
            alpha)
                if [ "${PR_NUM}" -gt "${ALPHA_NUM}" ]; then
                    ALPHA_NUM="${PR_NUM}"
                    BEST_ALPHA="${PT}"
                fi
                ;;
            *)
                echo "Ignoring tag: ${PR_TYPE}"
                ;;
        esac
    done

    # Select best pre-release: rc > beta > alpha
    if [ -n "${BEST_RC}" ]; then
        echo "${BEST_RC}" >> "${TMP_TAG_FILE}"
    elif [ -n "${BEST_BETA}" ]; then
        echo "${BEST_BETA}" >> "${TMP_TAG_FILE}"
    elif [ -n "${BEST_ALPHA}" ]; then
        echo "${BEST_ALPHA}" >> "${TMP_TAG_FILE}"
    fi
done

# Sort tags by version (newest first for processing)
# Use git's sort if available, otherwise fall back to lexical sort
if git tag -l --sort=v:refname "v*.*.*" 2>/dev/null | head -1 >/dev/null 2>&1; then
    sort -rV "${TMP_TAG_FILE}" > "${TMP_TAG_FILE}.sorted" 2>/dev/null || sort -r "${TMP_TAG_FILE}" > "${TMP_TAG_FILE}.sorted"
else
    # Lexical sort is acceptable for final ordering
    sort -r "${TMP_TAG_FILE}" > "${TMP_TAG_FILE}.sorted"
fi
mv "${TMP_TAG_FILE}.sorted" "${TMP_TAG_FILE}"

echo "Tags to scan:"
cat "${TMP_TAG_FILE}"
echo ""

# Step 7: Scan each tag (release is derived automatically from --tag)
while IFS= read -r TAG; do
    [ -z "${TAG}" ] && continue
    echo "=== Scanning tag: ${TAG} ==="
    git checkout "${TAG}" --quiet 2>/dev/null || { echo "Warning: Could not checkout ${TAG}"; continue; }
    if ! "${SPECTROMETER}" update \
        --atomvm-dir "${ATOMVM_DIR}" \
        --tag "${TAG}" \
        --cache "${TMP_CACHE_DIR}" \
        --output "${OUTPUT_FILE}" \
        --force \
        --no-tests; then
        echo "Warning: Failed to scan tag ${TAG}, continuing..."
    fi
    echo ""
done < "${TMP_TAG_FILE}"

# Step 8: Copy result to project priv/
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

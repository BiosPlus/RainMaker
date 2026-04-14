#!/usr/bin/env bash
set -euo pipefail

echo "Checking for package updates..."

# Retry wrapper: up to 3 attempts with exponential backoff (2s, 4s)
curl_with_retry() {
  local url="$1"
  shift
  local attempt=1
  local max_attempts=3
  local wait=2
  while [ "${attempt}" -le "${max_attempts}" ]; do
    if curl -fsSL "$@" "${url}"; then
      return 0
    fi
    if [ "${attempt}" -lt "${max_attempts}" ]; then
      echo "WARNING: curl failed for ${url} (attempt ${attempt}/${max_attempts}). Retrying in ${wait}s..." >&2
      sleep "${wait}"
      wait=$(( wait * 2 ))
    fi
    attempt=$(( attempt + 1 ))
  done
  echo "ERROR: curl failed for ${url} after ${max_attempts} attempts." >&2
  return 1
}

UPDATES="[]"
PACKAGE_FILES=( packages/*.yaml )
PACKAGE_COUNT=${#PACKAGE_FILES[@]}

for PKG_FILE in "${PACKAGE_FILES[@]}"; do
  NAME=$(yq eval '.name' "${PKG_FILE}")
  SOURCE_TYPE=$(yq eval '.source_type' "${PKG_FILE}")
  SOURCE=$(yq eval '.source' "${PKG_FILE}")
  CURRENT_VERSION=$(yq eval '.version' "${PKG_FILE}")

  echo ""
  echo "Checking: ${NAME}"
  echo "  Current version: ${CURRENT_VERSION}"

  # Only check Homebrew packages
  if [ "${SOURCE_TYPE}" = "brew" ]; then
    # Fetch latest version and URL info from Homebrew API
    BREW_DATA=$(curl_with_retry "https://formulae.brew.sh/api/cask/${SOURCE}.json")
    LATEST_VERSION=$(echo "${BREW_DATA}" | jq -r '.version')
    VERIFIED_URL=$(echo "${BREW_DATA}" | jq -r '.url_specs.verified // empty')
    DOWNLOAD_URL=$(echo "${BREW_DATA}" | jq -r '.url // empty')
    SHA256=$(echo "${BREW_DATA}" | jq -r '.sha256 // "none"')
    HOMEPAGE=$(echo "${BREW_DATA}" | jq -r '.homepage // empty')

    # Get current timestamp
    TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
    UNIX_TIMESTAMP=$(date +%s)

    if [ -z "${LATEST_VERSION}" ] || [ "${LATEST_VERSION}" = "null" ]; then
      echo "  ⚠️  Could not fetch version from Homebrew API"
      continue
    fi

    echo "  Latest version: ${LATEST_VERSION}"
    echo "  Download URL: ${DOWNLOAD_URL}"
    echo "  SHA256: ${SHA256}"

    # Check if URL is verified (indicates vendor-hosted, trusted source)
    URL_VERIFIED="false"
    if [ -n "${VERIFIED_URL}" ] && [ -n "${DOWNLOAD_URL}" ]; then
      if echo "${DOWNLOAD_URL}" | grep -q "${VERIFIED_URL}"; then
        URL_VERIFIED="true"
        echo "  ✓ Download URL verified by vendor"
      fi
    fi

    # Compare versions using sort -V for semantic versioning
    if [ "${LATEST_VERSION}" != "${CURRENT_VERSION}" ]; then
      # Check if latest is actually newer
      NEWER=$(printf '%s\n%s\n' "${CURRENT_VERSION}" "${LATEST_VERSION}" | sort -V | tail -n1)

      if [ "${NEWER}" = "${LATEST_VERSION}" ] && [ "${LATEST_VERSION}" != "${CURRENT_VERSION}" ]; then
        echo "  🆕 Update available!"

        # Add to matrix
        UPDATE_JSON=$(jq -n \
          --arg name "${NAME}" \
          --arg source "${SOURCE}" \
          --arg current "${CURRENT_VERSION}" \
          --arg latest "${LATEST_VERSION}" \
          --arg verified "${URL_VERIFIED}" \
          --arg download_url "${DOWNLOAD_URL}" \
          --arg sha256 "${SHA256}" \
          --arg homepage "${HOMEPAGE}" \
          --arg timestamp "${TIMESTAMP}" \
          --arg unix_timestamp "${UNIX_TIMESTAMP}" \
          --arg verified_domain "${VERIFIED_URL}" \
          '{name: $name, source: $source, current_version: $current, latest_version: $latest, url_verified: $verified, download_url: $download_url, sha256: $sha256, homepage: $homepage, timestamp: $timestamp, unix_timestamp: $unix_timestamp, verified_domain: $verified_domain}')

        UPDATES=$(echo "${UPDATES}" | jq --argjson update "${UPDATE_JSON}" '. += [$update]')
      else
        echo "  ⏭️  Version different but not newer (${CURRENT_VERSION} vs ${LATEST_VERSION})"
      fi
    else
      echo "  ✓ Up to date"
    fi
  else
    echo "  ⏭️  Skipping (not a Homebrew package)"
  fi
done

# Check if any updates found
UPDATE_COUNT=$(echo "${UPDATES}" | jq 'length')

if [ "${UPDATE_COUNT}" -eq 0 ]; then
  echo ""
  echo "All packages are up to date!"
  echo "matrix={\"include\":[]}" >> $GITHUB_OUTPUT
  echo "has_updates=false" >> $GITHUB_OUTPUT

  # Write summary
  echo "## 📦 Package Version Check" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "✅ **All ${PACKAGE_COUNT} package(s) are up to date!**" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "No updates available at this time." >> $GITHUB_STEP_SUMMARY
else
  echo ""
  echo "================================================"
  echo "Found ${UPDATE_COUNT} package update(s)"
  echo "================================================"
  MATRIX=$(echo "${UPDATES}" | jq -c '{include: .}')
  echo "matrix=${MATRIX}" >> $GITHUB_OUTPUT
  echo "has_updates=true" >> $GITHUB_OUTPUT
  echo "${MATRIX}" | jq .

  # Write summary
  echo "## 📦 Package Version Check" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "🆕 **Found ${UPDATE_COUNT} package update(s)**" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "| Package | Current Version | New Version | Verified URL |" >> $GITHUB_STEP_SUMMARY
  echo "|---------|----------------|-------------|--------------|" >> $GITHUB_STEP_SUMMARY

  # Add each update to summary table
  for row in $(echo "${UPDATES}" | jq -r '.[] | @base64'); do
    _jq() {
      echo "${row}" | base64 --decode | jq -r "${1}"
    }
    PKG_NAME=$(_jq '.name')
    PKG_CURRENT=$(_jq '.current_version')
    PKG_LATEST=$(_jq '.latest_version')
    PKG_VERIFIED=$(_jq '.url_verified')

    if [ "${PKG_VERIFIED}" = "true" ]; then
      VERIFIED_ICON="✅"
    else
      VERIFIED_ICON="⚠️"
    fi

    echo "| ${PKG_NAME} | \`${PKG_CURRENT}\` | \`${PKG_LATEST}\` | ${VERIFIED_ICON} |" >> $GITHUB_STEP_SUMMARY
  done

  echo "" >> $GITHUB_STEP_SUMMARY
  echo "**Legend:**" >> $GITHUB_STEP_SUMMARY
  echo "- ✅ Download URL is verified by vendor (low risk)" >> $GITHUB_STEP_SUMMARY
  echo "- ⚠️ Download URL is not verified (requires review)" >> $GITHUB_STEP_SUMMARY
fi

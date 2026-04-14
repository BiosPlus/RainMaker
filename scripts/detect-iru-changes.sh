#!/usr/bin/env bash
set -euo pipefail

# Detects which packages had their version bumped in the latest commit AND have
# an iru_library_item_id configured. Outputs a matrix for the iru-upload job.
#
# Required env vars (set by workflow):
#   IRU_API_KEY  — presence check only; if empty, skips all packages

# ---------------------------------------------------------------------------
# Retry wrapper (same as detect-updates.sh)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Guard: IRU_API_KEY must be configured
# ---------------------------------------------------------------------------
if [ -z "${IRU_API_KEY:-}" ]; then
  echo "WARNING: IRU_API_KEY secret is not configured."
  echo "Add IRU_API_KEY to repository secrets (Settings > Secrets and variables > Actions)."
  echo "matrix={\"include\":[]}" >> "${GITHUB_OUTPUT}"
  echo "has_iru_packages=false" >> "${GITHUB_OUTPUT}"

  echo "## Iru Package Sync" >> "${GITHUB_STEP_SUMMARY}"
  echo "" >> "${GITHUB_STEP_SUMMARY}"
  echo "⚠️ **Skipped — IRU_API_KEY secret is not configured.**" >> "${GITHUB_STEP_SUMMARY}"
  echo "" >> "${GITHUB_STEP_SUMMARY}"
  echo "Add \`IRU_API_KEY\` and \`IRU_TENANT_URL\` to repository secrets to enable Iru syncing." >> "${GITHUB_STEP_SUMMARY}"
  exit 0
fi

echo "Detecting packages changed in this commit..."

CANDIDATES="[]"

for PKG_FILE in packages/*.yaml; do
  # Parse the entire file once, then extract fields with jq
  PKG_JSON=$(yq eval -o=json '.' "${PKG_FILE}")

  NAME=$(echo "${PKG_JSON}" | jq -r '.name')
  SOURCE=$(echo "${PKG_JSON}" | jq -r '.source')
  SOURCE_TYPE=$(echo "${PKG_JSON}" | jq -r '.source_type')
  FILE_TYPE=$(echo "${PKG_JSON}" | jq -r '.file_type')
  NEW_VERSION=$(echo "${PKG_JSON}" | jq -r '.version')
  IRU_ID=$(echo "${PKG_JSON}" | jq -r '.iru_library_item_id // ""')
  INSTALL_ENFORCEMENT=$(echo "${PKG_JSON}" | jq -r '.install_enforcement // ""')
  UNZIP_LOCATION=$(echo "${PKG_JSON}" | jq -r '.unzip_location // ""')
  AUDIT_SCRIPT=$(echo "${PKG_JSON}" | jq -r '.audit_script // ""')
  PREINSTALL_SCRIPT=$(echo "${PKG_JSON}" | jq -r '.preinstall_script // ""')
  POSTINSTALL_SCRIPT=$(echo "${PKG_JSON}" | jq -r '.postinstall_script // ""')
  SHOW_IN_SELF_SERVICE=$(echo "${PKG_JSON}" | jq -r '.show_in_self_service // ""')
  SELF_SERVICE_CATEGORY_ID=$(echo "${PKG_JSON}" | jq -r '.self_service_category_id // ""')
  SELF_SERVICE_RECOMMENDED=$(echo "${PKG_JSON}" | jq -r '.self_service_recommended // ""')
  ACTIVE=$(echo "${PKG_JSON}" | jq -r '.active // ""')
  RESTART=$(echo "${PKG_JSON}" | jq -r '.restart // ""')

  # Skip packages without an Iru library item ID
  if [ -z "${IRU_ID}" ]; then
    echo "  Skipping ${NAME} — no iru_library_item_id configured"
    continue
  fi

  # Skip non-brew packages (only source type currently supported)
  if [ "${SOURCE_TYPE}" != "brew" ]; then
    echo "  Skipping ${NAME} — source_type '${SOURCE_TYPE}' is not supported"
    continue
  fi

  # Compare version in HEAD vs HEAD~1 for this specific file
  OLD_VERSION=$(git show "HEAD~1:${PKG_FILE}" 2>/dev/null | yq eval '.version // ""' - 2>/dev/null || true)

  if [ -z "${OLD_VERSION}" ]; then
    echo "  ${NAME}: could not read previous version (new package?), treating as changed"
  fi

  if [ "${OLD_VERSION}" = "${NEW_VERSION}" ]; then
    echo "  ${NAME}: version unchanged (${NEW_VERSION}) — skipping"
    continue
  fi

  echo ""
  echo "  ${NAME}: version changed ${OLD_VERSION} → ${NEW_VERSION}"

  # Fetch current download URL and SHA256 from Homebrew API
  echo "  Fetching Homebrew metadata for ${SOURCE}..."
  BREW_DATA=$(curl_with_retry "https://formulae.brew.sh/api/cask/${SOURCE}.json")
  DOWNLOAD_URL=$(echo "${BREW_DATA}" | jq -r '.url // empty')
  SHA256=$(echo "${BREW_DATA}" | jq -r '.sha256 // "none"')

  if [ -z "${DOWNLOAD_URL}" ]; then
    echo "  WARNING: Could not fetch download URL for ${NAME} — skipping"
    continue
  fi

  echo "  Download URL: ${DOWNLOAD_URL}"
  echo "  SHA256: ${SHA256}"

  ENTRY=$(jq -n \
    --arg name                  "${NAME}" \
    --arg source                "${SOURCE}" \
    --arg version               "${NEW_VERSION}" \
    --arg file_type             "${FILE_TYPE}" \
    --arg download_url          "${DOWNLOAD_URL}" \
    --arg sha256                "${SHA256}" \
    --arg iru_library_item_id   "${IRU_ID}" \
    --arg install_enforcement   "${INSTALL_ENFORCEMENT}" \
    --arg unzip_location        "${UNZIP_LOCATION}" \
    --arg audit_script          "${AUDIT_SCRIPT}" \
    --arg preinstall_script     "${PREINSTALL_SCRIPT}" \
    --arg postinstall_script    "${POSTINSTALL_SCRIPT}" \
    --arg show_in_self_service  "${SHOW_IN_SELF_SERVICE}" \
    --arg self_service_category_id "${SELF_SERVICE_CATEGORY_ID}" \
    --arg self_service_recommended "${SELF_SERVICE_RECOMMENDED}" \
    --arg active                "${ACTIVE}" \
    --arg restart               "${RESTART}" \
    '{
      name: $name,
      source: $source,
      version: $version,
      file_type: $file_type,
      download_url: $download_url,
      sha256: $sha256,
      iru_library_item_id: $iru_library_item_id,
      install_enforcement: $install_enforcement,
      unzip_location: $unzip_location,
      audit_script: $audit_script,
      preinstall_script: $preinstall_script,
      postinstall_script: $postinstall_script,
      show_in_self_service: $show_in_self_service,
      self_service_category_id: $self_service_category_id,
      self_service_recommended: $self_service_recommended,
      active: $active,
      restart: $restart
    }')

  CANDIDATES=$(echo "${CANDIDATES}" | jq --argjson entry "${ENTRY}" '. += [$entry]')
done

CANDIDATE_COUNT=$(echo "${CANDIDATES}" | jq 'length')

if [ "${CANDIDATE_COUNT}" -eq 0 ]; then
  echo ""
  echo "No packages qualify for Iru sync."
  echo "matrix={\"include\":[]}" >> "${GITHUB_OUTPUT}"
  echo "has_iru_packages=false" >> "${GITHUB_OUTPUT}"

  echo "## Iru Package Sync" >> "${GITHUB_STEP_SUMMARY}"
  echo "" >> "${GITHUB_STEP_SUMMARY}"
  echo "ℹ️ No packages with version changes and a configured \`iru_library_item_id\` were found." >> "${GITHUB_STEP_SUMMARY}"
else
  echo ""
  echo "Found ${CANDIDATE_COUNT} package(s) to sync to Iru:"
  MATRIX=$(echo "${CANDIDATES}" | jq -c '{include: .}')
  echo "${MATRIX}" | jq .
  echo "matrix=${MATRIX}" >> "${GITHUB_OUTPUT}"
  echo "has_iru_packages=true" >> "${GITHUB_OUTPUT}"

  echo "## Iru Package Sync" >> "${GITHUB_STEP_SUMMARY}"
  echo "" >> "${GITHUB_STEP_SUMMARY}"
  echo "📦 **${CANDIDATE_COUNT} package(s) queued for Iru sync**" >> "${GITHUB_STEP_SUMMARY}"
  echo "" >> "${GITHUB_STEP_SUMMARY}"
  echo "| Package | Version | Iru Item ID |" >> "${GITHUB_STEP_SUMMARY}"
  echo "|---------|---------|-------------|" >> "${GITHUB_STEP_SUMMARY}"

  for row in $(echo "${CANDIDATES}" | jq -r '.[] | @base64'); do
    _jq() {
      echo "${row}" | base64 --decode | jq -r "${1}"
    }
    echo "| $(_jq '.name') | \`$(_jq '.version')\` | \`$(_jq '.iru_library_item_id')\` |" >> "${GITHUB_STEP_SUMMARY}"
  done
fi

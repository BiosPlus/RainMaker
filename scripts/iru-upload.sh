#!/usr/bin/env bash
set -euo pipefail

# Downloads a brew package and uploads it to an Iru Custom App library item.
#
# Required env vars (set by workflow):
#   PACKAGE_NAME           — human-readable package name
#   MATRIX_SOURCE          — Homebrew cask name (used for artifact file naming)
#   DOWNLOAD_URL           — direct download URL
#   EXPECTED_SHA256        — SHA256 from Homebrew API
#   PACKAGE_VERSION        — new version string
#   FILE_TYPE              — dmg, pkg, or zip
#   IRU_LIBRARY_ITEM_ID    — UUID of the Iru Custom App library item
#   IRU_API_KEY            — Iru API token
#   IRU_TENANT_URL         — Iru tenant base URL (e.g. "example.api.eu.kandji.io")

# ---------------------------------------------------------------------------
# Retry wrappers (verbatim from virustotal-scan.sh)
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

curl_with_retry_silent() {
  local url="$1"
  shift
  local attempt=1
  local max_attempts=3
  local wait=2
  while [ "${attempt}" -le "${max_attempts}" ]; do
    if curl -s "$@" "${url}"; then
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
# Validate required env vars
# ---------------------------------------------------------------------------
REQUIRED_VARS="PACKAGE_NAME MATRIX_SOURCE DOWNLOAD_URL EXPECTED_SHA256 PACKAGE_VERSION FILE_TYPE IRU_LIBRARY_ITEM_ID IRU_API_KEY IRU_TENANT_URL"
for VAR in ${REQUIRED_VARS}; do
  if [ -z "${!VAR:-}" ]; then
    echo "ERROR: Required environment variable '${VAR}' is not set." >&2
    exit 1
  fi
done

IRU_BASE_URL="https://${IRU_TENANT_URL}"

# Derive Iru install_type from file extension
case "${FILE_TYPE}" in
  pkg) INSTALL_TYPE="package" ;;
  zip) INSTALL_TYPE="zip" ;;
  dmg) INSTALL_TYPE="image" ;;
  *)
    echo "WARNING: Unknown file_type '${FILE_TYPE}', leaving install_type unset"
    INSTALL_TYPE=""
    ;;
esac

# Track upload status — set to "failed" early; overwritten to "success" only after all phases
UPLOAD_STATUS="failed"
SHA256_VERIFIED="unknown"
ACTUAL_SHA256=""
UPLOAD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ---------------------------------------------------------------------------
# Download package
# ---------------------------------------------------------------------------
echo "Downloading ${PACKAGE_NAME} version ${PACKAGE_VERSION}"
echo "URL: ${DOWNLOAD_URL}"

mkdir -p downloads

FILENAME=$(basename "${DOWNLOAD_URL}" | cut -d'?' -f1)
FILEPATH="downloads/${FILENAME}"

curl_with_retry "${DOWNLOAD_URL}" --max-time 120 -o "${FILEPATH}"

FILE_SIZE=$(wc -c < "${FILEPATH}")
ACTUAL_SHA256=$(shasum -a 256 "${FILEPATH}" | cut -d' ' -f1)

echo "Downloaded: ${FILEPATH}"
echo "File size: ${FILE_SIZE} bytes"
echo "SHA256: ${ACTUAL_SHA256}"

if [ "${EXPECTED_SHA256}" != "none" ] && [ "${EXPECTED_SHA256}" != "no_check" ] && [ -n "${EXPECTED_SHA256}" ]; then
  if [ "${ACTUAL_SHA256}" = "${EXPECTED_SHA256}" ]; then
    echo "✅ SHA256 verification passed"
    SHA256_VERIFIED="true"
  else
    echo "❌ SHA256 verification FAILED — aborting upload"
    echo "Expected: ${EXPECTED_SHA256}"
    echo "Got:      ${ACTUAL_SHA256}"
    SHA256_VERIFIED="false"

    mkdir -p iru-results
    jq -n \
      --arg name "${PACKAGE_NAME}" \
      --arg source "${MATRIX_SOURCE}" \
      --arg version "${PACKAGE_VERSION}" \
      --arg sha256_verified "${SHA256_VERIFIED}" \
      --arg actual_sha256 "${ACTUAL_SHA256}" \
      --arg iru_item_id "${IRU_LIBRARY_ITEM_ID}" \
      --arg upload_status "${UPLOAD_STATUS}" \
      --arg upload_timestamp "${UPLOAD_TIMESTAMP}" \
      '{name: $name, source: $source, version: $version, sha256_verified: $sha256_verified, actual_sha256: $actual_sha256, iru_item_id: $iru_item_id, upload_status: $upload_status, upload_timestamp: $upload_timestamp}' \
      > "iru-results/${MATRIX_SOURCE}.json"

    exit 1
  fi
else
  echo "⚠️ No SHA256 hash available for verification"
fi

# ---------------------------------------------------------------------------
# Phase 1 — Pre-flight: verify library item exists in Iru
# ---------------------------------------------------------------------------
echo ""
echo "Verifying Iru library item ${IRU_LIBRARY_ITEM_ID}..."

ITEM_RESPONSE=$(curl_with_retry_silent "${IRU_BASE_URL}/api/v1/library/custom-apps/${IRU_LIBRARY_ITEM_ID}" \
  --request GET \
  --header "Authorization: Bearer ${IRU_API_KEY}" \
  --header "Content-Type: application/json")

ITEM_ID=$(echo "${ITEM_RESPONSE}" | jq -r '.id // empty' 2>/dev/null || true)

if [ -z "${ITEM_ID}" ]; then
  echo "❌ Iru library item not found: ${IRU_LIBRARY_ITEM_ID}"
  echo "Create the Custom App library item in the Iru web UI first,"
  echo "then add its UUID as 'iru_library_item_id' in packages.yaml."
  echo ""
  echo "API response:"
  echo "${ITEM_RESPONSE}" | jq . 2>/dev/null || echo "${ITEM_RESPONSE}"

  mkdir -p iru-results
  jq -n \
    --arg name "${PACKAGE_NAME}" \
    --arg source "${MATRIX_SOURCE}" \
    --arg version "${PACKAGE_VERSION}" \
    --arg sha256_verified "${SHA256_VERIFIED}" \
    --arg actual_sha256 "${ACTUAL_SHA256}" \
    --arg iru_item_id "${IRU_LIBRARY_ITEM_ID}" \
    --arg upload_status "${UPLOAD_STATUS}" \
    --arg upload_timestamp "${UPLOAD_TIMESTAMP}" \
    '{name: $name, source: $source, version: $version, sha256_verified: $sha256_verified, actual_sha256: $actual_sha256, iru_item_id: $iru_item_id, upload_status: $upload_status, upload_timestamp: $upload_timestamp}' \
    > "iru-results/${MATRIX_SOURCE}.json"

  exit 1
fi

ITEM_NAME=$(echo "${ITEM_RESPONSE}" | jq -r '.name // "unknown"')
echo "✅ Found library item: ${ITEM_NAME} (${ITEM_ID})"

# ---------------------------------------------------------------------------
# Phase 2 — Get S3 signed upload URL from Iru
# ---------------------------------------------------------------------------
echo ""
echo "Requesting S3 signed upload URL..."

UPLOAD_REQUEST_BODY=$(jq -n --arg name "${FILENAME}" '{"name": $name}')

UPLOAD_URL_RESPONSE=$(curl_with_retry_silent "${IRU_BASE_URL}/api/v1/library/custom-apps/upload" \
  --request POST \
  --header "Authorization: Bearer ${IRU_API_KEY}" \
  --header "Content-Type: application/json" \
  --data "${UPLOAD_REQUEST_BODY}")

SIGNED_URL=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.post_url // empty' 2>/dev/null || true)
S3_KEY=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.post_data.key // empty' 2>/dev/null || true)
AMZ_ALGORITHM=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.post_data["x-amz-algorithm"] // empty' 2>/dev/null || true)
AMZ_CREDENTIAL=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.post_data["x-amz-credential"] // empty' 2>/dev/null || true)
AMZ_DATE=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.post_data["x-amz-date"] // empty' 2>/dev/null || true)
AMZ_SECURITY_TOKEN=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.post_data["x-amz-security-token"] // empty' 2>/dev/null || true)
POLICY=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.post_data.policy // empty' 2>/dev/null || true)
AMZ_SIGNATURE=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.post_data["x-amz-signature"] // empty' 2>/dev/null || true)

if [ -z "${SIGNED_URL}" ]; then
  echo "❌ Failed to get S3 signed upload URL from Iru"
  echo "API response:"
  echo "${UPLOAD_URL_RESPONSE}" | jq . 2>/dev/null || echo "${UPLOAD_URL_RESPONSE}"

  mkdir -p iru-results
  jq -n \
    --arg name "${PACKAGE_NAME}" \
    --arg source "${MATRIX_SOURCE}" \
    --arg version "${PACKAGE_VERSION}" \
    --arg sha256_verified "${SHA256_VERIFIED}" \
    --arg actual_sha256 "${ACTUAL_SHA256}" \
    --arg iru_item_id "${IRU_LIBRARY_ITEM_ID}" \
    --arg upload_status "${UPLOAD_STATUS}" \
    --arg upload_timestamp "${UPLOAD_TIMESTAMP}" \
    '{name: $name, source: $source, version: $version, sha256_verified: $sha256_verified, actual_sha256: $actual_sha256, iru_item_id: $iru_item_id, upload_status: $upload_status, upload_timestamp: $upload_timestamp}' \
    > "iru-results/${MATRIX_SOURCE}.json"

  exit 1
fi

echo "✅ Got signed upload URL"
echo "S3 key: ${S3_KEY}"

# ---------------------------------------------------------------------------
# Phase 3 — Upload file directly to S3
# ---------------------------------------------------------------------------
echo ""
echo "Uploading ${FILENAME} to S3 (${FILE_SIZE} bytes)..."

S3_HTTP_STATUS=$(curl_with_retry_silent "${SIGNED_URL}" \
  --request POST \
  --max-time 120 \
  -F "key=${S3_KEY}" \
  -F "x-amz-algorithm=${AMZ_ALGORITHM}" \
  -F "x-amz-credential=${AMZ_CREDENTIAL}" \
  -F "x-amz-date=${AMZ_DATE}" \
  -F "x-amz-security-token=${AMZ_SECURITY_TOKEN}" \
  -F "policy=${POLICY}" \
  -F "x-amz-signature=${AMZ_SIGNATURE}" \
  -F "file=@${FILEPATH}" \
  -w "%{http_code}" \
  -o /dev/null)

if [ "${S3_HTTP_STATUS}" != "200" ] && [ "${S3_HTTP_STATUS}" != "204" ]; then
  echo "❌ S3 upload failed with HTTP status ${S3_HTTP_STATUS}"

  mkdir -p iru-results
  jq -n \
    --arg name "${PACKAGE_NAME}" \
    --arg source "${MATRIX_SOURCE}" \
    --arg version "${PACKAGE_VERSION}" \
    --arg sha256_verified "${SHA256_VERIFIED}" \
    --arg actual_sha256 "${ACTUAL_SHA256}" \
    --arg iru_item_id "${IRU_LIBRARY_ITEM_ID}" \
    --arg upload_status "${UPLOAD_STATUS}" \
    --arg upload_timestamp "${UPLOAD_TIMESTAMP}" \
    '{name: $name, source: $source, version: $version, sha256_verified: $sha256_verified, actual_sha256: $actual_sha256, iru_item_id: $iru_item_id, upload_status: $upload_status, upload_timestamp: $upload_timestamp}' \
    > "iru-results/${MATRIX_SOURCE}.json"

  exit 1
fi

echo "✅ S3 upload complete (HTTP ${S3_HTTP_STATUS})"

# ---------------------------------------------------------------------------
# Phase 4 — Update Iru custom app metadata to link the S3 object
# ---------------------------------------------------------------------------
echo ""
echo "Updating Iru library item metadata..."

PATCH_BODY=$(jq -n \
  --arg file_key "${S3_KEY}" \
  --arg install_type "${INSTALL_TYPE}" \
  --arg install_enforcement "${INSTALL_ENFORCEMENT:-}" \
  --arg unzip_location "${UNZIP_LOCATION:-}" \
  --arg audit_script "${AUDIT_SCRIPT:-}" \
  --arg preinstall_script "${PREINSTALL_SCRIPT:-}" \
  --arg postinstall_script "${POSTINSTALL_SCRIPT:-}" \
  --arg show_in_self_service "${SHOW_IN_SELF_SERVICE:-}" \
  --arg self_service_category_id "${SELF_SERVICE_CATEGORY_ID:-}" \
  --arg self_service_recommended "${SELF_SERVICE_RECOMMENDED:-}" \
  --arg active "${ACTIVE:-}" \
  --arg restart "${RESTART:-}" \
  '{file_key: $file_key}
  | if $install_type != "" then . + {install_type: $install_type} else . end
  | if $install_enforcement != "" then . + {install_enforcement: $install_enforcement} else . end
  | if $unzip_location != "" then . + {unzip_location: $unzip_location} else . end
  | if $audit_script != "" then . + {audit_script: $audit_script} else . end
  | if $preinstall_script != "" then . + {preinstall_script: $preinstall_script} else . end
  | if $postinstall_script != "" then . + {postinstall_script: $postinstall_script} else . end
  | if $show_in_self_service != "" then . + {show_in_self_service: ($show_in_self_service == "true")} else . end
  | if $self_service_category_id != "" then . + {self_service_category_id: $self_service_category_id} else . end
  | if $self_service_recommended != "" then . + {self_service_recommended: ($self_service_recommended == "true")} else . end
  | if $active != "" then . + {active: ($active == "true")} else . end
  | if $restart != "" then . + {restart: ($restart == "true")} else . end')

PATCH_MAX_ATTEMPTS=6
PATCH_WAIT=10
PATCH_ATTEMPT=1
while true; do
  PATCH_RESPONSE=$(curl_with_retry_silent "${IRU_BASE_URL}/api/v1/library/custom-apps/${IRU_LIBRARY_ITEM_ID}" \
    --request PUT \
    --header "Authorization: Bearer ${IRU_API_KEY}" \
    --header "Content-Type: application/json" \
    --data "${PATCH_BODY}" \
    -w "\n%{http_code}")

  PATCH_HTTP_STATUS=$(echo "${PATCH_RESPONSE}" | tail -n1)
  PATCH_BODY_RESPONSE=$(echo "${PATCH_RESPONSE}" | head -n -1)

  if [ "${PATCH_HTTP_STATUS}" = "503" ]; then
    if [ "${PATCH_ATTEMPT}" -ge "${PATCH_MAX_ATTEMPTS}" ]; then
      echo "WARNING: Iru still processing after ${PATCH_MAX_ATTEMPTS} attempts, giving up." >&2
      break
    fi
    echo "Iru upload still processing (attempt ${PATCH_ATTEMPT}/${PATCH_MAX_ATTEMPTS}), retrying in ${PATCH_WAIT}s..."
    sleep "${PATCH_WAIT}"
    PATCH_WAIT=$(( PATCH_WAIT + 10 ))
    PATCH_ATTEMPT=$(( PATCH_ATTEMPT + 1 ))
    continue
  fi
  break
done

if [ "${PATCH_HTTP_STATUS}" != "200" ] && [ "${PATCH_HTTP_STATUS}" != "204" ]; then
  echo "❌ Iru metadata update failed with HTTP status ${PATCH_HTTP_STATUS}"
  echo ""
  echo "NOTE: The file was successfully uploaded to S3 but is not yet linked to"
  echo "library item ${IRU_LIBRARY_ITEM_ID}. You can retry by re-running this"
  echo "workflow, or manually update the library item in the Iru web UI."
  echo ""
  echo "API response:"
  echo "${PATCH_BODY_RESPONSE}" | jq . 2>/dev/null || echo "${PATCH_BODY_RESPONSE}"

  mkdir -p iru-results
  jq -n \
    --arg name "${PACKAGE_NAME}" \
    --arg source "${MATRIX_SOURCE}" \
    --arg version "${PACKAGE_VERSION}" \
    --arg sha256_verified "${SHA256_VERIFIED}" \
    --arg actual_sha256 "${ACTUAL_SHA256}" \
    --arg iru_item_id "${IRU_LIBRARY_ITEM_ID}" \
    --arg upload_status "${UPLOAD_STATUS}" \
    --arg upload_timestamp "${UPLOAD_TIMESTAMP}" \
    '{name: $name, source: $source, version: $version, sha256_verified: $sha256_verified, actual_sha256: $actual_sha256, iru_item_id: $iru_item_id, upload_status: $upload_status, upload_timestamp: $upload_timestamp}' \
    > "iru-results/${MATRIX_SOURCE}.json"

  exit 1
fi

echo "✅ Iru library item updated successfully"

# ---------------------------------------------------------------------------
# All phases complete — write success artifact
# ---------------------------------------------------------------------------
UPLOAD_STATUS="success"
UPLOAD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p iru-results
jq -n \
  --arg name "${PACKAGE_NAME}" \
  --arg source "${MATRIX_SOURCE}" \
  --arg version "${PACKAGE_VERSION}" \
  --arg sha256_verified "${SHA256_VERIFIED}" \
  --arg actual_sha256 "${ACTUAL_SHA256}" \
  --arg iru_item_id "${IRU_LIBRARY_ITEM_ID}" \
  --arg upload_status "${UPLOAD_STATUS}" \
  --arg upload_timestamp "${UPLOAD_TIMESTAMP}" \
  '{name: $name, source: $source, version: $version, sha256_verified: $sha256_verified, actual_sha256: $actual_sha256, iru_item_id: $iru_item_id, upload_status: $upload_status, upload_timestamp: $upload_timestamp}' \
  > "iru-results/${MATRIX_SOURCE}.json"

echo ""
echo "Iru sync result for ${PACKAGE_NAME}:"
cat "iru-results/${MATRIX_SOURCE}.json" | jq .

# ---------------------------------------------------------------------------
# Write $GITHUB_STEP_SUMMARY
# ---------------------------------------------------------------------------
SHA256_DISPLAY="Verified ✅"
if [ "${SHA256_VERIFIED}" = "false" ]; then
  SHA256_DISPLAY="FAILED ❌"
elif [ "${SHA256_VERIFIED}" = "unknown" ]; then
  SHA256_DISPLAY="Skipped ⚠️"
fi

{
  echo "## Iru Sync: ${PACKAGE_NAME}"
  echo ""
  echo "| Property | Value |"
  echo "|----------|-------|"
  echo "| Version | \`${PACKAGE_VERSION}\` |"
  echo "| SHA256 | ${SHA256_DISPLAY} |"
  echo "| Iru Item ID | \`${IRU_LIBRARY_ITEM_ID}\` |"
  echo "| Upload Status | SUCCESS ✅ |"
  echo "| Timestamp | ${UPLOAD_TIMESTAMP} |"
} >> "${GITHUB_STEP_SUMMARY}"

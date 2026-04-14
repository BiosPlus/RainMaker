#!/usr/bin/env bash
set -euo pipefail

# Required env vars (set by workflow):
#   PACKAGE_NAME, LATEST_VERSION, DOWNLOAD_URL, EXPECTED_SHA256, MATRIX_SOURCE, VT_API_KEY

# ---------------------------------------------------------------------------
# Retry wrapper
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
# Download package
# ---------------------------------------------------------------------------
echo "Downloading ${PACKAGE_NAME} version ${LATEST_VERSION}"
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

SHA256_VERIFIED="unknown"
if [ "${EXPECTED_SHA256}" != "none" ] && [ "${EXPECTED_SHA256}" != "no_check" ] && [ -n "${EXPECTED_SHA256}" ]; then
  if [ "${ACTUAL_SHA256}" = "${EXPECTED_SHA256}" ]; then
    echo "✅ SHA256 verification passed"
    SHA256_VERIFIED="true"
  else
    echo "❌ SHA256 verification FAILED!"
    echo "Expected: ${EXPECTED_SHA256}"
    echo "Got: ${ACTUAL_SHA256}"
    SHA256_VERIFIED="false"
  fi
else
  echo "⚠️ No SHA256 hash available for verification"
fi

# ---------------------------------------------------------------------------
# Upload to VirusTotal
# ---------------------------------------------------------------------------
SCAN_STATUS="skipped"
ANALYSIS_ID="none"
VT_MALICIOUS=0
VT_SUSPICIOUS=0
VT_UNDETECTED=0
VT_HARMLESS=0
VT_TIMEOUT=0
VT_FAILURE=0
SCAN_COMPLETED="false"
PERMALINK=""

if [ -z "${VT_API_KEY}" ]; then
  echo "⚠️ VirusTotal API key not configured"
  echo "Please add VIRUSTOTAL_API_KEY to repository secrets"
else
  echo "Checking if VirusTotal already has a report for SHA256: ${ACTUAL_SHA256}..."

  HASH_RESPONSE=$(curl_with_retry_silent "https://www.virustotal.com/api/v3/files/${ACTUAL_SHA256}" \
    --request GET \
    --header "x-apikey: ${VT_API_KEY}")

  HASH_RESPONSE_TYPE=$(echo "${HASH_RESPONSE}" | jq -r '.data.type // empty' 2>/dev/null || true)

  if [ "${HASH_RESPONSE_TYPE}" = "file" ]; then
    echo "✅ File already known to VirusTotal — using existing report"

    STATS=$(echo "${HASH_RESPONSE}" | jq -r '.data.attributes.last_analysis_stats')
    VT_MALICIOUS=$(echo "${STATS}" | jq -r '.malicious // 0')
    VT_SUSPICIOUS=$(echo "${STATS}" | jq -r '.suspicious // 0')
    VT_UNDETECTED=$(echo "${STATS}" | jq -r '.undetected // 0')
    VT_HARMLESS=$(echo "${STATS}" | jq -r '.harmless // 0')
    VT_TIMEOUT=$(echo "${STATS}" | jq -r '.timeout // 0')
    VT_FAILURE=$(echo "${STATS}" | jq -r '.failure // 0')

    echo "Results:"
    echo "  Malicious: ${VT_MALICIOUS}"
    echo "  Suspicious: ${VT_SUSPICIOUS}"
    echo "  Undetected: ${VT_UNDETECTED}"
    echo "  Harmless: ${VT_HARMLESS}"

    PERMALINK="https://www.virustotal.com/gui/file/${ACTUAL_SHA256}/detection"
    SCAN_STATUS="uploaded"
    SCAN_COMPLETED="true"
  else
    echo "File not found in VirusTotal, uploading..."

  # Files > 32MB require a special upload URL
  VT_UPLOAD_URL="https://www.virustotal.com/api/v3/files"
  if [ "${FILE_SIZE}" -gt 33554432 ]; then
    echo "File is larger than 32MB (${FILE_SIZE} bytes), fetching large-file upload URL..."
    UPLOAD_URL_RESPONSE=$(curl_with_retry_silent "https://www.virustotal.com/api/v3/files/upload_url" \
      --request GET \
      --header "x-apikey: ${VT_API_KEY}")
    VT_UPLOAD_URL=$(echo "${UPLOAD_URL_RESPONSE}" | jq -r '.data // empty')
    if [ -z "${VT_UPLOAD_URL}" ]; then
      echo "❌ Failed to get large-file upload URL"
      echo "${UPLOAD_URL_RESPONSE}"
      SCAN_STATUS="failed"
      VT_UPLOAD_URL=""
    else
      echo "Got upload URL for large file"
    fi
  fi

  UPLOAD_RESPONSE=""
  if [ -n "${VT_UPLOAD_URL}" ]; then
    UPLOAD_RESPONSE=$(curl_with_retry_silent "${VT_UPLOAD_URL}" \
      --request POST \
      --header "x-apikey: ${VT_API_KEY}" \
      --max-time 120 \
      --form "file=@${FILEPATH}")
  fi

  ANALYSIS_ID=$(echo "${UPLOAD_RESPONSE}" | jq -r '.data.id // empty' 2>/dev/null || true)

  if [ -z "${ANALYSIS_ID}" ]; then
    echo "❌ Failed to upload to VirusTotal"
    echo "${UPLOAD_RESPONSE}" | jq . 2>/dev/null || echo "${UPLOAD_RESPONSE}"
    SCAN_STATUS="failed"
  else
    echo "✅ Uploaded successfully"
    echo "Analysis ID: ${ANALYSIS_ID}"
    SCAN_STATUS="uploaded"

    # -----------------------------------------------------------------------
    # Wait for VirusTotal analysis
    # -----------------------------------------------------------------------
    echo "Waiting for analysis to complete..."

    MAX_ATTEMPTS=60
    ATTEMPT=0

    while [ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]; do
      ATTEMPT=$((ATTEMPT + 1))

      ANALYSIS_RESPONSE=$(curl_with_retry_silent "https://www.virustotal.com/api/v3/analyses/${ANALYSIS_ID}" \
        --request GET \
        --header "x-apikey: ${VT_API_KEY}")

      STATUS=$(echo "${ANALYSIS_RESPONSE}" | jq -r '.data.attributes.status')

      echo "Attempt ${ATTEMPT}/${MAX_ATTEMPTS}: Status = ${STATUS}"

      if [ "${STATUS}" = "completed" ]; then
        echo "✅ Analysis completed"

        STATS=$(echo "${ANALYSIS_RESPONSE}" | jq -r '.data.attributes.stats')
        VT_MALICIOUS=$(echo "${STATS}" | jq -r '.malicious // 0')
        VT_SUSPICIOUS=$(echo "${STATS}" | jq -r '.suspicious // 0')
        VT_UNDETECTED=$(echo "${STATS}" | jq -r '.undetected // 0')
        VT_HARMLESS=$(echo "${STATS}" | jq -r '.harmless // 0')
        VT_TIMEOUT=$(echo "${STATS}" | jq -r '.timeout // 0')
        VT_FAILURE=$(echo "${STATS}" | jq -r '.failure // 0')

        echo "Results:"
        echo "  Malicious: ${VT_MALICIOUS}"
        echo "  Suspicious: ${VT_SUSPICIOUS}"
        echo "  Undetected: ${VT_UNDETECTED}"
        echo "  Harmless: ${VT_HARMLESS}"

        PERMALINK="https://www.virustotal.com/gui/file/${ACTUAL_SHA256}/detection"
        SCAN_COMPLETED="true"
        break
      fi

      sleep 10
    done

    if [ "${SCAN_COMPLETED}" = "false" ]; then
      echo "⚠️ Analysis timed out after ${MAX_ATTEMPTS} attempts"
    fi
  fi
  fi  # end: file not found in VT, uploaded fresh
fi

# ---------------------------------------------------------------------------
# Save scan result JSON
# ---------------------------------------------------------------------------
mkdir -p scan-results

RESULT_JSON=$(jq -n \
  --arg name "${PACKAGE_NAME}" \
  --arg source "${MATRIX_SOURCE}" \
  --arg version "${LATEST_VERSION}" \
  --arg sha256_verified "${SHA256_VERIFIED}" \
  --arg actual_sha256 "${ACTUAL_SHA256}" \
  --arg scan_status "${SCAN_STATUS}" \
  --arg scan_completed "${SCAN_COMPLETED}" \
  --arg malicious "${VT_MALICIOUS}" \
  --arg suspicious "${VT_SUSPICIOUS}" \
  --arg undetected "${VT_UNDETECTED}" \
  --arg harmless "${VT_HARMLESS}" \
  --arg permalink "${PERMALINK}" \
  '{name: $name, source: $source, version: $version, sha256_verified: $sha256_verified, actual_sha256: $actual_sha256, scan_status: $scan_status, scan_completed: $scan_completed, malicious: $malicious, suspicious: $suspicious, undetected: $undetected, harmless: $harmless, permalink: $permalink}')

echo "Scan result for ${PACKAGE_NAME}:"
echo "${RESULT_JSON}" | jq .

echo "${RESULT_JSON}" > "scan-results/${MATRIX_SOURCE}.json"

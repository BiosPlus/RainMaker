#!/usr/bin/env bash
set -euo pipefail

# Required env vars (set by workflow):
#   PACKAGE_NAME, MATRIX_SOURCE, CURRENT_VERSION, LATEST_VERSION,
#   URL_VERIFIED, DOWNLOAD_URL, SHA256, HOMEPAGE, TIMESTAMP,
#   UNIX_TIMESTAMP, VERIFIED_DOMAIN

# ---------------------------------------------------------------------------
# Load VirusTotal scan results
# ---------------------------------------------------------------------------
RESULT_FILE="scan-results/${MATRIX_SOURCE}.json"

VT_RESULTS_AVAILABLE="false"
VT_SHA256_VERIFIED=""
VT_ACTUAL_SHA256=""
VT_SCAN_STATUS=""
VT_SCAN_COMPLETED=""
VT_MALICIOUS=""
VT_SUSPICIOUS=""
VT_UNDETECTED=""
VT_HARMLESS=""
VT_PERMALINK=""

if [ -f "${RESULT_FILE}" ]; then
  echo "Loading scan results from ${RESULT_FILE}"

  VT_SHA256_VERIFIED=$(jq -r '.sha256_verified' "${RESULT_FILE}")
  VT_ACTUAL_SHA256=$(jq -r '.actual_sha256' "${RESULT_FILE}")
  VT_SCAN_STATUS=$(jq -r '.scan_status' "${RESULT_FILE}")
  VT_SCAN_COMPLETED=$(jq -r '.scan_completed' "${RESULT_FILE}")
  VT_MALICIOUS=$(jq -r '.malicious' "${RESULT_FILE}")
  VT_SUSPICIOUS=$(jq -r '.suspicious' "${RESULT_FILE}")
  VT_UNDETECTED=$(jq -r '.undetected' "${RESULT_FILE}")
  VT_HARMLESS=$(jq -r '.harmless' "${RESULT_FILE}")
  VT_PERMALINK=$(jq -r '.permalink' "${RESULT_FILE}")
  VT_RESULTS_AVAILABLE="true"

  echo "✅ Scan results loaded successfully"
else
  echo "⚠️ No scan results found at ${RESULT_FILE}"
fi

# ---------------------------------------------------------------------------
# Update package version in its individual package file
# ---------------------------------------------------------------------------
echo "Updating ${PACKAGE_NAME}: ${CURRENT_VERSION} -> ${LATEST_VERSION}"

PKG_FILE=""
for f in packages/*.yaml; do
  if [ "$(yq eval '.source' "${f}")" = "${MATRIX_SOURCE}" ]; then
    PKG_FILE="${f}"
    break
  fi
done

if [ -z "${PKG_FILE}" ]; then
  echo "ERROR: Could not find package file for source '${MATRIX_SOURCE}'"
  exit 1
fi

yq eval -i ".version = \"${LATEST_VERSION}\"" "${PKG_FILE}"
echo "Updated ${PKG_FILE}"

# ---------------------------------------------------------------------------
# Generate PR body
# ---------------------------------------------------------------------------
CASK_URL="https://formulae.brew.sh/cask/${MATRIX_SOURCE}"
PR_BODY_FILE="${RUNNER_TEMP:-/tmp}/pr_body.md"

echo "## 📦 Package Version Update: ${PACKAGE_NAME}" > "${PR_BODY_FILE}"
echo "" >> "${PR_BODY_FILE}"
echo "**\`${CURRENT_VERSION}\`** → **\`${LATEST_VERSION}\`**" >> "${PR_BODY_FILE}"
echo "" >> "${PR_BODY_FILE}"

# Determine overall risk level
RISK_LEVEL="LOW"
RISK_ICON="✅"
RISK_MESSAGE="Safe to Merge"

if [ "${VT_RESULTS_AVAILABLE}" = "true" ] && [ "${VT_SCAN_COMPLETED}" = "true" ]; then
  VT_MALICIOUS_NUM="${VT_MALICIOUS:-0}"
  VT_SUSPICIOUS_NUM="${VT_SUSPICIOUS:-0}"

  if [ "${VT_MALICIOUS_NUM}" -gt 0 ]; then
    RISK_LEVEL="CRITICAL"
    RISK_ICON="🚨"
    RISK_MESSAGE="DO NOT MERGE - Malware Detected"
  elif [ "${VT_SUSPICIOUS_NUM}" -gt 0 ]; then
    RISK_LEVEL="HIGH"
    RISK_ICON="⚠️"
    RISK_MESSAGE="Requires Security Review"
  elif [ "${URL_VERIFIED}" != "true" ]; then
    RISK_LEVEL="MEDIUM"
    RISK_ICON="⚠️"
    RISK_MESSAGE="Requires Manual Review"
  fi
elif [ "${URL_VERIFIED}" != "true" ]; then
  RISK_LEVEL="MEDIUM"
  RISK_ICON="⚠️"
  RISK_MESSAGE="Requires Manual Review"
fi

echo "## 🛡️ Security Assessment" >> "${PR_BODY_FILE}"
echo "" >> "${PR_BODY_FILE}"
echo "> ### ${RISK_ICON} **${RISK_LEVEL} RISK - ${RISK_MESSAGE}**" >> "${PR_BODY_FILE}"
echo ">" >> "${PR_BODY_FILE}"

if [ "${RISK_LEVEL}" = "CRITICAL" ]; then
  echo "> **⚠️ WARNING: This package was flagged as malicious by one or more antivirus engines.**" >> "${PR_BODY_FILE}"
elif [ "${RISK_LEVEL}" = "HIGH" ]; then
  echo "> This package was flagged as suspicious and requires thorough security review." >> "${PR_BODY_FILE}"
elif [ "${RISK_LEVEL}" = "MEDIUM" ]; then
  echo "> This package requires additional security verification before merging." >> "${PR_BODY_FILE}"
else
  echo "> This package meets all security verification criteria." >> "${PR_BODY_FILE}"
fi

echo "" >> "${PR_BODY_FILE}"
echo "<table>" >> "${PR_BODY_FILE}"
echo "<tr><th align=\"left\">Security Check</th><th align=\"center\">Status</th><th align=\"left\">Details</th></tr>" >> "${PR_BODY_FILE}"

# VirusTotal Scan Results
if [ "${VT_RESULTS_AVAILABLE}" = "true" ]; then
  if [ "${VT_SCAN_STATUS}" = "uploaded" ] && [ "${VT_SCAN_COMPLETED}" = "true" ]; then
    VT_MALICIOUS_NUM="${VT_MALICIOUS:-0}"
    VT_SUSPICIOUS_NUM="${VT_SUSPICIOUS:-0}"

    if [ "${VT_MALICIOUS_NUM}" -gt 0 ]; then
      echo "<tr><td><strong>VirusTotal Scan</strong></td><td align=\"center\">🚨</td><td><strong>${VT_MALICIOUS} engine(s) detected malware</strong></td></tr>" >> "${PR_BODY_FILE}"
    elif [ "${VT_SUSPICIOUS_NUM}" -gt 0 ]; then
      echo "<tr><td><strong>VirusTotal Scan</strong></td><td align=\"center\">⚠️</td><td><strong>${VT_SUSPICIOUS} engine(s) flagged as suspicious</strong></td></tr>" >> "${PR_BODY_FILE}"
    else
      echo "<tr><td><strong>VirusTotal Scan</strong></td><td align=\"center\">✅</td><td>Clean (${VT_HARMLESS} engines)</td></tr>" >> "${PR_BODY_FILE}"
    fi

    echo "<tr><td><strong>VT Detection Stats</strong></td><td align=\"center\">ℹ️</td><td>Malicious: ${VT_MALICIOUS}, Suspicious: ${VT_SUSPICIOUS}, Harmless: ${VT_HARMLESS}, Undetected: ${VT_UNDETECTED}</td></tr>" >> "${PR_BODY_FILE}"

    if [ -n "${VT_PERMALINK}" ] && [ "${VT_PERMALINK}" != "null" ] && [ "${VT_PERMALINK}" != "" ]; then
      echo "<tr><td><strong>VT Analysis Link</strong></td><td align=\"center\">🔗</td><td><a href=\"${VT_PERMALINK}\">View full report</a></td></tr>" >> "${PR_BODY_FILE}"
    fi

    if [ "${VT_SHA256_VERIFIED}" = "true" ]; then
      echo "<tr><td><strong>Download SHA256</strong></td><td align=\"center\">✅</td><td>Verified match</td></tr>" >> "${PR_BODY_FILE}"
    elif [ "${VT_SHA256_VERIFIED}" = "false" ]; then
      echo "<tr><td><strong>Download SHA256</strong></td><td align=\"center\">🚨</td><td><strong>MISMATCH - Possible tampering!</strong></td></tr>" >> "${PR_BODY_FILE}"
    fi
  elif [ "${VT_SCAN_STATUS}" = "skipped" ]; then
    echo "<tr><td><strong>VirusTotal Scan</strong></td><td align=\"center\">⏭️</td><td>Skipped (API key not configured)</td></tr>" >> "${PR_BODY_FILE}"
  else
    echo "<tr><td><strong>VirusTotal Scan</strong></td><td align=\"center\">⚠️</td><td>Failed or incomplete</td></tr>" >> "${PR_BODY_FILE}"
  fi
else
  echo "<tr><td><strong>VirusTotal Scan</strong></td><td align=\"center\">⚠️</td><td>Results not available</td></tr>" >> "${PR_BODY_FILE}"
fi

# URL Verification
if [ "${URL_VERIFIED}" = "true" ]; then
  echo "<tr><td><strong>URL Verification</strong></td><td align=\"center\">✅</td><td>Download URL matches verified vendor domain</td></tr>" >> "${PR_BODY_FILE}"
  echo "<tr><td><strong>Verified Domain</strong></td><td align=\"center\">✅</td><td><code>${VERIFIED_DOMAIN}</code></td></tr>" >> "${PR_BODY_FILE}"
else
  echo "<tr><td><strong>URL Verification</strong></td><td align=\"center\">⚠️</td><td><strong>Not verified - requires manual check</strong></td></tr>" >> "${PR_BODY_FILE}"
  if [ -n "${VERIFIED_DOMAIN}" ]; then
    echo "<tr><td><strong>Expected Domain</strong></td><td align=\"center\">ℹ️</td><td><code>${VERIFIED_DOMAIN}</code></td></tr>" >> "${PR_BODY_FILE}"
  fi
fi

# SHA256 from Homebrew
if [ "${SHA256}" != "none" ] && [ -n "${SHA256}" ]; then
  echo "<tr><td><strong>SHA256 Checksum</strong></td><td align=\"center\">✅</td><td><code>${SHA256}</code></td></tr>" >> "${PR_BODY_FILE}"
else
  echo "<tr><td><strong>SHA256 Checksum</strong></td><td align=\"center\">⚠️</td><td><strong>Not available</strong></td></tr>" >> "${PR_BODY_FILE}"
fi

echo "</table>" >> "${PR_BODY_FILE}"
echo "" >> "${PR_BODY_FILE}"

# Package Information Section
echo "## 📋 Package Information" >> "${PR_BODY_FILE}"
echo "" >> "${PR_BODY_FILE}"
echo "<table>" >> "${PR_BODY_FILE}"
echo "<tr><th align=\"left\">Property</th><th align=\"left\">Value</th></tr>" >> "${PR_BODY_FILE}"
echo "<tr><td><strong>Current Version</strong></td><td><code>${CURRENT_VERSION}</code></td></tr>" >> "${PR_BODY_FILE}"
echo "<tr><td><strong>New Version</strong></td><td><code>${LATEST_VERSION}</code></td></tr>" >> "${PR_BODY_FILE}"
echo "<tr><td><strong>Download URL</strong></td><td><code>${DOWNLOAD_URL}</code></td></tr>" >> "${PR_BODY_FILE}"

if [ -n "${HOMEPAGE}" ]; then
  echo "<tr><td><strong>Official Homepage</strong></td><td><a href=\"${HOMEPAGE}\">${HOMEPAGE}</a></td></tr>" >> "${PR_BODY_FILE}"
fi

echo "<tr><td><strong>Homebrew Cask</strong></td><td><a href=\"${CASK_URL}\"><code>${MATRIX_SOURCE}</code></a></td></tr>" >> "${PR_BODY_FILE}"
echo "<tr><td><strong>Data Retrieved</strong></td><td>${TIMESTAMP}</td></tr>" >> "${PR_BODY_FILE}"
echo "<tr><td><strong>Unix Timestamp</strong></td><td><code>${UNIX_TIMESTAMP}</code></td></tr>" >> "${PR_BODY_FILE}"
echo "</table>" >> "${PR_BODY_FILE}"

echo "" >> "${PR_BODY_FILE}"
echo "---" >> "${PR_BODY_FILE}"
echo "" >> "${PR_BODY_FILE}"
echo "## Review Checklist" >> "${PR_BODY_FILE}"
echo "" >> "${PR_BODY_FILE}"

if [ "${VT_RESULTS_AVAILABLE}" = "true" ] && [ "${VT_SCAN_COMPLETED}" = "true" ]; then
  VT_MALICIOUS_NUM="${VT_MALICIOUS:-0}"
  VT_SUSPICIOUS_NUM="${VT_SUSPICIOUS:-0}"

  if [ "${VT_MALICIOUS_NUM}" -gt 0 ]; then
    echo "- [ ] **🚨 CRITICAL: Review VirusTotal detections - ${VT_MALICIOUS} engine(s) flagged as malicious**" >> "${PR_BODY_FILE}"
    echo "- [ ] **🚨 CRITICAL: Investigate false positive possibility**" >> "${PR_BODY_FILE}"
    echo "- [ ] **🚨 CRITICAL: DO NOT MERGE without security team approval**" >> "${PR_BODY_FILE}"
  elif [ "${VT_SUSPICIOUS_NUM}" -gt 0 ]; then
    echo "- [ ] **⚠️ IMPORTANT: Review VirusTotal suspicious flags - ${VT_SUSPICIOUS} engine(s)**" >> "${PR_BODY_FILE}"
    echo "- [ ] **⚠️ IMPORTANT: Check vendor's official security announcements**" >> "${PR_BODY_FILE}"
  else
    echo "- [ ] Review VirusTotal scan results (clean)" >> "${PR_BODY_FILE}"
  fi
fi

if [ "${URL_VERIFIED}" = "true" ]; then
  echo "- [ ] Confirm version change is expected (\`${CURRENT_VERSION}\` → \`${LATEST_VERSION}\`)" >> "${PR_BODY_FILE}"
  echo "- [ ] Review the [Homebrew cask page](${CASK_URL}) for changelog" >> "${PR_BODY_FILE}"
  echo "- [ ] Verify no security advisories exist for this version" >> "${PR_BODY_FILE}"
  echo "- [ ] Confirm SHA256 hash is present and valid" >> "${PR_BODY_FILE}"
  if [ "${VT_RESULTS_AVAILABLE}" = "true" ] && [ "${VT_SCAN_COMPLETED}" = "true" ]; then
    VT_MALICIOUS_NUM="${VT_MALICIOUS:-0}"
    if [ "${VT_MALICIOUS_NUM}" -eq 0 ]; then
      echo "- [ ] Confirm VirusTotal scan passed with no detections" >> "${PR_BODY_FILE}"
    fi
  fi
else
  echo "- [ ] **CRITICAL: Verify download URL is from official vendor**" >> "${PR_BODY_FILE}"
  echo "- [ ] **CRITICAL: Manually verify SHA256 hash if possible**" >> "${PR_BODY_FILE}"
  echo "- [ ] Confirm version change is expected (\`${CURRENT_VERSION}\` → \`${LATEST_VERSION}\`)" >> "${PR_BODY_FILE}"
  echo "- [ ] Review the [Homebrew cask page](${CASK_URL}) for changelog" >> "${PR_BODY_FILE}"
  echo "- [ ] Verify no security advisories exist for this version" >> "${PR_BODY_FILE}"
  if [ "${VT_RESULTS_AVAILABLE}" = "true" ] && [ "${VT_SCAN_COMPLETED}" = "true" ]; then
    echo "- [ ] Review VirusTotal scan results carefully" >> "${PR_BODY_FILE}"
  fi
  echo "- [ ] Consider testing package installation before merging" >> "${PR_BODY_FILE}"
fi

echo "" >> "${PR_BODY_FILE}"
echo "---" >> "${PR_BODY_FILE}"
echo "" >> "${PR_BODY_FILE}"
echo "<sub>🤖 This PR was automatically generated by the version check workflow at ${TIMESTAMP}</sub>" >> "${PR_BODY_FILE}"

echo "PR body generated:"
cat "${PR_BODY_FILE}"

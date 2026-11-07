#!/usr/bin/env bash
set -euo pipefail

# PlayItRight — App Store Privacy & Zero-Telemetry Audit (NFR-11, NFR-13)
#
# Fails the build if:
#   • a third-party telemetry/analytics/crash SDK is referenced,
#   • the app manifest enables tracking or declares collected data,
#   • source code contains a network host outside the approved allowlist,
#   • a network URL is not HTTPS.
#
# Usage: ./scripts/audit-privacy.sh [--with-tests]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

RUN_TESTS=0
if [[ "${1:-}" == "--with-tests" ]]; then
    RUN_TESTS=1
fi

VIOLATIONS=0
SOURCES=("Libraries" "PlayItRight")
MANIFEST="PlayItRight/Resources/PrivacyInfo.xcprivacy"
PACKAGE_RESOLVED="PlayItRight.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

fail() {
    echo "❌ $*"
    VIOLATIONS=$((VIOLATIONS + 1))
}

echo "================================================================="
echo "Running PlayItRight Privacy & Zero-Telemetry Audit (NFR-11/NFR-13)"
echo "================================================================="

# 1. Third-party telemetry, analytics, and crash-reporting SDKs.
echo "Scanning for third-party telemetry SDKs..."
TELEMETRY_SDKS=(
    Firebase FirebaseAnalytics FirebaseCrashlytics Crashlytics
    GoogleAnalytics GoogleTagManager
    Sentry Bugsnag Instabug CrashReporter
    Mixpanel Amplitude Segment
    Braze AppsFlyer Adjust Branch
    Datadog NewRelic NewRelicAgent
    Flurry Heap Optimizely Airship OneSignal
    UserLeap Pendo Embrace
    FBSDKCoreKit FBAnalytics TikTokOpenSDK
)
TELEMETRY_FOUND=0
for sdk in "${TELEMETRY_SDKS[@]}"; do
    if grep -R -n -E "import[[:space:]]+${sdk}([[:space:]]|$)|${sdk}SDK|[\"']${sdk}[\"']" \
        "${SOURCES[@]}" PlayItRight.xcodeproj/project.pbxproj 2>/dev/null \
        | grep -v "audit-privacy.sh"; then
        fail "Third-party telemetry SDK referenced: ${sdk}"
        TELEMETRY_FOUND=1
    fi
done
if [[ ${TELEMETRY_FOUND} -eq 0 ]]; then
    echo "✅ No third-party telemetry, analytics, or crash SDKs referenced."
fi

# 2. Swift package dependencies must stay on the approved permissive list.
echo "Checking resolved Swift package dependencies..."
APPROVED_PACKAGES=("grdb.swift")
if [[ ! -f "${PACKAGE_RESOLVED}" ]]; then
    fail "${PACKAGE_RESOLVED} not found"
else
    PACKAGE_VIOLATIONS=0
    while IFS= read -r identity; do
        approved=0
        for package in "${APPROVED_PACKAGES[@]}"; do
            [[ "${identity}" == "${package}" ]] && approved=1
        done
        if [[ ${approved} -eq 0 ]]; then
            fail "Unapproved Swift package dependency: ${identity}"
            PACKAGE_VIOLATIONS=1
        fi
    done < <(sed -n 's/.*"identity" : "\([^"]*\)".*/\1/p' "${PACKAGE_RESOLVED}")
    if [[ ${PACKAGE_VIOLATIONS} -eq 0 ]]; then
        echo "✅ Swift packages contain no telemetry or advertising SDKs."
    fi
fi

# 3. Privacy manifest must declare "Data Not Collected" and no tracking.
echo "Validating PrivacyInfo.xcprivacy..."
if [[ ! -f "${MANIFEST}" ]]; then
    fail "Missing privacy manifest: ${MANIFEST}"
else
    TRACKING="$(plutil -extract NSPrivacyTracking raw -o - "${MANIFEST}" 2>/dev/null || echo "missing")"
    if [[ "${TRACKING}" != "false" ]]; then
        fail "NSPrivacyTracking must be false (found: ${TRACKING})"
    fi

    TRACKING_DOMAINS="$(plutil -extract NSPrivacyTrackingDomains json -o - "${MANIFEST}" 2>/dev/null || echo "missing")"
    if [[ "${TRACKING_DOMAINS}" != "[]" ]]; then
        fail "NSPrivacyTrackingDomains must be empty (found: ${TRACKING_DOMAINS})"
    fi

    COLLECTED="$(plutil -extract NSPrivacyCollectedDataTypes json -o - "${MANIFEST}" 2>/dev/null || echo "missing")"
    if [[ "${COLLECTED}" != "[]" ]]; then
        fail "NSPrivacyCollectedDataTypes must be empty for Data Not Collected (found: ${COLLECTED})"
    fi

    ACCESSED="$(plutil -extract NSPrivacyAccessedAPITypes json -o - "${MANIFEST}" 2>/dev/null || echo "missing")"
    for reason in CA92.1 C617.1 3B52.1; do
        if [[ "${ACCESSED}" != *"${reason}"* ]]; then
            fail "Privacy manifest is missing required-reason API justification: ${reason}"
        fi
    done

    echo "✅ Privacy manifest declares Data Not Collected with no tracking."
fi

# 4. Every hardcoded network host must be on the allowlist.
#    User-configured media servers and Apple system services are dynamic and
#    therefore not represented by source literals.
echo "Checking hardcoded network destinations..."
APPROVED_HOSTS=(
    api.themoviedb.org
    image.tmdb.org
    api4.thetvdb.com
    www.omdbapi.com
    plex.tv
    api.box.com
    api.dropboxapi.com
    content.dropboxapi.com
    graph.microsoft.com
    www.googleapis.com
)
# XML namespaces and example placeholders never leave the device.
IGNORED_HOSTS=(
    schemas.xmlsoap.org
    media.example.com
)

HOSTS="$(grep -R -h -o -E 'https?://[A-Za-z0-9.-]+' "${SOURCES[@]}" --include='*.swift' \
    | sed -E 's#https?://##' \
    | sort -u)"

HOST_VIOLATIONS=0
while IFS= read -r host; do
    [[ -z "${host}" ]] && continue
    ignored=0
    for allowed in "${IGNORED_HOSTS[@]}"; do
        [[ "${host}" == "${allowed}" ]] && ignored=1
    done
    [[ ${ignored} -eq 1 ]] && continue

    approved=0
    for allowed in "${APPROVED_HOSTS[@]}"; do
        [[ "${host}" == "${allowed}" ]] && approved=1
    done
    if [[ ${approved} -eq 0 ]]; then
        fail "Non-whitelisted network host: ${host}"
        HOST_VIOLATIONS=1
    fi
done <<< "${HOSTS}"
if [[ ${HOST_VIOLATIONS} -eq 0 ]]; then
    echo "✅ Every hardcoded network destination is allowlisted."
fi

# 5. Cleartext HTTP is prohibited outside XML namespaces.
echo "Checking transport security..."
if grep -R -h -o -E 'http://[A-Za-z0-9.-]+' "${SOURCES[@]}" --include='*.swift' \
    | sort -u \
    | grep -v -E 'schemas\.xmlsoap\.org'; then
    fail "Cleartext HTTP URL found in source"
else
    echo "✅ All network URLs use HTTPS."
fi

# 6. Optional runtime and contract test suite.
if [[ ${RUN_TESTS} -eq 1 ]]; then
    echo "Running PrivacyAuditTests..."
    if ! make test-suite SUITE=PrivacyAuditTests; then
        fail "PrivacyAuditTests failed"
    fi
fi

echo "================================================================="
if [[ ${VIOLATIONS} -eq 0 ]]; then
    echo "✅ PRIVACY AUDIT PASSED: Data Not Collected, zero telemetry."
    echo "================================================================="
    exit 0
else
    echo "❌ PRIVACY AUDIT FAILED with ${VIOLATIONS} violation(s)."
    echo "================================================================="
    exit 1
fi

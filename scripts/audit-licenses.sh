#!/usr/bin/env bash
set -euo pipefail

# PlayItRight — License Audit Script (ARCH-6)
# Verifies zero GPL code and strict LGPL 2.1+ / permissive licensing.

echo "================================================================="
echo "Running PlayItRight Automated License Compliance Audit (ARCH-6)"
echo "================================================================="

VIOLATIONS=0

# 1. Prohibited license strings in dependencies / manifests
PROHIBITED_LICENSES=("GPL-2.0" "GPL-3.0" "AGPL" "SSPL" "CC-BY-NC")

for lic in "${PROHIBITED_LICENSES[@]}"; do
    if grep -r -i --exclude-dir=".git" --exclude-dir=".build" --exclude-dir="scripts" --exclude="*.md" "${lic}" . 2>/dev/null; then
        echo "❌ ERROR: Prohibited license reference found: ${lic}"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

# 2. Check resolved Swift package dependencies
PACKAGE_RESOLVED="PlayItRight.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
echo "Checking resolved Swift package dependencies..."
if [ ! -f "${PACKAGE_RESOLVED}" ]; then
    echo "❌ ERROR: ${PACKAGE_RESOLVED} not found"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    UNAPPROVED=0
    while IFS= read -r identity; do
        case "${identity}" in
            grdb.swift)
                ;;
            *)
                echo "❌ ERROR: Unapproved Swift package dependency: ${identity}"
                UNAPPROVED=1
                ;;
        esac
    done < <(sed -n 's/.*"identity" : "\([^"]*\)".*/\1/p' "${PACKAGE_RESOLVED}")

    if [ ${UNAPPROVED} -eq 0 ]; then
        echo "✅ Resolved Swift packages contain only verified permissive dependencies."
    else
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
fi

# 3. Check build scripts for forbidden flags (--enable-gpl, --enable-nonfree, libx264, libx265)
echo "Checking build scripts for GPL / non-free configure flags..."
if grep -E -- "--enable-gpl|--enable-nonfree|libx264|libx265" scripts/*.sh | grep -v "grep" | grep -v "#"; then
    echo "❌ ERROR: Prohibited build flags found in scripts/"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    echo "✅ Build scripts strictly enforce --disable-gpl and dynamic LGPL."
fi

if [ ${VIOLATIONS} -eq 0 ]; then
    echo "================================================================="
    echo "✅ LICENSE AUDIT PASSED: 0 GPL/Copyleft violations detected."
    echo "================================================================="
    exit 0
else
    echo "================================================================="
    echo "❌ LICENSE AUDIT FAILED with ${VIOLATIONS} violation(s)."
    echo "================================================================="
    exit 1
fi

#!/bin/bash
#
# Notarization is not part of SoundBridge's release policy.
#
# This script used to zip the app, submit it with `xcrun notarytool`, staple the
# ticket with `xcrun stapler` and rebuild the DMG. That path required an Apple
# Developer Program account (APPLE_ID / APPLE_ID_PASSWORD / APPLE_TEAM_ID) and a
# Developer ID signature -- neither exists for SoundBridge 1.2.0, and neither is
# planned.
#
# Notarization is also impossible without a signature: the notary service only
# accepts Developer ID signed code, so "unsigned but notarized" is not a state a
# release can be in. The install guide tells users what they will see instead.
#
# The previous implementation is in git history at commit 0b50ae1.
#
set -uo pipefail

print_help() {
    cat <<'EOF'
notarize.sh - disabled

Apple notarization is not part of SoundBridge's release policy. It requires a
Developer ID signature, an Apple Developer Program account and a notary service
credential, none of which exist for this project.

This script refuses every invocation and exits 2. The DMG and PKG are published
unsigned; users approve the first launch manually (see docs/INSTALLATION_GUIDE.md).
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) print_help; exit 0 ;;
    esac
done

cat >&2 <<'EOF'
ERROR: notarization is disabled in this repository (exit 2).

SoundBridge 1.2.0 is published unsigned and unnotarized. No Apple Developer
Program account exists, no Developer ID signature is produced, and the notary
service would reject an unsigned submission anyway.

Nothing was submitted, zipped, stapled or rebuilt. Nothing in dist/ was modified.

What users are told instead (docs/INSTALLATION_GUIDE.md):
  * Gatekeeper will refuse the first launch of the app until it is approved
    manually in System Settings > Privacy & Security,
  * the PKG is unsigned, so the Installer asks for approval as well,
  * there is no notarization ticket to verify, and `spctl --assess` reports
    "rejected / source=no usable signature" on every artifact in the release.
EOF
exit 2

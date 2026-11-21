#!/bin/bash
#
# Sparkle appcast generation is not part of SoundBridge's release policy.
#
# Sparkle only signs an update archive whose bundle declares a non-empty
# SUPublicEDKey, and its feed is useful only if the app ships that public key.
# SoundBridge 1.2.0 ships with an empty SUPublicEDKey and no appcast, which means
# the updater never initialises: the app prints "Update feed not configured" and
# runs without auto-update.
#
# That is a deliberate policy, not an unfinished step:
#   * no EdDSA key pair is created, stored or rotated for this project,
#   * no appcast.xml is generated, uploaded or referenced by a release,
#   * "releases/latest/download/appcast.xml" is never published, so nothing in
#     Info.plist points at a live feed,
#   * SUEnableAutomaticChecks is false and VersionManager.updateChannelAvailable
#     is a compile-time false, so an empty SUPublicEDKey is not the only guard.
#
# SUFeedURL does stay in Info.plist, but not as an update channel: the driver
# compatibility notice reads it to derive the GitHub releases page URL. It is a
# link source, and no appcast is ever served from it.
#
# Sparkle.framework itself stays in the bundle: SoundBridgeApp links it through
# @rpath, and removing the framework would break the app at launch. It is a
# build dependency, not an update channel.
#
# The previous implementation is in git history at commit 0b50ae1.
#
set -uo pipefail

print_help() {
    cat <<'EOF'
generate_appcast.sh - disabled

Sparkle auto-update is not supported by SoundBridge 1.2.0: no EdDSA key pair is
created, SUPublicEDKey stays empty and no appcast.xml is published.

This script refuses every invocation and exits 2. Releases are published without
an update feed; users update by downloading a new DMG.
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) print_help; exit 0 ;;
    esac
done

cat >&2 <<'EOF'
ERROR: appcast generation is disabled in this repository (exit 2).

Sparkle auto-update is not supported by SoundBridge 1.2.0. The release pipeline
publishes no appcast.xml and configures no Sparkle keys, so the updater stays
disabled inside the app (SUPublicEDKey is empty, SUEnableAutomaticChecks is
false, and VersionManager.updateChannelAvailable is a compile-time false).

Nothing was generated and nothing in dist/ was modified.

Release assets are limited to:
  SoundBridge-<version>.dmg, SoundBridge-<version>.pkg, SHA256SUMS.txt,
  INSTALLATION_GUIDE.md, RELEASE_NOTES.md

Users update by downloading the next DMG. Auto-update is listed as unsupported in
docs/risks/Known-Limitations.md.
EOF
exit 2

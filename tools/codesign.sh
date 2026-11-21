#!/bin/bash
#
# Code signing is not part of SoundBridge's release policy.
#
# This script used to sign SoundBridgeHost, SoundBridgeDriver.driver,
# Sparkle.framework, SoundBridgeApp and the outer .app bundle, either with a
# Developer ID identity or ad-hoc (`codesign --sign -`). That entire path was
# removed on purpose: SoundBridge 1.2.0 is published as a completely unsigned
# release, and no Apple Developer Program membership exists behind it.
#
# What "unsigned" means here
# --------------------------
#   * no `codesign` invocation of any kind, with any identity, including "-",
#   * no certificate, keychain, provisioning profile or `security find-identity`,
#   * no bundle seal (`Contents/_CodeSignature`), no entitlements blob,
#   * no notarization and no stapling (`tools/notarize.sh` refuses too).
#
# What it cannot mean
# -------------------
# ld64 stamps every Mach-O it produces with an ad-hoc CodeDirectory
# (`flags=0x20002(adhoc,linker-signed)`). On Apple silicon that stamp is what
# makes a binary loadable at all: removing it with `codesign --remove-signature`
# leaves a file the kernel refuses to execute. It is a build-tool artifact, not a
# signature this project creates, and it carries no TeamIdentifier and no
# Authority. The release notes say the same thing in the same words.
#
# What to do instead
# ------------------
#   make bundle            build dist/SoundBridge.app without touching signatures
#   make verify            assert the bundle is unsigned (tools/verify_signatures.sh)
#   make verify-unsigned   assert the whole release set is unsigned
#
# The previous implementation is in git history at commit 0b50ae1.
#
set -uo pipefail

print_help() {
    cat <<'EOF'
codesign.sh - disabled

Code signing is not part of SoundBridge's release policy: no Developer ID, no
ad-hoc signature, no PKG signature, no notarization.

This script refuses every invocation and exits 2. Use:

  make bundle            build dist/SoundBridge.app (no signing step)
  make verify            assert the app bundle is unsigned
  make verify-unsigned   assert the app, PKG and DMG are all unsigned

Unsigned status is checked, never produced.
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) print_help; exit 0 ;;
    esac
done

cat >&2 <<'EOF'
ERROR: code signing is disabled in this repository (exit 2).

SoundBridge 1.2.0 ships unsigned, without an Apple Developer Program account.
No Developer ID Application identity, no ad-hoc signature, no PKG signature and
no notarization are produced by this project, so this script has no work to do.

Nothing was signed. Nothing in dist/ was modified.

Use:
  make bundle            build dist/SoundBridge.app (no signing step)
  make verify            assert the app bundle is unsigned
  make verify-unsigned   assert the app, PKG and DMG are all unsigned

The only signature left in a built binary is the ad-hoc CodeDirectory that ld64
writes into every Mach-O (`flags=0x20002(adhoc,linker-signed)`). It carries no
TeamIdentifier and no Authority, and Apple silicon will not run a binary without
it -- removing it is not an option, and it is not something this project signs.
EOF
exit 2

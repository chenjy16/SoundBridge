# SoundBridge Development Makefile
# Shortcuts for building, testing, and running SoundBridge

# The single version this checkout builds. `make build` writes it into every
# component; override on the command line (make build VERSION=1.2.1) when
# preparing a different release without editing the file.
VERSION ?= $(shell cat VERSION 2>/dev/null || echo 0.0.0)

.PHONY: help clean build run dev reset bundle install-deps test test-dsp test-dsp-tsan test-driver test-host test-app test-installer test-unsigned protocol-check dsp-build sign verify verify-unsigned release-verify release test-release quick rebuild dmg dmg-precheck verify-pkg verify-installer-pkg test-installer-gate verify-dmg verify-payload test-release-payload full-release changelog update-version version-check

# Default target - show help
help:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  SoundBridge Development Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "  Development:"
	@echo "    make dev          - Start from scratch (reset + build + run with onboarding)"
	@echo "    make run          - Run app without onboarding (keeps existing state)"
	@echo "    make reset        - Reset onboarding + uninstall driver"
	@echo ""
	@echo "  Building:"
	@echo "    make build        - Build all components (DSP, driver, host, app)"
	@echo "    make version-check - Check every version source agrees on $(VERSION)"
	@echo "    make bundle       - Create .app bundle in dist/"
	@echo "    make clean        - Clean all build artifacts"
	@echo "    make rebuild      - Full clean + rebuild"
	@echo "    make update-version - Update all component versions from git tag"
	@echo ""
	@echo "  Release (Unsigned):"
	@echo "    make release      - Build and assert an unsigned distribution"
	@echo "    make verify       - Assert the .app bundle is unsigned (no seal, no identity)"
	@echo "    make verify-unsigned - Assert app + PKG + DMG are unsigned, no appcast"
	@echo "    make test-release - Open the release build"
	@echo ""
	@echo "  Distribution:"
	@echo "    make dmg          - Create DMG with drag-to-Applications layout"
	@echo "    make full-release - Complete pipeline (build + verify + DMG)"
	@echo ""
	@echo "  Verification (read-only, works on what is already in dist/):"
	@echo "    make verify-pkg   - The package's two driver copies match the bundle in dist/"
	@echo "    make verify-dmg   - Mount the image read-only and check the app inside it"
	@echo "    make verify-payload - All of the above, plus the driver inside the image (four-way)"
	@echo "    make verify-installer-pkg - Check a package's payload and its pre-payload version gate"
	@echo "    make test-release-payload - Damage tests for the checkers themselves"
	@echo ""
	@echo "  Other:"
	@echo "    make test         - Run protocol check + DSP/Driver/Host/App/installer tests"
	@echo "    make test-driver  - Run the Driver's C++ unit tests"
	@echo "    make test-installer - Run the driver install transaction tests"
	@echo "    make test-installer-gate - Run the package's preinstall/postinstall gate tests"
	@echo "    make protocol-check - Verify the single shared-memory protocol source"
	@echo "    make install-deps - Install build dependencies"
	@echo "    make changelog    - Update CHANGELOG.md (optional: VERSION=vX.Y.Z)"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Start from scratch - full developer workflow with onboarding
dev: reset build bundle
	@echo ""
	@echo "Starting SoundBridge with onboarding..."
	@echo ""
	@open dist/SoundBridge.app

# Run app normally without resetting onboarding
run:
	@echo "Starting SoundBridge..."
	@if [ -d "dist/SoundBridge.app" ]; then \
		open dist/SoundBridge.app; \
	else \
		echo "❌ App bundle not found. Run 'make bundle' first."; \
		exit 1; \
	fi

# Sync every component to the version in the VERSION file.
#
# The argument is passed explicitly. Without it the script falls back to the
# VERSION file on its own, but naming it here keeps a `make build VERSION=x`
# override working and makes the number in the build log the number used.
update-version:
	@echo "Updating component versions to $(VERSION)..."
	@./tools/update_versions.sh "$(VERSION)"
	@echo "✓ Version updated"

# Build all components
#
# The protocol check is a prerequisite, not a suggestion: the driver, the Host
# and the App each compile a generated copy of RFSharedAudio.h, so a stale copy
# would silently ship a mismatched ABI.
build: protocol-check update-version
	@echo "Building all components..."
	@./tools/build_release.sh

# Create .app bundle
bundle:
	@echo "Creating .app bundle..."
	@./tools/create_app_bundle.sh

# Clean all build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf packages/dsp/build
	@rm -rf packages/dsp/build-tsan
	@rm -rf packages/driver/build
	@rm -rf packages/host/.build
	@rm -rf apps/mac/SoundBridgeApp/.build
	@rm -rf dist
	@echo "✓ Clean complete"

# Reset onboarding and uninstall driver (for testing onboarding flow)
reset:
	@echo "Resetting SoundBridge for fresh start..."
	@pkill -f "SoundBridgeApp|SoundBridgeHost" 2>/dev/null || true
	@./tools/uninstall_driver.sh || echo "No driver to uninstall (this is fine)"
	@defaults delete com.soundbridge.menubar hasCompletedOnboarding 2>/dev/null || true
	@defaults delete com.soundbridge.menubar onboardingVersion 2>/dev/null || true
	@defaults delete com.soundbridge.menubar driverInstallDate 2>/dev/null || true
	@sleep 2
	@echo "✓ Reset complete - next launch will show onboarding"

# Install build dependencies
install-deps:
	@echo "Checking build dependencies..."
	@which cmake > /dev/null || (echo "❌ CMake not found. Install with: brew install cmake" && exit 1)
	@which swift > /dev/null || (echo "❌ Swift not found. Install Xcode." && exit 1)
	@echo "✓ All dependencies installed"

# Run all tests: protocol consistency first, then DSP -> Driver -> Host -> App.
# The Host links the prebuilt DSP static library through a relative path, so
# `dsp-build` has to run before `swift test` in packages/host.
test: protocol-check version-check test-dsp test-driver test-host test-app test-installer test-unsigned
	@echo "✓ All test suites passed"

# Every version source agrees on $(VERSION) (App, Driver, VERSION files, CMake).
version-check:
	@echo "Checking version consistency ($(VERSION))..."
	@./tools/verify_version_consistency.sh --expect "$(VERSION)"

# Verify every shared header has exactly one source and identical copies
protocol-check:
	@echo "Checking shared-memory protocol..."
	@./tools/sync_shared_header.sh --check
	@./tools/check_protocol_layout.sh
	@echo "Checking DSP public headers..."
	@./tools/sync_dsp_headers.sh --check

# Build the DSP static library (required before the Host can link)
dsp-build:
	@echo "Building DSP library..."
	@cd packages/dsp && \
	mkdir -p build && \
	cd build && \
	cmake .. && \
	cmake --build .

# Run DSP tests
test-dsp: dsp-build
	@echo "Running DSP tests..."
	@cd packages/dsp/build && ctest --output-on-failure

# Run the DSP suite under ThreadSanitizer (concurrency findings F-02 - F-05).
#
# Its own build directory because sanitizers are single-architecture (the
# default DSP build is universal arm64;x86_64) and because Debug hardcodes
# AddressSanitizer, which cannot be combined with ThreadSanitizer.
test-dsp-tsan:
	@echo "Running DSP tests under ThreadSanitizer..."
	@cd packages/dsp && \
	cmake -S . -B build-tsan \
	  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
	  -DSOUNDBRIDGE_DSP_SANITIZE=thread \
	  -DBUILD_BRIDGE=OFF -DBUILD_TOOLS=OFF && \
	cmake --build build-tsan --target soundbridge_dsp_tests && \
	TSAN_OPTIONS=halt_on_error=1 ./build-tsan/tests/soundbridge_dsp_tests

# Run the Driver's C++ unit tests
#
# The three suites under packages/driver/tests include src/*.hpp and nothing else
# from the driver, so they build and run with no driver installed, no sudo and no
# CoreAudio. packages/driver/CMakeLists.txt declares them as plain executables
# and registers them with CTest.
#
# They are configured in a scratch directory on purpose: packages/driver/build
# holds the bundle the release tooling signs, and a test run must not write over
# it. The scratch path is printed so a failing run can still be inspected.
test-driver:
	@echo "Running Driver tests..."
	@scratch="$$(mktemp -d "$${TMPDIR:-/tmp}/soundbridge-driver-tests.XXXXXX")" && \
	echo "  scratch build: $$scratch" && \
	cmake -S packages/driver -B "$$scratch" && \
	cmake --build "$$scratch" \
	    --target soundbridge_driver_control_protocol_tests \
	             soundbridge_driver_producer_token_tests \
	             soundbridge_driver_mapping_retirement_tests && \
	ctest --test-dir "$$scratch" --output-on-failure

# Run Host tests (volume state model + shared-memory protocol)
test-host: dsp-build
	@echo "Running Host tests..."
	@cd packages/host && swift test

# Run App tests
test-app:
	@echo "Running App tests..."
	@cd apps/mac/SoundBridgeApp && swift test

# Unsigned release policy tests
#
# Two halves: a static scan that fails if a signing, notarization or appcast
# command has crept back into the workflow, the Makefile or tools/, and fixture
# tests that build a tiny unsigned bundle in a temporary directory and assert the
# verifiers accept it -- and refuse a sealed bundle, a bundle carrying a Sparkle
# public key, or a release directory carrying an appcast.
#
# Nothing is signed and dist/ is never read or written.
test-unsigned:
	@echo "Running unsigned release policy tests..."
	@./tools/test_unsigned_release.sh

# Driver install and uninstall lifecycle tests
#
# Install: every scenario runs in its own mktemp directory with a fake driver
# bundle. The real HAL directory is never read or written, and nothing here needs
# sudo.
#
# Uninstall: tools/uninstall_driver.sh runs for real against a --sandbox-root, so
# the removal, the idempotent second run, the refusals, the Host stop (with its
# bounded wait and SIGKILL escalation, on a compiled fixture process), the IPC
# scope and the failure reporting are all exercised without touching this
# machine. Nothing here installs, removes or signals anything outside mktemp.
#
# The process scenarios skip themselves, with a printed reason, on a machine that
# cannot read process state or cannot compile the fixture.
test-installer:
	@echo "Running install transaction tests..."
	@./tools/test_install_transaction.sh
	@echo "Running uninstall lifecycle tests..."
	@./tools/test_uninstall_lifecycle.sh

# Installer package gate tests (Phase 3.2B)
#
# The version refusal that used to live in postinstall now runs in preinstall, so
# it can stop an install before the app payload is written. Those tests expand a
# built package and run its scripts against temporary roots; they need a package
# that already has the gate (dist/ from before Phase 3.2 does not).
#
#   make test-installer-gate PKG=build/p32/SoundBridge-1.1.1.pkg
#
# Defaults to the newest package under build/ so the target is useful right
# after a build without naming the file.
test-installer-gate:
	@PKG="$(PKG)"; \
	if [ -z "$$PKG" ]; then PKG="$$(ls -1t build/*/*.pkg 2>/dev/null | head -1)"; fi; \
	if [ -z "$$PKG" ]; then echo "no package given and none found under build/"; echo "usage: make test-installer-gate PKG=<path-to.pkg>"; exit 1; fi; \
	echo "Running installer gate tests against $$PKG..."; \
	./tools/test_installer_preinstall.sh "$$PKG"

# Quick rebuild (for when you only changed Swift code)
#
# Each architecture gets its own scratch path: SwiftPM 6.x writes both triples to
# the same `out/Products/Release`, so the second build would overwrite the first.
#
# `Sparkle.framework` is staged into the universal directory as well. It is a
# build product that lives next to the executable inside the scratch directory,
# and `create_app_bundle.sh` only finds it in `.build/universal/release` (or in a
# legacy `.build/release` that does not exist after `make clean`). Without the
# staging the bundle links `@rpath/Sparkle.framework` at launch and finds nothing.
quick: protocol-check
	@echo "Quick rebuild (Swift only, universal)..."
	@cd apps/mac/SoundBridgeApp && swift build -c release --triple arm64-apple-macosx --scratch-path .build/arm64 && swift build -c release --triple x86_64-apple-macosx --scratch-path .build/x86_64 && mkdir -p .build/universal/release && lipo -create -output .build/universal/release/SoundBridgeApp .build/arm64/release/SoundBridgeApp .build/x86_64/release/SoundBridgeApp && rm -rf .build/universal/release/Sparkle.framework && cp -R .build/arm64/release/Sparkle.framework .build/universal/release/
	@cd packages/host && swift build -c release --triple arm64-apple-macosx --scratch-path .build/arm64 && swift build -c release --triple x86_64-apple-macosx --scratch-path .build/x86_64 && mkdir -p .build/universal/release && lipo -create -output .build/universal/release/SoundBridgeHost .build/arm64/release/SoundBridgeHost .build/x86_64/release/SoundBridgeHost
	@./tools/create_app_bundle.sh
	@echo "✓ Quick rebuild complete (universal)"

# Full clean + rebuild
rebuild: clean build bundle
	@echo "✓ Full rebuild complete"

# Verify the driver inside the finished .app, not the sources it came from.
#
# `protocol-check` covers the source plist; this covers the plist CMake emitted
# into the driver bundle and `create_app_bundle.sh` copied into the app. Those
# are two extra steps where a stale value can survive every source-level check.
# `release` and `full-release` depend on it, so a mismatch stops the build
# before anything is packaged.
release-verify:
	@./tools/verify_release_bundle.sh

# Unsigned release policy
#
# SoundBridge 1.2.0 is published without any signing identity: no Developer ID,
# no ad-hoc signature, no PKG signature and no notarization. `sign` is kept only
# so an old habit fails loudly -- it calls tools/codesign.sh, which refuses with
# exit 2 and explains why. The verifiers are inverted accordingly: they pass only
# when nothing was signed.
sign:
	@./tools/codesign.sh

# Assert the app bundle is unsigned (no seal, no Authority, empty SUPublicEDKey).
verify:
	@./tools/verify_signatures.sh

# Assert the whole release set is unsigned: app, PKG, DMG, and no appcast.
verify-unsigned:
	@./tools/verify_unsigned_release.sh \
		--app "$(APP_BUNDLE)" \
		--pkg "$(dir $(APP_BUNDLE))SoundBridge-$(VERSION).pkg" \
		--dmg "$(dir $(APP_BUNDLE))SoundBridge-$(VERSION).dmg"

# Build and assert an unsigned distribution
release: build bundle release-verify verify
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "     Release Build Complete!"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "Unsigned app: dist/SoundBridge.app"
	@echo "  no Developer ID, no ad-hoc signature, no notarization"
	@echo ""
	@echo "Next steps:"
	@echo "  • Test: make test-release"
	@echo "  • Package DMG: ./tools/create_dmg.sh"
	@echo "  • Package PKG: ./tools/build_installer_pkg.sh"
	@echo ""

# Open the release build
test-release:
	@echo "Testing release build..."
	@open dist/SoundBridge.app

# The app bundle the DMG wraps. Overridable so `make dmg-precheck` can be pointed
# at a scratch bundle; `dmg` hands the same value to create_dmg.sh, so the bundle
# that is checked is the bundle that is packaged.
APP_BUNDLE ?= dist/SoundBridge.app

# Create DMG for distribution
#
# The pre-check runs first because a half-built bundle would otherwise produce a
# DMG that installs an app that cannot launch. The archive itself is written to a
# staging path and moved into place only after it exists, so a failed run no
# longer costs the DMG that was already in dist/.
#
dmg: dmg-precheck
	@echo "Creating DMG..."
	@APP_BUNDLE="$(APP_BUNDLE)" ./tools/create_dmg.sh

# Refuse to package an app bundle that is missing the parts that make it an app.
#
# `[ -d ]` is not enough: a bundle left over from an interrupted run, or one
# whose driver copy failed, is still a directory. Everything the DMG exists to
# deliver is checked here, and every problem is reported in one pass.
#
# Sparkle is on the list because `otool -L dist/SoundBridge.app/Contents/MacOS/
# SoundBridgeApp` resolves `@rpath/Sparkle.framework/Versions/B/Sparkle`: dyld
# refuses to start the app when that path has nothing behind it, and the DMG
# would ship an app whose only symptom is "it is damaged".
dmg-precheck:
	@bundle="$(APP_BUNDLE)"; \
	problems=0; \
	add() { echo "   - $$1"; problems=$$((problems + 1)); }; \
	if [ -z "$$bundle" ]; then \
	    add "APP_BUNDLE is empty"; \
	elif [ ! -e "$$bundle" ]; then \
	    add "$$bundle does not exist (run 'make bundle' first)"; \
	elif [ ! -d "$$bundle" ]; then \
	    add "$$bundle is not a directory"; \
	else \
	    plist="$$bundle/Contents/Info.plist"; \
	    if [ ! -f "$$plist" ]; then \
	        add "$$plist is missing"; \
	    elif ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$plist" >/dev/null 2>&1; then \
	        add "$$plist is not a property list with a CFBundleIdentifier"; \
	    fi; \
	    for exe in "$$bundle/Contents/MacOS/SoundBridgeApp" "$$bundle/Contents/MacOS/SoundBridgeHost"; do \
	        if [ ! -f "$$exe" ]; then \
	            add "$$exe is missing"; \
	        elif [ ! -x "$$exe" ]; then \
	            add "$$exe is not executable"; \
	        fi; \
	    done; \
	    driver="$$bundle/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver"; \
	    if [ ! -f "$$driver" ]; then \
	        add "$$driver is missing (the app cannot install a driver it does not ship)"; \
	    elif [ ! -x "$$driver" ]; then \
	        add "$$driver is not executable"; \
	    fi; \
	    sparkle="$$bundle/Contents/Frameworks/Sparkle.framework"; \
	    if [ ! -d "$$sparkle" ]; then \
	        add "$$sparkle is missing (SoundBridgeApp links @rpath/Sparkle.framework)"; \
	    else \
	        sparkle_bin="$$sparkle/Versions/B/Sparkle"; \
	        [ -e "$$sparkle_bin" ] || sparkle_bin="$$sparkle/Versions/Current/Sparkle"; \
	        if [ ! -f "$$sparkle_bin" ]; then \
	            add "$$sparkle has no Sparkle executable (looked for Versions/B and Versions/Current)"; \
	        elif [ ! -x "$$sparkle_bin" ]; then \
	            add "$$sparkle_bin is not executable"; \
	        fi; \
	        sparkle_plist="$$sparkle/Versions/B/Resources/Info.plist"; \
	        [ -e "$$sparkle_plist" ] || sparkle_plist="$$sparkle/Versions/Current/Resources/Info.plist"; \
	        if [ ! -f "$$sparkle_plist" ]; then \
	            add "$$sparkle has no Resources/Info.plist (looked for Versions/B and Versions/Current)"; \
	        elif ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$sparkle_plist" >/dev/null 2>&1; then \
	            add "$$sparkle_plist is not a property list with a CFBundleIdentifier"; \
	        fi; \
	    fi; \
	fi; \
	if [ "$$problems" -ne 0 ]; then \
	    echo "ERROR: refusing to build a DMG from an unusable app bundle ($$problems problem(s)): " >&2; \
	    echo "No DMG was created; any DMG already in dist/ was left untouched." >&2; \
	    exit 1; \
	fi; \
	echo "OK: app bundle is complete enough to package: $$bundle"

# Verify what is already in dist/, without building, signing or installing anything.
#
# All three targets take the same APP_BUNDLE, defined above: the bundle a release
# is built from is the one the package and the image are compared against, so a
# scratch bundle has to reach every check instead of only some of them.
#
# `verify-pkg` compares the package's two copies with that bundle (three-way).
# `verify-payload` runs the image stage first and adds the driver inside the
# mounted image to the same comparison (four-way); `verify-pkg` stays package-only
# so it can answer one question without mounting anything.
#
# Which release is checked is $(VERSION) -- the repository's VERSION file -- and
# that is handed to each verifier explicitly. The bundle in dist/ no longer
# selects the artifacts: it is the copy that goes stale, and a 1.1.1 bundle next
# to a 1.2.0 tree used to make the 1.1.1 package and image look verified.
#
# `verify-payload` prints one line per area (PASS, FAIL or NOT_VERIFIED); the
# individual targets exist for when only one artifact is at hand. An artifact
# that is not there is reported as NOT_VERIFIED, not as PASS.
verify-pkg:
	@./tools/verify_pkg_contents.sh --app "$(APP_BUNDLE)" --version "$(VERSION)"

# Static check of an installer package: payload layout, script contents, and the
# pre-payload version gate. Reads only, never installs.
#
#   make verify-installer-pkg PKG=build/p32/SoundBridge-1.1.1.pkg
#
# Pass ALLOW_LEGACY_PREINSTALL=1 to report the Phase 3.2B gate assertions as notes
# instead of failures, for a package built before the gate moved into preinstall.
verify-installer-pkg:
	@PKG="$(PKG)"; \
	if [ -z "$$PKG" ]; then PKG="$$(ls -1t build/*/*.pkg 2>/dev/null | head -1)"; fi; \
	if [ -z "$$PKG" ]; then echo "no package given and none found under build/"; echo "usage: make verify-installer-pkg PKG=<path-to.pkg>"; exit 1; fi; \
	./tools/verify_installer_pkg.sh $(if $(ALLOW_LEGACY_PREINSTALL),--allow-legacy-preinstall,) "$$PKG"

verify-dmg:
	@./tools/verify_dmg_contents.sh --app "$(APP_BUNDLE)" --expect-version "$(VERSION)"

verify-payload:
	@./tools/verify_release_payload.sh --app "$(APP_BUNDLE)" --version "$(VERSION)"

# Damage tests for the verifiers above: each case breaks one copy of an artifact
# and expects the matching verifier to notice. Reads dist/, writes only to a
# scratch directory.
test-release-payload:
	@./tools/test_release_payload.sh

# Full release pipeline (build, assert unsigned, create DMG)
full-release: build bundle release-verify verify dmg
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Full Release Build Complete!"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "  Signed by nothing: no Developer ID, no ad-hoc, no notarization"
	@ls -lh dist/*.dmg

# Update changelog
changelog:
	@echo "Updating CHANGELOG.md..."
	@./tools/generate_changelog.sh $(if $(VERSION),--tag $(VERSION),)
	@echo "✓ CHANGELOG.md updated"

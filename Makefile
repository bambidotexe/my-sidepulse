DEST := /Applications/MySidepulse.app
CLI := $(DEST)/Contents/MacOS/mysidepulse
AGENT := io.mysidepulse.agent

.PHONY: build test app dmg install release uninstall

build:
	swift build

test:
	swift test

# Ad-hoc unless a Developer ID certificate is in the keychain; refuses an ad-hoc build without DEBUG_OK=1
# (scripts/make-app.sh) — an ad-hoc build is for reading something a signed build will not show, and is
# never installed. `install` and `release` build the real, signed, notarized thing instead.
app:
	sh scripts/make-app.sh

# The disk image a GitHub release carries; it publishes nothing.
dmg:
	sh scripts/make-dmg.sh

# The real, signed, notarized, stapled bundle — never build/MySidepulse.app — replacing /Applications and
# leaving nothing launchable behind. scripts/install.sh has the sequence and why each step is not optional.
install:
	sh scripts/install.sh

# The same install, plus a tagged, pushed GitHub release carrying the disk image, at the version the given
# LEVEL bumps to (patch, minor or major — required). Only run when the owner has asked for a release.
# scripts/publish.sh has the sequence.
release:
	sh scripts/publish.sh $(LEVEL)

uninstall:
	-"$(CLI)" uninstall-hooks
	# Before the bundle goes, not after: Background Task Management stores the
	# launch agent against it, and a record left pointing at a deleted bundle
	# breaks the next install's crash restart while still reporting itself
	# registered.
	-"$(CLI)" autostart off
	-launchctl bootout "gui/$$(id -u)/$(AGENT)" 2>/dev/null
	-killall MySidepulseApp 2>/dev/null
	rm -rf "$(DEST)"
	@echo "Config and journal left in ~/Library/Application Support/MySidepulse — remove by hand if wanted."
	@echo "If Open at Login was enabled, remove the stale entry in System Settings > General > Login Items."

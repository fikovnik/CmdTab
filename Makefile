APP_NAME  := CmdTab
BUNDLE_ID := net.fikovnik.cmdtab
APP       := build/$(APP_NAME).app

# Stable code-signing identity, created on demand by scripts/make-cert.sh.
# An ad-hoc signature pins the designated requirement to the binary's cdhash,
# so macOS drops the Accessibility grant on every rebuild. A certificate makes
# the requirement `identifier ... and certificate leaf ...`, which does not move.
# CI has no keychain to put one in, so it passes IDENTITY=- for an ad-hoc
# signature and accepts that the grant is per-download.
IDENTITY ?= CmdTab Self-Signed

# `debug` additionally builds --report, the Write Diagnostics menu item and the
# Space-change auto-trace. See Diagnostics in the README.
CONFIG ?= release

.PHONY: all cert build test app install uninstall run stop reset-permissions clean

all: app

cert:
ifneq ($(IDENTITY),-)
	@./scripts/make-cert.sh "$(IDENTITY)"
endif

build:
	swift build -c $(CONFIG)

# The Command Line Tools toolchain ships neither XCTest nor a loadable
# swift-testing macro plugin, so point at Xcode's toolchain when one is
# installed. DEVELOPER_DIR does that without needing sudo xcode-select.
test:
	@if [ -d /Applications/Xcode.app ]; then \
		DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test; \
	else \
		swift test; \
	fi

app: cert build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/$(CONFIG)/$(APP_NAME) $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string $(BUNDLE_ID) $(APP)/Contents/Info.plist
	codesign --force --sign "$(IDENTITY)" --identifier $(BUNDLE_ID) $(APP)
	@codesign -d -r- $(APP) 2>&1 | grep designated

install: app stop
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	@echo "installed to /Applications/$(APP_NAME).app"

uninstall: stop
	rm -rf /Applications/$(APP_NAME).app

run: app stop
	open $(APP)

stop:
	-@pkill -x $(APP_NAME) 2>/dev/null; true

# Only needed to clear a grant made against a *different* signing identity,
# i.e. the one-time migration off ad-hoc signing, or if you delete the
# certificate. Ordinary rebuilds keep their permission.
reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID)

clean:
	rm -rf .build build

APP_NAME  := CmdTab
BUNDLE_ID := net.fikovnik.cmdtab
APP       := build/$(APP_NAME).app

# The code-signing identity. scripts/make-cert.sh creates it if necessary.
# With an ad-hoc signature, macOS loses the Accessibility permission on each
# build. With a certificate, the permission stays (see scripts/make-cert.sh).
# CI has no keychain. Thus, CI uses IDENTITY=- for an ad-hoc signature, and
# each download needs the permission again.
IDENTITY ?= CmdTab Self-Signed

# `debug` also builds --report, the Write Diagnostics menu item and the trace
# on a Space change. See Diagnostics in the README.
CONFIG ?= release

.PHONY: all cert build test app install uninstall run stop reset-permissions clean

all: app

cert:
ifneq ($(IDENTITY),-)
	@./scripts/make-cert.sh "$(IDENTITY)"
endif

build:
	swift build -c $(CONFIG)

# The Command Line Tools have no XCTest and no swift-testing macro plugin.
# Thus, use the Xcode toolchain if Xcode is installed. DEVELOPER_DIR does this
# without sudo xcode-select.
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

# Necessary only after a change of the signing identity, for example after
# you delete the certificate. A normal build keeps the permission.
reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID)

clean:
	rm -rf .build build

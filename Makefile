APP_NAME  := CmdTab
BUNDLE_ID := net.fikovnik.cmdtab
APP       := build/$(APP_NAME).app

# A stable signing certificate helps preserve Accessibility permission.
# CI uses IDENTITY=- because no signing certificate is available.
IDENTITY ?= CmdTab Self-Signed

# Ship and test the same release configuration.

.PHONY: all cert build test app install uninstall run stop reset-permissions clean

all: app

cert:
ifneq ($(IDENTITY),-)
	@./scripts/make-cert.sh "$(IDENTITY)"
endif

build:
	swift build -c release

# Use one toolchain for the app and its tests.
ifneq ($(wildcard /Applications/Xcode.app),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

test:
	swift test -c release

app: cert build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/$(APP_NAME) $(APP)/Contents/MacOS/
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

# Reset permission after a signing identity change.
reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID)

clean:
	rm -rf .build build

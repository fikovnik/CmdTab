APP_NAME  := CmdTab
BUNDLE_ID := com.krikava.cmdtab
APP       := build/$(APP_NAME).app

.PHONY: all build app install uninstall run stop reset-permissions clean

all: app

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/$(APP_NAME) $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - --identifier $(BUNDLE_ID) $(APP)
	@echo "built $(APP)"

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

# Ad-hoc signatures change on every rebuild, so macOS treats the new binary as a
# different program and drops its Accessibility grant. Run this, then re-add the
# app under System Settings > Privacy & Security > Accessibility.
reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID)

clean:
	rm -rf .build build

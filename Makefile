.PHONY: build debug test run clean reset-screen-permission help

APP_BUNDLE := SonoTwinApp/SonoTwinApp.app
BUNDLE_IDENTIFIER := com.sonotwin.app
SONOTWIN_SIGNING_IDENTITY ?= SonoTwin Local Development

# Default target
all: build

# Build menu bar app (release)
build:
	cd SonoTwinApp && swift build -c release
	cp SonoTwinApp/.build/release/SonoTwinApp SonoTwinApp/SonoTwinApp.app/Contents/MacOS/
	codesign --force --sign "$(SONOTWIN_SIGNING_IDENTITY)" --identifier "$(BUNDLE_IDENTIFIER)" "$(APP_BUNDLE)"
	@if [ "$(SONOTWIN_SIGNING_IDENTITY)" = "-" ]; then \
		echo "Warning: ad-hoc signing makes macOS privacy grants build-specific."; \
		echo "Set SONOTWIN_SIGNING_IDENTITY to a stable Apple Development identity."; \
	fi

# Debug build
debug:
	cd SonoTwinApp && swift build

# Run Swift package tests
test:
	cd SonoTwinApp && swift test

# Run menu bar app
run: build
	open "$(APP_BUNDLE)"

# Clean all build artifacts
clean:
	rm -rf SonoTwinApp/.build
	rm -f SonoTwinApp/*.d SonoTwinApp/*.swiftdeps
	rm -f SonoTwinApp/SonoTwinApp.app/Contents/MacOS/SonoTwinApp

# Remove the stale Screen Recording grant after changing signing identity.
reset-screen-permission:
	tccutil reset ScreenCapture "$(BUNDLE_IDENTIFIER)"

# Help
help:
	@echo "SonoTwin Build System"
	@echo ""
	@echo "Targets:"
	@echo "  build   - Build menu bar app (release)"
	@echo "  debug   - Build menu bar app (debug)"
	@echo "  test    - Run Swift package tests"
	@echo "  run     - Build and launch menu bar app"
	@echo "  clean   - Remove all build artifacts"
	@echo "  reset-screen-permission - Reset SonoTwin's Screen Recording grant"
	@echo ""
	@echo "CLI Control (while app is running):"
	@echo "  ./sonotwin-ctl status"
	@echo "  ./sonotwin-ctl start --output recording.wav"
	@echo "  ./sonotwin-ctl stop"

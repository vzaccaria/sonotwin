.PHONY: build debug run clean help

# Default target
all: build

# Build menu bar app (release)
build:
	cd SonoTwinApp && swift build -c release
	cp SonoTwinApp/.build/release/SonoTwinApp SonoTwinApp/SonoTwinApp.app/Contents/MacOS/

# Debug build
debug:
	cd SonoTwinApp && swift build

# Run menu bar app
run: build
	open SonoTwinApp/SonoTwinApp.app

# Clean all build artifacts
clean:
	rm -rf SonoTwinApp/.build
	rm -f SonoTwinApp/*.d SonoTwinApp/*.swiftdeps
	rm -f SonoTwinApp/SonoTwinApp.app/Contents/MacOS/SonoTwinApp

# Help
help:
	@echo "SonoTwin Build System"
	@echo ""
	@echo "Targets:"
	@echo "  build   - Build menu bar app (release)"
	@echo "  debug   - Build menu bar app (debug)"
	@echo "  run     - Build and launch menu bar app"
	@echo "  clean   - Remove all build artifacts"
	@echo ""
	@echo "CLI Control (while app is running):"
	@echo "  ./sonotwin-ctl status"
	@echo "  ./sonotwin-ctl start --output recording.wav"
	@echo "  ./sonotwin-ctl stop"

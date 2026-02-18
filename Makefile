.PHONY: build debug run clean help

# Default target
all: build

# Build menu bar app (release)
build:
	cd AudioScribeApp && swift build -c release
	cp AudioScribeApp/.build/release/AudioScribeApp AudioScribeApp/AudioScribeApp.app/Contents/MacOS/

# Debug build
debug:
	cd AudioScribeApp && swift build

# Run menu bar app
run: build
	open AudioScribeApp/AudioScribeApp.app

# Clean all build artifacts
clean:
	rm -rf AudioScribeApp/.build
	rm -f AudioScribeApp/*.d AudioScribeApp/*.swiftdeps
	rm -f AudioScribeApp/AudioScribeApp.app/Contents/MacOS/AudioScribeApp

# Help
help:
	@echo "AudioScribe Build System"
	@echo ""
	@echo "Targets:"
	@echo "  build   - Build menu bar app (release)"
	@echo "  debug   - Build menu bar app (debug)"
	@echo "  run     - Build and launch menu bar app"
	@echo "  clean   - Remove all build artifacts"
	@echo ""
	@echo "CLI Control (while app is running):"
	@echo "  ./ascribe-ctl status"
	@echo "  ./ascribe-ctl start --output recording.wav"
	@echo "  ./ascribe-ctl stop"

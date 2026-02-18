.PHONY: build build-cli build-app run clean release install help

# Default target
all: build

# Build both CLI and App
build: build-cli build-app

# Build CLI tool only
build-cli:
	swift build -c release
	cp .build/release/audioscribe AudioScribe.app/Contents/MacOS/

# Build menu bar app only
build-app:
	cd AudioScribeApp && swift build -c release
	cp AudioScribeApp/.build/release/AudioScribeApp AudioScribeApp/AudioScribeApp.app/Contents/MacOS/

# Debug builds
debug: debug-cli debug-app

debug-cli:
	swift build

debug-app:
	cd AudioScribeApp && swift build

# Run CLI tool
run: build-cli
	./ascribe $(ARGS)

# Run menu bar app
run-app: build-app
	open AudioScribeApp/AudioScribeApp.app

# Clean all build artifacts
clean:
	swift package clean
	rm -rf .build
	rm -rf AudioScribeApp/.build
	rm -f AudioScribeApp/*.d AudioScribeApp/*.swiftdeps
	rm -f AudioScribe.app/Contents/MacOS/audioscribe
	rm -f AudioScribeApp/AudioScribeApp.app/Contents/MacOS/AudioScribeApp

# Install CLI to /usr/local/bin
install: build-cli
	cp .build/release/audioscribe /usr/local/bin/

# Help
help:
	@echo "AudioScribe Build System"
	@echo ""
	@echo "Targets:"
	@echo "  build       - Build both CLI and menu bar app (release)"
	@echo "  build-cli   - Build CLI tool only"
	@echo "  build-app   - Build menu bar app only"
	@echo "  debug       - Build both in debug mode"
	@echo "  run         - Build and run CLI (use ARGS= for arguments)"
	@echo "  run-app     - Build and launch menu bar app"
	@echo "  clean       - Remove all build artifacts"
	@echo "  install     - Install CLI to /usr/local/bin"
	@echo ""
	@echo "Examples:"
	@echo "  make build"
	@echo "  make run ARGS='--system-only --duration 30 --output test.wav'"
	@echo "  make run-app"
	@echo "  make clean"

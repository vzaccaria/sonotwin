.PHONY: build run clean release install

build:
	swift build

release:
	swift build -c release

run: build
	.build/debug/audioscribe $(ARGS)

clean:
	swift package clean
	rm -rf .build

install: release
	cp .build/release/audioscribe /usr/local/bin/

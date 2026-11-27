SHELL := /bin/bash
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APP := $(ROOT)/build/DoctKey.app

.DEFAULT_GOAL := build
.PHONY: all build test test-core test-swift cli install uninstall enable settings diagnose release clean fmt

all: build

# Build the Rust static library and assemble build/DoctKey.app (ad-hoc signed).
build:
	./scripts/build.sh

# Full verification: Rust engine tests + Swift handler/fixture tests.
test: test-core test-swift

test-core:
	cargo test --manifest-path core/Cargo.toml

test-swift:
	./scripts/test-swift.sh

# Interactive engine playground (no macOS install needed).
cli:
	cargo run --manifest-path core/Cargo.toml --bin doctkey-cli -- --repl

# Install as a system input source. On macOS 26+ this installs into
# /Library/Input Methods and therefore asks for sudo.
install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

# Open the settings-only window from the installed app (or the repo build).
settings:
	@if [ -x "/Library/Input Methods/DoctKey.app/Contents/MacOS/DoctKey" ]; then \
		"/Library/Input Methods/DoctKey.app/Contents/MacOS/DoctKey" --settings; \
	elif [ -x "$(HOME)/Library/Input Methods/DoctKey.app/Contents/MacOS/DoctKey" ]; then \
		"$(HOME)/Library/Input Methods/DoctKey.app/Contents/MacOS/DoctKey" --settings; \
	else \
		"$(APP)/Contents/MacOS/DoctKey" --settings; \
	fi

# Print a diagnostics report (install path, signature, TIS state, config).
diagnose:
	./scripts/diagnose.sh

# Sign and publish a versioned ZIP to the public GitHub Releases feed.
# Example: make release VERSION=0.2.1
release:
	@test -n "$(VERSION)" || { echo 'Usage: make release VERSION=0.2.1'; exit 2; }
	VERSION="$(VERSION)" ./scripts/release.sh

# Register + enable + select the installed bundle with the TIS APIs. Run this
# after logging back in if DoctKey does not show up in System Settings yet; the
# helper automatically looks in both install locations (macOS 26: /Library/Input
# Methods, older: ~/Library/Input Methods).
enable:
	@mkdir -p build
	@swiftc -O -o build/enable-input-source scripts/enable-input-source.swift \
		-framework Carbon -framework Foundation
	@./build/enable-input-source

clean:
	cargo clean --manifest-path core/Cargo.toml
	rm -rf build

fmt:
	cargo fmt --manifest-path core/Cargo.toml

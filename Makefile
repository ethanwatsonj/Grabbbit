PROJECT        := Grabbit.xcodeproj
SCHEME         := Grabbit
CONFIG         ?= Debug
DERIVED        := .build
DESTINATION    := platform=macOS,arch=arm64
APP            := $(DERIVED)/Build/Products/$(CONFIG)/Grabbit.app
BUNDLE_ID      := ewew.design.Grabbit

# Release packaging (Developer ID–signed, notarized, stapled .app)
RELEASE_APP    ?= Grabbit.app
DIST           := dist
DMG_ROOT       := $(DIST)/dmg-root
DMG            := $(DIST)/Grabbit.dmg
NOTARY_PROFILE ?= AC_PASSWORD
CREATE_DMG     := $(shell \
	if command -v create-dmg >/dev/null 2>&1; then command -v create-dmg; \
	elif [ -x tools/create-dmg/create-dmg ]; then echo tools/create-dmg/create-dmg; \
	else echo create-dmg; fi)

# Always use full Xcode.app toolchain (not bare Command Line Tools).
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

XCODEBUILD     := xcodebuild \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-configuration $(CONFIG) \
	-destination '$(DESTINATION)' \
	-derivedDataPath $(DERIVED)

.PHONY: ensure-xcode build run stop clean ensure-create-dmg dmg release

# Verify xcode-select / DEVELOPER_DIR point at Xcode.app before building.
ensure-xcode:
	@if [ ! -d "$(DEVELOPER_DIR)" ]; then \
		echo "error: Xcode not found at $(DEVELOPER_DIR)"; \
		echo "Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
		exit 1; \
	fi
	@active="$$(xcode-select -p 2>/dev/null || true)"; \
	if [ "$$active" != "$(DEVELOPER_DIR)" ]; then \
		echo "note: xcode-select is '$$active'; using DEVELOPER_DIR=$(DEVELOPER_DIR) for this build"; \
	fi
	@xcrun --find xcodebuild >/dev/null
	@xcodebuild -version

# Stop every running Grabbit (Cursor .build + Xcode DerivedData copies).
# Also releases instances held by Xcode's debugserver (normal killall can't).
stop:
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@killall Grabbit 2>/dev/null || true
	@sleep 0.3
	@pids="$$(pgrep -f '/Grabbit\.app/Contents/MacOS/Grabbit' 2>/dev/null || true)"; \
	for pid in $$pids; do \
		ppid="$$(ps -o ppid= -p "$$pid" 2>/dev/null | tr -d ' ')"; \
		if [ -n "$$ppid" ] && [ "$$ppid" != "1" ]; then \
			pcmd="$$(ps -o command= -p "$$ppid" 2>/dev/null || true)"; \
			case "$$pcmd" in \
				*debugserver*) /bin/kill -9 "$$ppid" 2>/dev/null || true ;; \
			esac; \
		fi; \
		/bin/kill -9 "$$pid" 2>/dev/null || true; \
	done
	@killall -9 Grabbit 2>/dev/null || true
	@sleep 0.2

build: ensure-xcode
	$(XCODEBUILD) build

run: build stop
	open "$(APP)"

clean: stop
	$(XCODEBUILD) clean
	rm -rf "$(DERIVED)"

ensure-create-dmg:
	@if ! command -v "$(CREATE_DMG)" >/dev/null 2>&1 && [ ! -x "$(CREATE_DMG)" ]; then \
		echo "error: create-dmg not found"; \
		echo "Install: brew install create-dmg"; \
		echo "Or clone into tools/: git clone --depth 1 https://github.com/create-dmg/create-dmg.git tools/create-dmg"; \
		exit 1; \
	fi

# Stage RELEASE_APP and build an installer-window DMG (does not notarize).
# Example: make dmg RELEASE_APP=/path/to/stapled/Grabbit.app
dmg: ensure-create-dmg
	@test -d "$(RELEASE_APP)" || { \
		echo "error: RELEASE_APP not found: $(RELEASE_APP)"; \
		echo "Pass a Developer ID–signed, notarized, stapled .app, e.g."; \
		echo "  make dmg RELEASE_APP=/path/to/Grabbit.app"; \
		exit 1; \
	}
	@mkdir -p "$(DMG_ROOT)"
	@rm -rf "$(DMG_ROOT)"/*
	@cp -R "$(RELEASE_APP)" "$(DMG_ROOT)/Grabbit.app"
	@rm -f "$(DMG)"
	"$(CREATE_DMG)" \
		--volname "Grabbit" \
		--window-pos 200 120 \
		--window-size 600 400 \
		--icon-size 100 \
		--icon "Grabbit.app" 150 190 \
		--app-drop-link 450 190 \
		--hide-extension "Grabbit.app" \
		"$(DMG)" \
		"$(DMG_ROOT)"
	@echo ""
	@echo "Created $(DMG)"
	@echo "Next — notarize and staple the DMG (not auto-run):"
	@echo "  xcrun notarytool submit $(DMG) --keychain-profile \"$(NOTARY_PROFILE)\" --wait"
	@echo "  xcrun stapler staple $(DMG)"
	@echo "  spctl --assess --type open --context context:primary-signature -v $(DMG)"
	@echo "Then publish: make release TAG=v0.1.0"

# Publish stapled dist/Grabbit.dmg to GitHub Releases (stable asset name).
# Requires: gh auth login, public repo, TAG=vX.Y.Z
release:
	@test -f "$(DMG)" || { echo "error: missing $(DMG) — run make dmg first"; exit 1; }
	@test -n "$(TAG)" || { echo "error: set TAG=v0.1.0 (or similar)"; exit 1; }
	@GH=$$(command -v gh 2>/dev/null || true); \
	if [ -z "$$GH" ] && [ -x tools/gh/gh ]; then GH=tools/gh/gh; fi; \
	if [ -z "$$GH" ]; then echo "error: gh not found — brew install gh && gh auth login"; exit 1; fi; \
	"$$GH" release create "$(TAG)" "$(DMG)" \
		--title "Grabbit $$(echo '$(TAG)' | sed 's/^v//')" \
		--notes "Notarized macOS build."
	@echo ""
	@echo "Download URL:"
	@echo "  https://github.com/ethanwatsonj/Grabbbit/releases/latest/download/Grabbit.dmg"

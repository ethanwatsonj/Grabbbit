PROJECT        := Grabbit.xcodeproj
SCHEME         := Grabbit
CONFIG         ?= Debug
DERIVED        := .build
DESTINATION    := platform=macOS,arch=arm64
APP            := $(DERIVED)/Build/Products/$(CONFIG)/Grabbit.app

XCODEBUILD     := xcodebuild \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-configuration $(CONFIG) \
	-destination '$(DESTINATION)' \
	-derivedDataPath $(DERIVED)

.PHONY: build run clean

build:
	$(XCODEBUILD) build

run: build
	killall Grabbit 2>/dev/null || true
	sleep 0.3
	open "$(APP)"

clean:
	$(XCODEBUILD) clean
	rm -rf "$(DERIVED)"

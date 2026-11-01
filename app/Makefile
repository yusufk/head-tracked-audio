PROJECT   = HeadTrack.xcodeproj
SCHEME    = HeadTrack
BUILD_DIR = $(CURDIR)/build
APP       = $(BUILD_DIR)/Build/Products/Debug/HeadTrack.app

.PHONY: generate build test run clean

generate:
	xcodegen generate --quiet

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(BUILD_DIR) -allowProvisioningUpdates build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(BUILD_DIR) -allowProvisioningUpdates test

run: build
	open $(APP)

clean:
	rm -rf $(BUILD_DIR) $(PROJECT)

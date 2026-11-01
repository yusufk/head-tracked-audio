PROJECT      = HeadTrack.xcodeproj
SCHEME       = HeadTrack
BUILD_DIR    = $(CURDIR)/build
APP          = $(BUILD_DIR)/Build/Products/Debug/HeadTrack.app
RELEASE_APP  = $(BUILD_DIR)/Build/Products/Release/HeadTrack.app
ENTITLEMENTS = $(CURDIR)/HeadTrack/Resources/HeadTrack.entitlements
PLIST        = $(CURDIR)/HeadTrack/Resources/Info.plist
VERSION     ?= 0.1.0
BUILD_NUMBER ?= 1
DMG          = $(BUILD_DIR)/HeadTrack-v$(VERSION).dmg

.PHONY: generate build test run release dmg clean

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

# Universal, ad-hoc signed Release build (same approach as ZoomacIt: no
# notarisation; the Homebrew cask strips the quarantine flag on install).
release: generate
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(PLIST)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
		build
	@lipo -archs $(RELEASE_APP)/Contents/MacOS/HeadTrack | grep -q arm64 && \
	 lipo -archs $(RELEASE_APP)/Contents/MacOS/HeadTrack | grep -q x86_64 || \
	 { echo "ERROR: binary is not universal"; exit 1; }
	codesign --force --deep --sign - --entitlements $(ENTITLEMENTS) $(RELEASE_APP)
	codesign --verify --deep --strict $(RELEASE_APP)

dmg: release
	rm -rf $(BUILD_DIR)/dmg-staging $(DMG)
	mkdir -p $(BUILD_DIR)/dmg-staging
	cp -R $(RELEASE_APP) $(BUILD_DIR)/dmg-staging/
	ln -s /Applications $(BUILD_DIR)/dmg-staging/Applications
	hdiutil create -volname HeadTrack -srcfolder $(BUILD_DIR)/dmg-staging -ov -format UDZO $(DMG)
	@shasum -a 256 $(DMG)

clean:
	rm -rf $(BUILD_DIR) $(PROJECT)

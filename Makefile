SCHEME := Cleanora
DEST := 'platform=macOS'
APP := $(HOME)/Library/Developer/Xcode/DerivedData/Cleanora-*/Build/Products/Debug/Cleanora.app

.PHONY: project build test run verify clean

project:
	xcodegen generate

build: project
	xcodebuild -project Cleanora.xcodeproj -scheme $(SCHEME) -destination $(DEST) build 2>&1 | tail -20

test: project
	xcodebuild -project Cleanora.xcodeproj -scheme $(SCHEME) -destination $(DEST) test 2>&1 | tail -40

run: build
	open $(APP)

verify: project
	./scripts/verify.sh

clean:
	rm -rf Cleanora.xcodeproj DerivedData

.PHONY: build test app install run zip screenshots clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install: app
	rm -rf /Applications/RamRadar.app
	cp -R build/RamRadar.app /Applications/
	@echo "Installed /Applications/RamRadar.app"

run: app
	open build/RamRadar.app

zip: app
	cd build && ditto -c -k --keepParent RamRadar.app RamRadar-$$(cat ../VERSION).zip

screenshots: build
	.build/debug/RamRadar --snapshot docs/screenshot-light.png --demo
	.build/debug/RamRadar --snapshot docs/screenshot-dark.png --demo --dark
	.build/debug/RamRadar --snapshot docs/screenshot-detail.png --demo --dark --detail "Google Chrome"

clean:
	rm -rf .build build

# Requires macOS + Xcode + xcodegen (brew install xcodegen) and an iPhone with Face ID; the Simulator runs replay mode only.
.PHONY: config project build sim replay fetch-mediapipe open

config:
	@[ -f Config.xcconfig ] || { cp Config.example.xcconfig Config.xcconfig; echo "Created Config.xcconfig - edit HANDGRAB_TEAM_ID"; }

project: config
	xcodegen generate

# then pick your iPhone and press Run; signing team/bundle id come from Config.xcconfig
open: project
	open HandGrab.xcodeproj

build: config
	scripts/build.sh

sim: config
	SDK=iphonesimulator CONF=Debug scripts/build.sh

replay: sim
	scripts/sim-replay.sh synth

fetch-mediapipe:
	scripts/fetch-mediapipe.sh

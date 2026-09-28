# Peakbar: build, test, bundle, sign, install, run.
#
# Toolchain: Command Line Tools only.  xcodebuild is unavailable and
# `swift test` is unusable here (the swift-testing macro plugin fails to load
# without Xcode), so the tests are a plain executable harness compiled with
# swiftc.  See ARCHITECTURE.md §8.

SWIFTC      := xcrun --sdk macosx swiftc
TARGET      := arm64-apple-macosx14.0
BUILD_DIR   := build
BIN         := $(BUILD_DIR)/Peakbar
TEST_BIN    := $(BUILD_DIR)/peakcheck
APP         := $(BUILD_DIR)/Peakbar.app
CONTENTS    := $(APP)/Contents
INSTALL_DIR ?= /Applications

APP_SOURCES := \
	Sources/Model.swift \
	Sources/Holiday.swift \
	Sources/Resolver.swift \
	Sources/Clock.swift \
	Sources/Notifier.swift \
	Sources/App.swift

TEST_SOURCES := \
	Sources/Model.swift \
	Sources/Holiday.swift \
	Sources/Resolver.swift \
	Sources/Clock.swift \
	Sources/Notifier.swift \
	Sources/App.swift \
	Tests/TestMain.swift \
	Tests/ConformanceTests.swift \
	Tests/EdgeCaseTests.swift \
	Tests/HolidaySourceTests.swift

.PHONY: all build test bundle sign install run clean

all: build

# -parse-as-library is required, otherwise @main fails with
# "'main' attribute cannot be used in a module that contains top-level code".
build:
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) -O -parse-as-library -target $(TARGET) -o $(BIN) $(APP_SOURCES)
	@echo "built $(BIN) ($$(stat -f%z $(BIN)) bytes)"

# The harness defines PEAKCHECK, which suppresses the @main attribute in
# App.swift so StatusModel can be driven from Tests/TestMain.swift, and uses
# -parse-as-library because Tests/TestMain.swift declares its own @main.
test:
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) -O -parse-as-library -target $(TARGET) -D PEAKCHECK -o $(TEST_BIN) $(TEST_SOURCES)
	./$(TEST_BIN)

# cn_zh.ics and vectors.json are test fixtures and are deliberately NOT
# shipped in the bundle (§8).
bundle: build
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN) $(CONTENTS)/MacOS/Peakbar
	cp Resources/schedule.json Resources/holidays-2026.json $(CONTENTS)/Resources/
	cp Info.plist $(CONTENTS)/Info.plist

sign: bundle
	codesign --force --sign - $(APP)
	codesign -dv $(APP)

install: sign
	rm -rf "$(INSTALL_DIR)/Peakbar.app"
	cp -R $(APP) "$(INSTALL_DIR)/Peakbar.app"
	@echo "installed to $(INSTALL_DIR)/Peakbar.app"

# Never run the binary directly: UNUserNotificationCenter.current() traps when
# the process has no bundle identifier.
run: bundle
	open $(APP)

clean:
	rm -rf $(BUILD_DIR)

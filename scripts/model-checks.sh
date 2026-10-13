#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
bin="$(swift build -c release --show-bin-path)"
swiftc -swift-version 5 -I "$bin" -Xcc -fmodule-map-file="$PWD/.build/out/Intermediates.noindex/GeneratedModuleMaps/FanStorage.modulemap" "$bin/FanCore.o" "$bin/FanStorage.o" Sources/FanDesk/Model.swift Sources/FanDesk/LaunchContext.swift ModelTests/main.swift -o build/model-checks -framework AppKit -framework ServiceManagement -framework Security -framework IOKit -framework CoreFoundation
build/model-checks

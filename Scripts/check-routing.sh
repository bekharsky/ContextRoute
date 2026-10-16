#!/bin/sh
set -eu

SCRIPT_DIR=$(dirname "$0")
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CHECK_DIR=$(mktemp -d "${TMPDIR:-/private/tmp}/contextroute-checks.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM

xcrun swiftc -O -swift-version 5 \
    -module-cache-path "$CHECK_DIR/module-cache" \
    "$PROJECT_DIR/Sources/ContextRoute/Models.swift" \
    "$PROJECT_DIR/Sources/ContextRoute/WebsiteRoutes.swift" \
    "$PROJECT_DIR/Sources/ContextRoute/Localization.swift" \
    "$PROJECT_DIR/Sources/ContextRoute/BrowserCatalog.swift" \
    "$PROJECT_DIR/Sources/ContextRoute/RoutePlanner.swift" \
    "$PROJECT_DIR/Sources/ContextRoute/BrowserLauncher.swift" \
    "$PROJECT_DIR/Sources/ContextRoute/ChromiumSingleton.swift" \
    "$PROJECT_DIR/Sources/ContextRoute/RoutingDiagnostics.swift" \
    "$PROJECT_DIR/Tests/RoutingChecks.swift" \
    -o "$CHECK_DIR/check-routing"

"$CHECK_DIR/check-routing"

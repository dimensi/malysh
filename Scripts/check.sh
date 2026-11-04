#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-DerivedData}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-Artifacts/Tests.xcresult}"

# RTK is optional; the same checks work with the standard tools alone.
run() {
    if command -v rtk >/dev/null 2>&1; then
        rtk proxy "$@"
    else
        "$@"
    fi
}

run swiftformat Sources Tests UITests Project.swift --lint
run swiftlint lint --strict
run tuist generate --no-open
mkdir -p "$(dirname "$RESULT_BUNDLE_PATH")"
if [[ -e "$RESULT_BUNDLE_PATH" ]]; then
    echo "Каталог результата уже существует: $RESULT_BUNDLE_PATH. Задайте новый RESULT_BUNDLE_PATH или удалите предыдущий результат." >&2
    exit 1
fi
run xcodebuild \
    -workspace Malysh.xcworkspace \
    -scheme Malysh \
    -destination "$DESTINATION" \
    CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    -parallel-testing-enabled NO \
    test

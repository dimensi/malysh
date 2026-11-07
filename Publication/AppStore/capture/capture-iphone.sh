#!/usr/bin/env bash
set -euo pipefail

# Invoke with the UDID of a dedicated Malysh capture simulator.
capture="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${MALYSH_CAPTURE_REPO:-$(cd "$capture/../../.." && pwd)}"
ref="${MALYSH_CAPTURE_REF:-v1.13.0}"
udid="${1:?Usage: capture-iphone.sh UDID [raw-directory] [XCTest-selection]}"
output="${2:-$capture/../raw}"
selection="${3:-MalyshUITests/StorefrontScenes}"
mkdir -p "$output"

run() {
    if command -v rtk >/dev/null 2>&1; then
        rtk proxy "$@"
    else
        "$@"
    fi
}

device="$(run xcrun simctl list devices -j | python3 -c '
import json,sys
devices = json.load(sys.stdin)["devices"]
print(next((d["name"] for runtime, group in devices.items() if ".iOS-" in runtime
            for d in group if d["udid"] == sys.argv[1]), ""))
' "$udid")"
[[ "$device" == "Malysh – App Store Launch"* ]] || {
    echo "The capture device must be a dedicated simulator named Malysh – App Store Launch." >&2
    exit 1
}

build="${MALYSH_CAPTURE_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/malysh-storefront.XXXXXX")}"
mkdir -p "$build/source"
echo "Capture build directory: $build"
run git -C "$repo" archive "$ref" Malysh.xcodeproj Malysh.xcworkspace Derived Resources \
    Sources Tests UITests WidgetExtension WatchApp WatchShared WatchWidgets \
    | run tar -x -C "$build/source"
python3 - "$capture" "$build/source" <<'PY'
import pathlib, plistlib, sys

capture, build = map(pathlib.Path, sys.argv[1:])
store = build / "Sources/AppStore.swift"
source = store.read_text()
needle = 'if arguments.contains("--ui-testing"), !arguments.contains("--test-onboarding") {'
assert source.count(needle) == 1
source = source.replace(needle, needle + """
                    #if targetEnvironment(simulator)
                        if arguments.contains("--storefront-fixture"), try persistence.babies().isEmpty {
                            try prepareStorefrontFixture()
                        }
                    #endif
""")
reminder_needle = '        let suite = testing ? "dev.dimensi.malysh.feeding-reminders.ui-testing" :'
assert source.count(reminder_needle) == 1
source = source.replace(reminder_needle, """
        #if DEBUG && targetEnvironment(simulator)
            if testing, arguments.contains("--storefront-reminder-system") {
                let suite = "dev.dimensi.malysh.feeding-reminders.storefront"
                let defaults = UserDefaults(suiteName: suite)!
                if arguments.contains("--reset-data") {
                    defaults.removePersistentDomain(forName: suite)
                }
                return FeedingReminderService(defaults: defaults)
            }
        #endif
""" + reminder_needle)
store.write_text(source + (capture / "Fixture.swift").read_text())
# Preserve the local widget App Group while removing all CloudKit and APS entitlement paths.
entitlements = build / "Resources/Malysh.entitlements"
existing = plistlib.loads(entitlements.read_bytes())
key = "com.apple.security.application-groups"
entitlements.write_bytes(plistlib.dumps({key: existing[key]}))
# Preserve the actual file written by the native PDF flow for marketing export.
pdf = build / "Sources/DiaryPDFReportView.swift"
pdf_source = pdf.read_text()
pdf_source = pdf_source.replace("try file.protectContents()", """try file.protectContents()
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--storefront-fixture") {
                    let export = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("StorefrontReport.pdf")
                    try? FileManager.default.removeItem(at: export)
                    try FileManager.default.copyItem(at: file.url, to: export)
                }
                #endif""")
pdf.write_text(pdf_source)
tests = build / "UITests/MalyshUITests.swift"
tests.write_text(tests.read_text() + (capture / "Scenes.swift").read_text()
                 + (capture / "features/FeatureScenes.swift").read_text())
widget = build / "UITests/WidgetSystemUITests.swift"
widget_source, trailing = widget.read_text().rsplit("}", 1)
widget.write_text(widget_source + (capture / "WidgetScene.swift").read_text() + "}" + trailing)

PY
python3 "$capture/album.py" "$build/source/Resources/Assets.xcassets"

# Use the real clock so that the status bar agrees with the seeded diary's dates.
run xcrun simctl status_bar "$udid" clear
run xcrun simctl status_bar "$udid" override --operatorName "" --dataNetwork wifi \
    --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
run xcrun simctl ui "$udid" appearance light

result="$(mktemp -d "$build/results.XXXXXX")"
extra=()
if [[ "$selection" == "MalyshUITests/StorefrontScenes" ]]; then
    extra=(-skip-testing:MalyshUITests/StorefrontScenes/testToday -skip-testing:MalyshUITests/StorefrontScenes/testDuoScreens -skip-testing:MalyshUITests/StorefrontScenes/testSupportLinksAtAccessibilitySize)
fi
for additional in "${@:4}"; do
    extra+=("-only-testing:$additional")
done
status=0
run xcodebuild -workspace "$build/source/Malysh.xcworkspace" -scheme Malysh -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" -parallel-testing-enabled NO \
    -derivedDataPath "$build/DerivedData" -resultBundlePath "$result/Capture.xcresult" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -only-testing:"$selection" ${extra[@]+"${extra[@]}"} test || status=$?

if [[ -d "$result/Capture.xcresult" ]]; then
    run xcrun xcresulttool export attachments --path "$result/Capture.xcresult" --output-path "$result/attachments"
    if [[ "${MALYSH_CAPTURE_NATIVE_DISPLAY:-}" != "3" ]]; then
        python3 "$capture/finalize-capture.py" "$capture" "$repo" "$ref" "$udid" "$result/attachments" "$output"
    fi
fi
exit "$status"

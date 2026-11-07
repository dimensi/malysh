#!/usr/bin/env bash
set -euo pipefail

capture="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${MALYSH_CAPTURE_REPO:-$(cd "$capture/../../.." && pwd)}"
ref="${MALYSH_CAPTURE_REF:-v1.13.0}"
udid="${1:?Usage: capture-watch.sh WATCH-UDID [raw-directory]}"
output="${2:-$capture/../raw/watch}"
build="${MALYSH_WATCH_CAPTURE_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/malysh-watch-storefront.XXXXXX")}"
bundle_id=dev.dimensi.malysh.watchkitapp
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
print(next((d["name"] for k,g in devices.items() if ".watchOS-" in k for d in g if d["udid"] == sys.argv[1]), ""))
' "$udid")"
[[ "$device" == "Malysh – App Store Launch Watch"* ]] || {
    echo "The capture device must be a dedicated Watch simulator named Malysh – App Store Launch Watch." >&2
    exit 1
}

# This build uses the unmodified watchOS source and ad hoc simulator signing.
if [[ -n "${MALYSH_WATCH_CAPTURE_APP:-}" ]]; then
    app="$MALYSH_WATCH_CAPTURE_APP"
else
    mkdir -p "$build/source"
    run git -C "$repo" archive "$ref" Malysh.xcodeproj Malysh.xcworkspace Derived Resources \
        Sources Tests UITests WidgetExtension WatchApp WatchShared WatchWidgets | run tar -x -C "$build/source"
    run xcodebuild -workspace "$build/source/Malysh.xcworkspace" -scheme MalyshWatch -configuration Debug \
        -destination "platform=watchOS Simulator,id=$udid" -derivedDataPath "$build" \
        CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
    app="$build/Build/Products/Debug-watchsimulator/MalyshWatch.app"
fi
run xcrun simctl install "$udid" "$app"
group="$(run xcrun simctl get_app_container "$udid" "$bundle_id" group.dev.dimensi.malysh)"
[[ -d "$group" && "$group" == *"/$udid/data/Containers/Shared/AppGroup/"* ]]

snapshot="$group/WatchDiary.json"
# These changes affect only the designated simulator's local App Group.
run xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
python3 "$capture/watch-fixture.py" "$snapshot" home
run xcrun simctl launch "$udid" "$bundle_id" -AppleLanguages '(ru)' -AppleLocale ru_RU
sleep 8
run xcrun simctl io "$udid" screenshot "$output/01-watch-diary.png"

run xcrun simctl terminate "$udid" "$bundle_id"
python3 "$capture/watch-fixture.py" "$snapshot" active
run xcrun simctl launch "$udid" "$bundle_id" -AppleLanguages '(ru)' -AppleLocale ru_RU
sleep 8
run xcrun simctl io "$udid" screenshot "$output/02-watch-feeding.png"

run xcrun simctl terminate "$udid" "$bundle_id"
python3 "$capture/watch-fixture.py" "$snapshot" sleep
run xcrun simctl launch "$udid" "$bundle_id" -AppleLanguages '(ru)' -AppleLocale ru_RU
sleep 8
run xcrun simctl io "$udid" screenshot "$output/03-watch-sleep.png"

python3 "$capture/record-provenance.py" --repo "$repo" --release "$ref" --udid "$udid" \
    "$output/01-watch-diary.png" "$output/02-watch-feeding.png" "$output/03-watch-sleep.png"

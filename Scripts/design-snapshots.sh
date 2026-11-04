#!/usr/bin/env bash
# Record candidates explicitly, or compare approved resources without modifying them.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
MODE="${1:-verify}"
case "$MODE" in
    record) export RECORD_DESIGN_BASELINES=1 ;;
    verify) export RECORD_DESIGN_BASELINES=0 ;;
    *) echo 'Usage: bash Scripts/design-snapshots.sh record|verify' >&2; exit 2 ;;
esac
export DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-DerivedData/DesignSystem}"
export RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-Artifacts/DesignSystem-$MODE.xcresult}"
export DESIGN_OUTPUT_PATH="${DESIGN_OUTPUT_PATH:-Artifacts/DesignBaselines-$MODE}"
[[ ! -e "$RESULT_BUNDLE_PATH" && ! -e "$DESIGN_OUTPUT_PATH" ]] || {
    echo 'Result/output already exists. Set unique RESULT_BUNDLE_PATH and DESIGN_OUTPUT_PATH.' >&2
    exit 1
}
python3 Scripts/check-design-system.py
if [[ -z "${DESTINATION:-}" ]]; then
    SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 Scripts/simulator-id.py)"
    DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi
mkdir -p "$DESIGN_OUTPUT_PATH" "$(dirname "$RESULT_BUNDLE_PATH")"
xcodebuild -workspace Malysh.xcworkspace -scheme Malysh \
    -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA_PATH" CODE_SIGNING_ALLOWED=NO \
    -only-testing:MalyshTests/DesignSystemSnapshotTests build-for-testing
python3 - <<'PY'
import os, pathlib, plistlib
paths = list((pathlib.Path(os.environ["DERIVED_DATA_PATH"]) / "Build/Products").glob("*.xctestrun"))
if len(paths) != 1:
    raise SystemExit("Expected exactly one generated xctestrun file")
path = paths[0]
with path.open("rb") as source:
    data = plistlib.load(source)
targets = [target for config in data.get("TestConfigurations", []) for target in config.get("TestTargets", [])]
if not targets:
    targets = [target for target in data.values() if isinstance(target, dict) and "TestBundlePath" in target]
if not targets:
    raise SystemExit("No test targets found in xctestrun")
for target in targets:
    target.setdefault("EnvironmentVariables", {})["RECORD_DESIGN_BASELINES"] = os.environ["RECORD_DESIGN_BASELINES"]
with path.open("wb") as output:
    plistlib.dump(data, output)
(pathlib.Path(os.environ["DESIGN_OUTPUT_PATH"]) / "xctestrun-path").write_text(str(path))
PY
XCTESTRUN="$(cat "$DESIGN_OUTPUT_PATH/xctestrun-path")"
test_status=0
xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
    -destination "$DESTINATION" -parallel-testing-enabled NO \
    -only-testing:MalyshTests/DesignSystemSnapshotTests \
    -resultBundlePath "$RESULT_BUNDLE_PATH" CODE_SIGNING_ALLOWED=NO || test_status=$?
if [[ -d "$RESULT_BUNDLE_PATH" ]]; then
    # These commands must remain sequential: xcresulttool may mutate the bundle database.
    xcrun xcresulttool export attachments --path "$RESULT_BUNDLE_PATH" \
        --output-path "$DESIGN_OUTPUT_PATH/attachments"
    xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE_PATH" \
        > "$DESIGN_OUTPUT_PATH/test-summary.json"
    python3 - <<'PY'
import hashlib, json, os, pathlib, re, shutil
output = pathlib.Path(os.environ["DESIGN_OUTPUT_PATH"])
source = output / "attachments"
images = []
candidate_paths = []
metadata = None
groups = json.loads((source / "manifest.json").read_text())
for group in groups:
    for item in group.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "")
        # XCTest adds an attachment index and UUID before the filename extension.
        name = re.sub(r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?=\.(?:png|json)$)", "", name)
        path = source / item["exportedFileName"]
        data = path.read_bytes()
        if name == "design-baseline-manifest.json":
            metadata = json.loads(data)
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            continue
        candidate = re.fullmatch(r"design-baseline-(iOS-\d+)-(gallery-(?:light|dark)-(?:large|accessibility3))\.png", name)
        if candidate:
            destination = output / candidate[1] / (candidate[2] + ".png")
            candidate_paths.append(str(destination.relative_to(output)))
        else:
            destination = output / "comparison" / pathlib.Path(name).name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        images.append({"path": str(destination.relative_to(output)), "sha256": hashlib.sha256(data).hexdigest()})
recording = os.environ["RECORD_DESIGN_BASELINES"] == "1"
(output / "manifest.json").write_text(json.dumps({
    "mode": "record" if recording else "verify", "requiresVisualApproval": recording,
    "rendering": metadata, "images": images,
}, indent=2))
(output / "xctestrun-path").unlink(missing_ok=True)
if recording:
    variants = {"gallery-light-large", "gallery-dark-large", "gallery-light-accessibility3", "gallery-dark-accessibility3"}
    if metadata is None or set(metadata.get("variants", [])) != variants:
        raise SystemExit("Recording requires the four-variant rendering manifest; raw attachments retained")
    expected = {f"{metadata['system']}/{variant}.png" for variant in variants}
    if len(candidate_paths) != 4 or set(candidate_paths) != expected or len(images) != 4:
        raise SystemExit("Recording must export exactly four unique gallery candidates; raw attachments retained")
shutil.rmtree(source)
PY
fi
exit "$test_status"

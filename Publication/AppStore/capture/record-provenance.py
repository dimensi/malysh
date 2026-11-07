#!/usr/bin/env python3
"""Record baseline metadata for actual captured files; never infer it from folder names."""
import argparse, datetime, hashlib, json, pathlib, struct, subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--release", default="v1.13.0")
parser.add_argument("--repo")
parser.add_argument("--commit")
parser.add_argument("--device")
parser.add_argument("--runtime")
parser.add_argument("--udid")
parser.add_argument("files", nargs="+")
args = parser.parse_args()
if args.repo:
    args.commit = subprocess.check_output(["git", "-C", args.repo, "rev-parse", args.release + "^{commit}"], text=True).strip()
if args.udid and (not args.device or not args.runtime):
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
    found = [(runtime, device) for runtime, devices in inventory["devices"].items()
             for device in devices if device["udid"] == args.udid]
    if len(found) != 1: parser.error("Capture simulator not found: " + args.udid)
    runtime, device = found[0]
    args.device = device.get("deviceTypeIdentifier", device["name"]).split(".")[-1].replace("-", " ")
    args.runtime = runtime.split(".")[-1]
if not all([args.commit, args.device, args.runtime]):
    parser.error("Supply --repo/--udid or explicit --commit/--device/--runtime")
base = pathlib.Path(__file__).resolve().parent.parent
manifest = base / "capture/provenance.json"
data = json.loads(manifest.read_text()) if manifest.exists() else {"sources": {}}
data.update({"release": args.release, "commit": args.commit})
for filename in args.files:
    path = pathlib.Path(filename).resolve()
    relative = path.relative_to(base).as_posix()
    raw = path.read_bytes()
    item = {
        "release": args.release, "commit": args.commit,
        "device": args.device, "runtime": args.runtime,
        "scene": path.stem, "sha256": hashlib.sha256(raw).hexdigest(),
        "exportedAt": datetime.datetime.fromtimestamp(path.stat().st_mtime, datetime.timezone.utc).isoformat(),
        "method": "native simulator screenshot",
        "fixture": "capture/watch-fixture.py" if "/watch/" in relative else "capture/Fixture.swift",
        "syntheticData": True,
    }
    if args.udid: item["simulatorUDID"] = args.udid
    if path.suffix.lower() == ".png":
        if raw[:8] != b"\x89PNG\r\n\x1a\n": raise ValueError("Not a PNG: " + filename)
        width, height = struct.unpack(">II", raw[16:24])
        item["dimensions"] = [width, height]
    if path.name == "15-pediatrician-report.png": item["method"] = "first page raster of native exported PDF, unmodified content"
    if path.suffix.lower() == ".pdf": item["method"] = "native app PDF export, copied unchanged from isolated Documents"
    data["sources"][relative] = item
temporary = manifest.with_suffix(".json.tmp")
temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
temporary.replace(manifest)
print(manifest)

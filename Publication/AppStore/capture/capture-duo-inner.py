#!/usr/bin/env python3
"""XCTest navigates; simctl captures display 3 while each real screen is held."""
import json, os, pathlib, shutil, struct, subprocess, sys, tempfile, time

capture = pathlib.Path(__file__).resolve().parent
udid = sys.argv[1]
output = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else capture.parent / "raw/duo-inner").resolve()
output.parent.mkdir(parents=True, exist_ok=True)
repository = os.environ.get("MALYSH_CAPTURE_REPO", str(capture.parents[2]))
release = os.environ.get("MALYSH_CAPTURE_REF", "v1.13.0")
names = ["01-today", "04-history", "05-statistics"]
staging = pathlib.Path(tempfile.mkdtemp(prefix="duo-inner-capture."))
log = staging / "capture.log"
environment = dict(os.environ, MALYSH_CAPTURE_NATIVE_DISPLAY="3")
with log.open("w") as stream:
    process = subprocess.Popen(["bash", str(capture / "capture-iphone.sh"), udid, str(output),
                                "MalyshUITests/StorefrontScenes/testDuoScreens"],
                               env=environment, stdout=stream, stderr=subprocess.STDOUT)
    completed = set()
    while process.poll() is None:
        text = log.read_text(errors="replace")
        for name in names:
            if name not in completed and "Added attachment named '" + name + "'" in text:
                subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", "--display=3",
                                str(staging / (name + ".png"))], check=True)
                completed.add(name)
        time.sleep(0.2)
    status = process.wait()
if status or completed != set(names):
    raise RuntimeError("Duo capture incomplete; inspect " + str(log))
for name in names:
    source = staging / (name + ".png")
    size = struct.unpack(">II", source.read_bytes()[16:24])
    if size not in [(2853, 2007), (2007, 2853)]: raise ValueError("Wrong inner dimensions: " + str(size))
    mean = float(subprocess.check_output(["magick", str(source), "-format", "%[fx:mean]", "info:"], text=True))
    if mean < 0.001: raise ValueError("Black inner screenshot rejected: " + str(source))
output.mkdir(parents=True, exist_ok=True)
for name in names:
    target = output / (name + ".png")
    temporary = target.with_suffix(".capturing")
    shutil.copyfile(staging / (name + ".png"), temporary)
    temporary.replace(target)
subprocess.run([sys.executable, str(capture / "record-provenance.py"), "--repo", repository,
                "--release", release, "--udid", udid, *[str(output / (n + ".png")) for n in names]], check=True)
print("Native inner display captured. Driver log: " + str(log))

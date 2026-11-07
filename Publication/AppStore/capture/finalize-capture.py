#!/usr/bin/env python3
"""Export actual XCTest attachments and the native PDF, then record their baseline."""
import json, pathlib, re, shutil, subprocess, sys
capture, repo, release, udid, attachments, output = sys.argv[1:]
capture, attachments, output = map(pathlib.Path, [capture, attachments, output])
files = []
for test in json.loads((attachments / "manifest.json").read_text()):
    for item in test["attachments"]:
        match = re.match(r"^(\d+[a-z]?-[a-z-]+)(?=[_.]|$)", item["suggestedHumanReadableName"])
        if match and item["exportedFileName"].lower().endswith(".png"):
            target = output / (match[1] + ".png")
            temporary = target.with_suffix(".capturing")
            shutil.copyfile(attachments / item["exportedFileName"], temporary)
            temporary.replace(target)
            files.append(str(target.resolve()))
            print(target)
if any(pathlib.Path(file).name == "15-pediatrician-pdf.png" for file in files):
    container = pathlib.Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", udid,
                                                     "dev.dimensi.malysh", "data"], text=True).strip())
    original = container / "Documents/StorefrontReport.pdf"
    if not original.is_file(): raise FileNotFoundError("Native export missing: " + str(original))
    pdf, png = output / "15-pediatrician-report.pdf", output / "15-pediatrician-report.png"
    shutil.copyfile(original, pdf)
    subprocess.run(["swift", str(capture / "raster-pdf.swift"), str(pdf), str(png)], check=True)
    files += [str(pdf.resolve()), str(png.resolve())]
if files:
    subprocess.run([sys.executable, str(capture / "record-provenance.py"), "--repo", repo,
                    "--release", release, "--udid", udid, *files], check=True)

"""Reject custom palette/radius/font bypasses outside their shared definitions."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKEN_FILE = pathlib.Path("Sources/DesignSystem.swift")
WIDGET_FILE = pathlib.Path("WidgetExtension/CareLiveActivityWidget.swift")

# The widget is a separate target: it shares named assets, while the Island is always black.
# Only these existing asset/contrast constructors are allowed; RGB/hex and fixed fonts are not.
WIDGET_CONSTRUCTORS = [
    re.compile(r'Color\(\s*"AccentColor"\s*\)'),
    re.compile(r'Color\(\s*kind\s*==\s*\.breast\s*\?\s*"Feeding"\s*:\s*"Sleep"\s*\)'),
    re.compile(r'UIColor\(\s*named:\s*kind\s*==\s*\.breast\s*\?\s*"Feeding"\s*:\s*"Sleep"\s*\)'),
    re.compile(r"Color\(\s*uiColor:\s*\.systemBackground\s*\)"),
    re.compile(r"Color\(\s*uiColor:\s*color\.resolvedColor\(with:\s*UITraitCollection\(userInterfaceStyle:\s*\.light\)\)\s*\)"),
]

# Native Dynamic Type and SwiftUI's primary/secondary/tertiary/tint styles remain valid.
# Error/success/category colors belong to the palette, not to per-view exceptions.
RULES = [
    (re.compile(r"\b(?:Color|UIColor)\s*\("), "Use AppDesign.Palette instead of constructing a UI color"),
    (re.compile(r"#colorLiteral\s*\("), "Use the shared asset palette instead of an RGB color literal"),
    (re.compile(r"\b(?:Color|UIColor)\.(?:red|green|blue|orange|yellow|purple|pink|cyan|mint|indigo|black|white)\b"),
     "Use AppDesign.Palette instead of a hardcoded UI color"),
    (re.compile(r"\bcornerRadius\s*:\s*[-\d.]|\.cornerRadius\s*\(\s*[-\d.]"),
     "Use AppDesign.Radius for custom rounded surfaces"),
    (re.compile(r"(?:\.font\s*\(\s*\.system|Font\.system)\s*\(\s*size\s*:\s*[\d.]"),
     "Use Dynamic Type typography instead of a fixed font size"),
    (re.compile(r"\.(?:foregroundStyle|foregroundColor|background|tint)\s*\(\s*\.(?:red|green|blue|orange|yellow|purple|pink|cyan|mint|indigo|black|white)\b"),
     "Use the shared palette or an explicitly approved native status color"),
]


def widget_semantic_exception(code, match, message):
    if "constructing a UI color" in message:
        return any(pattern.match(code, match.start()) for pattern in WIDGET_CONSTRUCTORS)
    start = code.rfind("\n", 0, match.start()) + 1
    end = code.find("\n", match.end())
    line = code[start:end if end != -1 else len(code)]
    if "hardcoded UI color" in message:
        return re.search(r"\.foregroundStyle\(island\s*\?\s*Color\.black\s*:\s*Color\(uiColor:\s*\.systemBackground\)\)", line) is not None
    if "status color" in message:
        return line.strip() == ".foregroundStyle(.white)"
    return False


def violations(path, source):
    if path == TOKEN_FILE:
        return []
    failures = []
    code = re.sub(r"//[^\n]*", "", source)
    for pattern, message in RULES:
        for match in pattern.finditer(code):
            if path == WIDGET_FILE and widget_semantic_exception(code, match, message):
                continue
            number = code.count("\n", 0, match.start()) + 1
            failures.append(f"{path.as_posix()}:{number}: {message}")
    return failures


def main():
    failures = []
    for folder in ("Sources", "WidgetExtension"):
        for path in sorted((ROOT / folder).rglob("*.swift")):
            failures.extend(violations(path.relative_to(ROOT), path.read_text()))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Design-system style gate passed (native typography and semantic text styles allowed).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

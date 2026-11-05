#!/usr/bin/env python3
"""Prepare and inspect CloudKit schema; production is always read-only."""

import argparse
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEAM = "YBBAN7R28K"
CONTAINER = "iCloud.dev.dimensi.malysh"
SCHEMA = ROOT / "CloudKit/development.ckdb"
REPORT = ROOT / "Artifacts/CloudKit/report.json"


class SchemaError(Exception):
    pass


# Tokenize comments before identifiers, preserving comment markers inside quotes.
TOKEN = re.compile(r'\s+|//[^\n]*|--[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z_0-9.]*|[(),;<>]')
PRIMITIVES = {"ASSET", "BYTES", "DOUBLE", "INT64", "LOCATION", "REFERENCE", "STRING", "TIMESTAMP"}
INDEXES = {"QUERYABLE", "SORTABLE", "SEARCHABLE"}
IMPLICIT = {"___createTime": "TIMESTAMP", "___createdBy": "REFERENCE", "___etag": "STRING",
            "___modTime": "TIMESTAMP", "___modifiedBy": "REFERENCE", "___recordID": "REFERENCE"}


def parse_schema(source):
    tokens = []
    pos = 0
    while pos < len(source):
        match = TOKEN.match(source, pos)
        if not match:
            raise SchemaError("Unsupported CKDB syntax at offset %d" % pos)
        value = match.group()
        pos = match.end()
        if value.isspace() or value.startswith(("//", "--", "/*")):
            continue
        if value.startswith('"'):
            try:
                tokens.append((json.loads(value), True))
            except ValueError as error:
                raise SchemaError("Unsupported quoted identifier") from error
        else:
            tokens.append((value, False))
    cursor = 0

    def peek(word):
        return cursor < len(tokens) and not tokens[cursor][1] and tokens[cursor][0].upper() == word

    def take(word):
        nonlocal cursor
        if not peek(word):
            raise SchemaError("Expected %s at token %d" % (word, cursor))
        cursor += 1

    def identifier():
        nonlocal cursor
        if cursor >= len(tokens):
            raise SchemaError("Missing identifier")
        value, quoted = tokens[cursor]
        if not quoted and not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9.]*', value):
            raise SchemaError("Invalid identifier")
        cursor += 1
        return value

    def field_type():
        if peek("ENCRYPTED"):
            take("ENCRYPTED")
            value = identifier().upper()
            if value not in {"BYTES", "STRING", "DOUBLE", "INT64", "LOCATION", "TIMESTAMP"}:
                raise SchemaError("Unsupported encrypted type")
            return "ENCRYPTED " + value
        if peek("LIST"):
            take("LIST")
            take("<")
            inner = field_type()
            if inner.startswith("LIST"):
                raise SchemaError("Nested LIST is unsupported")
            take(">")
            return "LIST<%s>" % inner
        if peek("NUMBER"):
            take("NUMBER")
            if not peek("PREFERRED"):
                return "NUMBER"
            take("PREFERRED")
            take("AS")
            value = identifier().upper()
            if value not in {"DOUBLE", "INT64"}:
                raise SchemaError("Unknown NUMBER preference")
            return "NUMBER PREFERRED AS " + value
        value = identifier().upper()
        if value not in PRIMITIVES:
            raise SchemaError("Unknown field type: " + value)
        return value

    take("DEFINE")
    take("SCHEMA")
    if peek(";"):
        take(";")
    result = {"roles": ["_creator", "_world", "_icloud"], "records": {}}
    while cursor < len(tokens):
        if peek("CREATE"):
            take("CREATE")
            take("ROLE")
            role = identifier()
            take(";")
            if role in result["roles"] and role not in {"_creator", "_world", "_icloud"}:
                raise SchemaError("Duplicate role")
            if role not in result["roles"]:
                result["roles"].append(role)
            continue
        take("RECORD")
        take("TYPE")
        name = identifier()
        if name in result["records"]:
            raise SchemaError("Duplicate record type")
        take("(")
        record = {"fields": {}, "grants": []}
        while not peek(")"):
            if peek("GRANT"):
                take("GRANT")
                permissions = [identifier().upper()]
                while peek(","):
                    take(",")
                    permissions.append(identifier().upper())
                if not set(permissions) <= {"READ", "WRITE", "CREATE"}:
                    raise SchemaError("Unknown grant")
                take("TO")
                role = identifier()
                record["grants"].extend((permission, role) for permission in permissions)
            else:
                field = identifier()
                if field in record["fields"]:
                    raise SchemaError("Duplicate field")
                kind = field_type()
                options = []
                while cursor < len(tokens) and tokens[cursor][0].upper() in INDEXES and not tokens[cursor][1]:
                    option = identifier().upper()
                    if option in options:
                        raise SchemaError("Duplicate field option")
                    options.append(option)
                record["fields"][field] = {"type": kind, "options": sorted(options)}
            if not peek(","):
                break
            take(",")
        take(")")
        take(";")
        record["grants"] = sorted(set(record["grants"]))
        for field, kind in IMPLICIT.items():
            record["fields"].setdefault(field, {"type": kind, "options": []})
        result["records"][name] = record
    result["roles"].sort()
    return result


def incompatible(baseline, candidate):
    errors = []
    for role in baseline["roles"]:
        if role not in candidate["roles"]:
            errors.append("Removed role: " + role)
    for name, old in baseline["records"].items():
        new = candidate["records"].get(name)
        if new is None:
            errors.append("Removed record type: " + name)
            continue
        if old["grants"] != new["grants"]:
            errors.append("Changed permissions: " + name)
        for field, definition in old["fields"].items():
            replacement = new["fields"].get(field)
            if replacement is None:
                errors.append("Removed field: " + name + "." + field)
            elif definition["type"] != replacement["type"]:
                errors.append("Changed field type/encryption: " + name + "." + field)
            elif not set(definition["options"]) <= set(replacement["options"]):
                errors.append("Removed index: " + name + "." + field)
    return sorted(errors)


def canonical(schema):
    return json.dumps(schema, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix="." + path.name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def cktool(command, environment, *arguments):
    # Never forward captured output: cktool errors may contain sensitive details.
    args = ["xcrun", "cktool", command, "--team-id", TEAM, "--container-id", CONTAINER,
            "--environment", environment, *map(str, arguments)]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        hint = "check management-token access and network locally" if command == "export-schema" else "inspect schema syntax and cktool diagnostics locally"
        raise SchemaError("cktool %s (%s) failed with exit %d; %s" %
                          (command, environment, result.returncode, hint))


def run(command="prepare", dry_run=False, confirm=False):
    dry_run = dry_run or command == "check"
    if command == "import-development" and not confirm:
        raise SchemaError("import-development requires --confirm-import-development")
    atomic_write(REPORT, json.dumps({"command": command, "status": "incomplete", "compatible": None}) + "\n")
    with tempfile.TemporaryDirectory(prefix="malysh-cloudkit-") as temporary:
        paths = {env: Path(temporary) / (env + ".ckdb") for env in ("development", "production")}
        schemas = {}
        for env, path in paths.items():
            cktool("export-schema", env, "--output-file", path)
            if not path.is_file() or not path.stat().st_size:
                raise SchemaError("Missing or empty " + env + " export")
            schemas[env] = parse_schema(path.read_text(encoding="utf-8"))
        candidate_path = SCHEMA if command in {"import-development", "verify-production"} else paths["development"]
        if not candidate_path.is_file():
            raise SchemaError("No versioned schema; run prepare after configuring credentials")
        candidate_text = candidate_path.read_text(encoding="utf-8")
        candidate = parse_schema(candidate_text)
        cktool("validate-schema", "development", "--file", candidate_path)
        errors = incompatible(schemas["production"], candidate)
        if command == "import-development":
            errors += incompatible(schemas["development"], candidate)
        diff = list(difflib.unified_diff(canonical(schemas["production"]).splitlines(),
                                        canonical(candidate).splitlines(), fromfile="production", tofile="candidate", lineterm=""))
        if command == "verify-production" and schemas["production"] != candidate:
            errors.append("Production differs from versioned schema")
        report = {"command": command, "status": "checked", "team": TEAM, "container": CONTAINER,
                  "compatible": not errors, "errors": sorted(set(errors)), "diff": diff, "dry_run": dry_run}
        report["next_action"] = ("CloudKit Console: review Development → Deploy Schema Changes → Production for " + CONTAINER
                                 if diff else "Production matches candidate; no schema deployment needed")
        atomic_write(REPORT, json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        if errors:
            raise SchemaError("; ".join(sorted(set(errors))))
        if command == "prepare" and not dry_run:
            # Retain exact real export, but avoid rewriting for formatting/order-only changes.
            if not SCHEMA.exists() or parse_schema(SCHEMA.read_text(encoding="utf-8")) != candidate:
                atomic_write(SCHEMA, candidate_text)
        if command == "import-development" and not dry_run and schemas["development"] != candidate:
            report["status"] = "import-incomplete"
            atomic_write(REPORT, json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            cktool("import-schema", "development", "--validate", "--file", candidate_path)
            verified_path = Path(temporary) / "verified-development.ckdb"
            cktool("export-schema", "development", "--output-file", verified_path)
            if parse_schema(verified_path.read_text(encoding="utf-8")) != candidate:
                raise SchemaError("Development after import differs from candidate")
            report["status"] = "import-verified"
            atomic_write(REPORT, json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", default="prepare", choices=["prepare", "check", "import-development", "verify-production"])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--confirm-import-development", action="store_true")
    args = parser.parse_args()
    try:
        report = run(args.command, args.dry_run or args.command == "check", args.confirm_import_development)
        print("CloudKit schema checked. Production is read-only. Report: " + str(REPORT.relative_to(ROOT)))
        print("\n".join(report["diff"]) or "No semantic schema changes.")
        print(report["next_action"])
    except (SchemaError, OSError, UnicodeError) as error:
        print("CloudKit schema: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

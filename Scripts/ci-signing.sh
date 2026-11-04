#!/bin/bash
# Temporary, job-scoped signing material for GitHub Actions macOS runners.
set -eEuo pipefail
umask 077

fail() { printf '%s\n' "$1" >&2; exit 1; }

resolve_directory() {
    [[ "${RUNNER_TEMP:-}" == /* ]] || fail "RUNNER_TEMP must be an absolute path."
    [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]] || fail "Invalid GITHUB_RUN_ID."
    [[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || fail "Invalid GITHUB_RUN_ATTEMPT."
    signing_dir="${RUNNER_TEMP%/}/malysh-signing-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
    [[ ! -L "$signing_dir" ]] || fail "Signing directory must not be a symlink."
}

cleanup() {
    # An always() workflow step can run even when setup never started.
    [[ -n "${RUNNER_TEMP:-}" && -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_RUN_ATTEMPT:-}" ]] || return 0
    resolve_directory
    [[ -d "$signing_dir" ]] || return 0
    local cleanup_failed=0
    if [[ -f "$signing_dir/original-keychains.txt" ]]; then
        local keychains=() item
        while IFS= read -r item; do
            [[ -n "$item" ]] && keychains[${#keychains[@]}]="$item"
        done < "$signing_dir/original-keychains.txt"
        if [[ ${#keychains[@]} -gt 0 ]]; then
            security list-keychains -d user -s "${keychains[@]}" >/dev/null || cleanup_failed=1
        else
            security list-keychains -d user -s >/dev/null || cleanup_failed=1
        fi
    fi
    if [[ -f "$signing_dir/keychain-created" && -f "$signing_dir/signing.keychain-db" ]]; then
        security delete-keychain "$signing_dir/signing.keychain-db" >/dev/null 2>&1 || cleanup_failed=1
    fi
    # Validate the UUID, exact destination, and content before removing a profile.
    local profile_status=0
    python3 - "$signing_dir" "${HOME:?}" <<'PYPROFILECLEAN' || profile_status=$?
import json, pathlib, re, sys
root, home = map(pathlib.Path, sys.argv[1:])
for state in [root / "installed-profile.json", root / "installed-widget-profile.json"]:
    if not state.exists():
        continue
    info = json.loads(state.read_text())
    uuid = info["uuid"]
    if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", uuid):
        raise SystemExit("Invalid installed-profile state; refusing removal.")
    expected = home / "Library/Developer/Xcode/UserData/Provisioning Profiles" / (uuid + ".mobileprovision")
    if info["path"] != str(expected):
        raise SystemExit("Unexpected profile path; refusing removal.")
    if expected.is_symlink():
        raise SystemExit("Profile is now a symlink; refusing removal.")
    if expected.exists():
        stat = expected.stat()
        if stat.st_dev != info["device"] or stat.st_ino != info["inode"]:
            raise SystemExit("Profile ownership changed; refusing removal.")
        expected.unlink()
PYPROFILECLEAN
    [[ "$profile_status" == 0 ]] || cleanup_failed=1
    if [[ "$cleanup_failed" == 0 ]]; then
        rm -rf -- "$signing_dir"
    else
        printf '%s\n' "Signing cleanup incomplete; retained job state for retry." >&2
    fi
    return "$cleanup_failed"
}

setup() {
    # Validate every required input before creating any filesystem entries.
    local variable
    for variable in RUNNER_TEMP GITHUB_ENV GITHUB_RUN_ID GITHUB_RUN_ATTEMPT IOS_DISTRIBUTION_P12_BASE64 IOS_DISTRIBUTION_P12_PASSWORD IOS_PROVISIONING_PROFILE_BASE64 IOS_WIDGET_PROVISIONING_PROFILE_BASE64 ASC_PRIVATE_KEY_BASE64; do
        [[ -n "${!variable:-}" ]] || fail "Missing required environment variable: $variable"
    done
    [[ "$GITHUB_ENV" == /* ]] || fail "GITHUB_ENV must be an absolute path."
    [[ -n "${HOME:-}" && "$HOME" == /* ]] || fail "HOME must be an absolute path."
    resolve_directory
    [[ ! -e "$signing_dir" ]] || fail "Signing directory already exists; run cleanup first."
    mkdir -m 700 -- "$signing_dir"
    trap 'setup_status=$?; trap - ERR; cleanup || true; exit "$setup_status"' ERR
    python3 - "$signing_dir" <<'PYDECODE'
import base64, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
for key, filename in [
    ("IOS_DISTRIBUTION_P12_BASE64", "distribution.p12"),
    ("IOS_PROVISIONING_PROFILE_BASE64", "profile.mobileprovision"),
    ("IOS_WIDGET_PROVISIONING_PROFILE_BASE64", "widget-profile.mobileprovision"),
    ("ASC_PRIVATE_KEY_BASE64", "AuthKey.p8"),
]:
    try:
        data = base64.b64decode("".join(os.environ[key].split()), validate=True)
        if not data:
            raise ValueError()
    except (ValueError, TypeError):
        raise SystemExit("Invalid base64 signing input: " + key)
    with (root / filename).open("xb") as file:
        file.write(data)
    (root / filename).chmod(0o600)
if not (root / "AuthKey.p8").read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----"):
    raise SystemExit("App Store Connect key must be a PEM private key.")
PYDECODE
    security cms -D -i "$signing_dir/profile.mobileprovision" > "$signing_dir/profile.plist"
    security cms -D -i "$signing_dir/widget-profile.mobileprovision" > "$signing_dir/widget-profile.plist"
    python3 - "$signing_dir" <<'PYVALIDATE'
import datetime, pathlib, plistlib, re, sys
root = pathlib.Path(sys.argv[1])
for prefix, bundle_id in [("profile", "dev.dimensi.malysh"), ("widget-profile", "dev.dimensi.malysh.widgets")]:
    try:
        profile = plistlib.loads((root / (prefix + ".plist")).read_bytes())
        entitlements = profile["Entitlements"]
        assert entitlements["application-identifier"] == "YBBAN7R28K." + bundle_id
        assert entitlements.get("get-task-allow", False) is False
        assert "ProvisionedDevices" not in profile
        assert "ProvisionsAllDevices" not in profile
        assert profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc)
        assert "group.dev.dimensi.malysh" in entitlements.get("com.apple.security.application-groups", [])
        if bundle_id == "dev.dimensi.malysh":
            assert "iCloud.dev.dimensi.malysh" in entitlements.get("com.apple.developer.icloud-container-identifiers", [])
        environment = entitlements.get("com.apple.developer.icloud-container-environment")
        assert environment is None or environment == "Production" or (isinstance(environment, list) and "Production" in environment)
        push = entitlements.get("aps-environment")
        assert push is None or push == "production"
        uuid, name = profile["UUID"], profile["Name"]
        assert re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", uuid)
        assert isinstance(name, str) and name and not any(c in name for c in "\r\n\0")
    except (KeyError, ValueError, TypeError, AssertionError, AttributeError):
        raise SystemExit("Provisioning profile is not a valid App Store profile for " + bundle_id + ".")
    (root / (prefix + "-uuid")).write_text(uuid)
    (root / (prefix + "-name")).write_text(name)
PYVALIDATE
    # Persist search paths as individual lines, parsed without eval or shell splitting.
    security list-keychains -d user > "$signing_dir/keychains-raw.txt"
    python3 - "$signing_dir" <<'PYKEYCHAINS'
import pathlib, shlex, sys
root = pathlib.Path(sys.argv[1])
paths = shlex.split((root / "keychains-raw.txt").read_text())
if any("\n" in p or "\r" in p for p in paths):
    raise SystemExit("Unsupported newline in keychain path.")
(root / "original-keychains.txt").write_text("".join(p + "\n" for p in paths))
PYKEYCHAINS
    local keychain_path="$signing_dir/signing.keychain-db"
    local keychain_password
    keychain_password="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    printf '::add-mask::%s\n' "$keychain_password"
    # Mark the exact owned path first, so a partially failed creation is cleanable.
    touch "$signing_dir/keychain-created"
    security create-keychain -p "$keychain_password" "$keychain_path" >/dev/null
    security unlock-keychain -p "$keychain_password" "$keychain_path" >/dev/null
    security set-keychain-settings -lut 21600 "$keychain_path" >/dev/null
    security import "$signing_dir/distribution.p12" -k "$keychain_path" -P "$IOS_DISTRIBUTION_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >/dev/null
    local keychains=("$keychain_path") item
    while IFS= read -r item; do
        [[ -n "$item" ]] && keychains[${#keychains[@]}]="$item"
    done < "$signing_dir/original-keychains.txt"
    security list-keychains -d user -s "${keychains[@]}" >/dev/null
    python3 - "$signing_dir" "$HOME" <<'PYINSTALL'
import json, pathlib, sys
root, home = map(pathlib.Path, sys.argv[1:])
for prefix, state_name in [("profile", "installed-profile.json"), ("widget-profile", "installed-widget-profile.json")]:
    uuid = (root / (prefix + "-uuid")).read_text()
    destination = home / "Library/Developer/Xcode/UserData/Provisioning Profiles" / (uuid + ".mobileprovision")
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = (root / (prefix + ".mobileprovision")).read_bytes()
    # Exclusive creation refuses to overwrite another job's or the user's profile.
    with destination.open("xb") as installed:
        stat = destination.stat()
        (root / state_name).write_text(json.dumps({"uuid": uuid, "path": str(destination), "device": stat.st_dev, "inode": stat.st_ino}))
        installed.write(data)
    destination.chmod(0o600)
PYINSTALL
    # No other variables are exported into the workflow environment.
    PROFILE_UUID="$(cat "$signing_dir/profile-uuid")" PROFILE_NAME="$(cat "$signing_dir/profile-name")" WIDGET_PROFILE_UUID="$(cat "$signing_dir/widget-profile-uuid")" CI_KEYCHAIN_PATH="$keychain_path" CI_KEYCHAIN_PASSWORD="$keychain_password" ASC_KEY_PATH="$signing_dir/AuthKey.p8" python3 <<'PYEXPORT'
import os
with open(os.environ["GITHUB_ENV"], "a") as output:
    for key in ["PROFILE_UUID", "PROFILE_NAME", "WIDGET_PROFILE_UUID", "CI_KEYCHAIN_PATH", "CI_KEYCHAIN_PASSWORD", "ASC_KEY_PATH"]:
        value = os.environ[key]
        if "\n" in value or "\r" in value:
            raise SystemExit("Unsupported newline in signing environment value.")
        output.write(key + "=" + value + "\n")
PYEXPORT
    trap - ERR
}

case "${1:-}" in
    setup) setup ;;
    cleanup) cleanup ;;
    *) fail "Usage: ci-signing.sh setup|cleanup" ;;
esac

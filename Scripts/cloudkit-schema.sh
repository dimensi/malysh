#!/bin/sh
set -eu
exec python3 "$(dirname "$0")/cloudkit_schema.py" "$@"

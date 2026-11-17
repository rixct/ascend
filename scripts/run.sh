#!/bin/sh
set -eu
ASCEND_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ASCEND_ROOT/scripts/build-app.sh"
exec "$ASCEND_ROOT/dist/ASCEND.app/Contents/MacOS/ASCEND" "$@"

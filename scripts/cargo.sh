#!/bin/sh
set -eu
ASCEND_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ASCEND_ROOT"
if command -v cargo >/dev/null 2>&1; then
    exec cargo "$@"
fi
ASCEND_TOOLCHAIN_DIR=${ASCEND_TOOLCHAIN_DIR:-"$ASCEND_ROOT/.toolchain"}
export CARGO_HOME="$ASCEND_TOOLCHAIN_DIR/cargo"
export RUSTUP_HOME="$ASCEND_TOOLCHAIN_DIR/rustup"
export PATH="$CARGO_HOME/bin:$PATH"
if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
    echo 'Rust не найден. Выполните ./scripts/setup.sh' >&2
    exit 1
fi
exec "$CARGO_HOME/bin/cargo" "$@"

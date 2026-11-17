#!/bin/sh
set -eu
ASCEND_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CARGO_HOME="$ASCEND_ROOT/.toolchain/cargo"
export RUSTUP_HOME="$ASCEND_ROOT/.toolchain/rustup"
mkdir -p "$ASCEND_ROOT/target/setup"
curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$ASCEND_ROOT/target/setup/rustup-init.sh"
sh "$ASCEND_ROOT/target/setup/rustup-init.sh" -y --profile minimal --component rustfmt --component clippy --no-modify-path
echo 'Rust готов. Запуск: ./scripts/run.sh'

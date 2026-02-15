#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Compiling pong.clj to WAT..."
clj -M:run examples/pong.clj > examples/pong.wat

echo "Assembling WAT to WASM..."
# wasm-tools supports WasmGC (install via: cargo install wasm-tools)
wasm-tools parse examples/pong.wat -o examples/pong.wasm

echo ""
echo "Build complete!"
echo ""
echo "To play:"
echo "  cd examples && python3 -m http.server 8000"
echo "  Then open: http://localhost:8000/pong.html"
echo ""
echo "Controls:"
echo "  Left player:  W (up) / S (down)"
echo "  Right player: Arrow Up / Arrow Down"

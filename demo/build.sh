#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Building woj REPL ==="

# 1. Check for compiler WAT
WAT="/tmp/woj-compiler.wat"
if [ ! -f "$WAT" ]; then
  echo "Compiler WAT not found at $WAT"
  echo "Build it with: clj -M:run --path lib --path src bootstrap/main.clj > $WAT"
  exit 1
fi

# 2. Patch WAT: replace (start $start) with _start export so we control init timing.
# The browser WASI shim needs memory access before $start runs.
echo "Patching compiler WAT..."
PATCHED="/tmp/woj-compiler-patched.wat"
sed 's/(start $start)/(export "_start" (func $start))/' "$WAT" > "$PATCHED"

# 3. Convert WAT to WASM
echo "Converting compiler WAT -> WASM..."
wasm-tools parse "$PATCHED" -o public/woj-compiler.wasm
echo "  $(wc -c < public/woj-compiler.wasm | tr -d ' ') bytes"

# 4. Bundle CodeMirror
echo "Bundling CodeMirror..."
npx esbuild cm-bundle.js --bundle --format=esm --outfile=public/cm-bundle.js --minify
echo "  $(wc -c < public/cm-bundle.js | tr -d ' ') bytes"

# 5. Bundle lib files
echo "Bundling lib files..."
node build-vfs.js

echo "=== Done ==="
echo "Run: npx wrangler pages dev public"

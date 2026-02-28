#!/bin/bash
# Fast clojure-test-suite runner for woj
#
# Splits test files into batches and compiles each batch in a separate JVM
# process (in parallel), then runs wasmtime on each in parallel.
#
# Usage:
#   ./test/run-compat-tests.sh              # run all tests
#   ./test/run-compat-tests.sh first rest   # run only specific tests (by basename without .cljc)
#   ./test/run-compat-tests.sh --list       # list all test files
#
# Environment variables:
#   COMPILE_JOBS=4      Number of parallel JVM compile processes (default: 4)
#   WASM_JOBS=8         Number of parallel wasmtime processes (default: 8)
#   WASM_TIMEOUT=5      Per-test wasmtime timeout in seconds (default: 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$PROJECT_DIR/test/clojure-test-suite/test/clojure/core_test"
SEARCH_PATH="$PROJECT_DIR/test/clojure-test-suite/test"
WASMTIME_FLAGS="-W gc=y -W function-references=y -W exceptions=y"
COMPILE_JOBS=${COMPILE_JOBS:-4}
WASM_JOBS=${WASM_JOBS:-8}
WASM_TIMEOUT=${WASM_TIMEOUT:-5}
TMP_DIR=$(mktemp -d)

# Cleanup on exit — kill any child JVMs too
cleanup() {
  jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Colors (if terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# Skip files that aren't tests (no deftest)
SKIP_FILES="portability number_range"

collect_test_files() {
  for f in "$TEST_DIR"/*.cljc; do
    local base=$(basename "$f" .cljc)
    local skip=false
    for s in $SKIP_FILES; do
      [ "$base" = "$s" ] && { skip=true; break; }
    done
    $skip || echo "$f"
  done
}

extract_deftest_name() {
  grep -oE '\(deftest [a-zA-Z0-9_?!<>=*/+-]+' "$1" 2>/dev/null | head -1 | sed 's/(deftest //' || true
}

# --- Main ---

if [ "${1:-}" = "--list" ]; then
  collect_test_files | while read -r f; do
    base=$(basename "$f" .cljc)
    deftest=$(extract_deftest_name "$f")
    printf "%-30s  deftest: %s\n" "$base" "${deftest:-<none>}"
  done
  exit 0
fi

FILTER_TESTS=("$@")
FILES=()
while IFS= read -r line; do FILES+=("$line"); done < <(collect_test_files)

if [ ${#FILTER_TESTS[@]} -gt 0 ]; then
  FILTERED=()
  for f in "${FILES[@]}"; do
    base=$(basename "$f" .cljc)
    for filter in "${FILTER_TESTS[@]}"; do
      [ "$base" = "$filter" ] && { FILTERED+=("$f"); break; }
    done
  done
  if [ ${#FILTERED[@]} -eq 0 ]; then
    echo "No matching test files found for: ${FILTER_TESTS[*]}"
    exit 1
  fi
  FILES=("${FILTERED[@]}")
fi

TOTAL=${#FILES[@]}
echo -e "${BOLD}woj clojure-test-suite runner${RESET}"
echo "Found $TOTAL test files"
echo ""

# ===== Phase 1: Parallel batch compilation =====
# Split files into COMPILE_JOBS batches, each compiled by a separate JVM
echo -e "${BOLD}Phase 1:${RESET} Compiling $TOTAL tests across $COMPILE_JOBS JVM processes..."
COMPILE_START=$SECONDS

# Write file lists for each batch
BATCH_DIR="$TMP_DIR/batches"
mkdir -p "$BATCH_DIR"
BATCH_IDX=0
for f in "${FILES[@]}"; do
  echo "$f" >> "$BATCH_DIR/batch_$((BATCH_IDX % COMPILE_JOBS)).txt"
  BATCH_IDX=$((BATCH_IDX + 1))
done

# Generate and run a compile script for each batch
PIDS=()
for batch_file in "$BATCH_DIR"/batch_*.txt; do
  BATCH_NUM=$(basename "$batch_file" .txt | sed 's/batch_//')
  COMPILE_SCRIPT="$TMP_DIR/compile_${BATCH_NUM}.clj"

  cat > "$COMPILE_SCRIPT" << CLOJURE_HEADER
(require '[woj.main :as woj])
(defn compile-one [input-file output-file search-paths]
  (try
    (let [wat (woj/compile-file input-file search-paths)]
      (spit output-file wat)
      (binding [*out* *err*] (println (str "OK " input-file))))
    (catch Exception e
      (binding [*out* *err*] (println (str "COMPILE_FAIL " input-file " " (.getMessage e)))))))
CLOJURE_HEADER

  while IFS= read -r f; do
    base=$(basename "$f" .cljc)
    echo "(compile-one \"$f\" \"$TMP_DIR/${base}.wat\" [\"$SEARCH_PATH\"])" >> "$COMPILE_SCRIPT"
  done < "$batch_file"

  echo "(System/exit 0)" >> "$COMPILE_SCRIPT"

  # Launch JVM in background
  cd "$PROJECT_DIR"
  clj -M -i "$COMPILE_SCRIPT" > /dev/null 2>"$TMP_DIR/compile_err_${BATCH_NUM}.txt" &
  PIDS+=($!)
done

# Wait for all compile jobs
COMPILE_FAILED=false
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || COMPILE_FAILED=true
done

COMPILE_ELAPSED=$((SECONDS - COMPILE_START))
COMPILED_OK=$(find "$TMP_DIR" -maxdepth 1 -name "*.wat" -size +0c 2>/dev/null | wc -l | tr -d ' ')
echo -e "Compiled ${CYAN}${COMPILED_OK}${RESET} of $TOTAL in ${CYAN}${COMPILE_ELAPSED}s${RESET}"
echo ""

# ===== Phase 2: Parallel wasmtime execution =====
echo -e "${BOLD}Phase 2:${RESET} Running wasmtime ($WASM_JOBS parallel, ${WASM_TIMEOUT}s timeout)..."

RESULTS_DIR="$TMP_DIR/results"
mkdir -p "$RESULTS_DIR"

# Worker script for a single wasmtime run
WORKER="$TMP_DIR/run_one.sh"
cat > "$WORKER" << WORKEREOF
#!/bin/bash
FILE="\$1"
base=\$(basename "\$FILE" .cljc)
wat_file="$TMP_DIR/\${base}.wat"
result_file="$RESULTS_DIR/\${base}.result"

deftest_name=\$(grep -oE '\(deftest [a-zA-Z0-9_?!<>=*/+-]+' "\$FILE" 2>/dev/null | head -1 | sed 's/(deftest //' || true)

if [ ! -f "\$wat_file" ] || [ ! -s "\$wat_file" ]; then
  echo "COMPILE_FAIL" > "\$result_file"; exit 0
fi
if [ -z "\$deftest_name" ]; then
  echo "SKIP no deftest" > "\$result_file"; exit 0
fi

# Check if the deftest function was actually exported (when-var-exists may skip it)
if ! grep -q "export \"\$deftest_name\"" "\$wat_file" 2>/dev/null; then
  echo "SKIP not exported (unimplemented var)" > "\$result_file"; exit 0
fi

# Run wasmtime with a kill-based timeout
wasmtime $WASMTIME_FLAGS --invoke "\$deftest_name" "\$wat_file" \
  > "$TMP_DIR/wasm_out_\${base}.txt" \
  2> "$TMP_DIR/wasm_err_\${base}.txt" &
WPID=\$!

# Watchdog
(sleep $WASM_TIMEOUT && kill \$WPID 2>/dev/null) &
TPID=\$!

wait \$WPID 2>/dev/null
EXIT_CODE=\$?
kill \$TPID 2>/dev/null; wait \$TPID 2>/dev/null || true

WASM_OUT=\$(cat "$TMP_DIR/wasm_out_\${base}.txt" 2>/dev/null)

if [ \$EXIT_CODE -eq 137 ] || [ \$EXIT_CODE -eq 143 ]; then
  echo "TIMEOUT" > "\$result_file"
elif [ \$EXIT_CODE -ne 0 ]; then
  echo "RUNTIME_FAIL \$(head -1 "$TMP_DIR/wasm_err_\${base}.txt" 2>/dev/null)" > "\$result_file"
elif [ "\$WASM_OUT" = "0" ]; then
  echo "PASS" > "\$result_file"
else
  echo "FAIL \$WASM_OUT" > "\$result_file"
fi
WORKEREOF
chmod +x "$WORKER"

RUN_START=$SECONDS
printf '%s\n' "${FILES[@]}" | xargs -P "$WASM_JOBS" -I{} bash "$WORKER" {}
RUN_ELAPSED=$((SECONDS - RUN_START))

# ===== Collect results =====
PASS=0; FAIL=0; COMPILE_FAIL=0; SKIP=0; RUNTIME_FAIL=0; TIMEOUT=0
FAILED_TESTS=(); COMPILE_FAILED_TESTS=(); RUNTIME_FAILED_TESTS=(); TIMEOUT_TESTS=()

for f in "${FILES[@]}"; do
  base=$(basename "$f" .cljc)
  result_file="$RESULTS_DIR/${base}.result"

  if [ ! -f "$result_file" ]; then
    echo -e "  ${YELLOW}MISSING${RESET}      $base"
    COMPILE_FAIL=$((COMPILE_FAIL + 1)); COMPILE_FAILED_TESTS+=("$base"); continue
  fi

  result=$(cat "$result_file")
  case "$result" in
    PASS)
      echo -e "  ${GREEN}PASS${RESET}         $base"; PASS=$((PASS + 1)) ;;
    FAIL*)
      ret=${result#FAIL }
      echo -e "  ${RED}FAIL${RESET}         $base (returned $ret)"
      FAIL=$((FAIL + 1)); FAILED_TESTS+=("$base") ;;
    TIMEOUT)
      echo -e "  ${YELLOW}TIMEOUT${RESET}      $base"
      TIMEOUT=$((TIMEOUT + 1)); TIMEOUT_TESTS+=("$base") ;;
    RUNTIME_FAIL*)
      err=${result#RUNTIME_FAIL }
      echo -e "  ${RED}RUNTIME_FAIL${RESET} $base ($err)"
      RUNTIME_FAIL=$((RUNTIME_FAIL + 1)); RUNTIME_FAILED_TESTS+=("$base") ;;
    COMPILE_FAIL)
      echo -e "  ${YELLOW}COMPILE_FAIL${RESET}  $base"
      COMPILE_FAIL=$((COMPILE_FAIL + 1)); COMPILE_FAILED_TESTS+=("$base") ;;
    SKIP*)
      reason=${result#SKIP }
      echo -e "  ${YELLOW}SKIP${RESET}         $base ($reason)"
      SKIP=$((SKIP + 1)) ;;
    *)
      echo -e "  ${YELLOW}UNKNOWN${RESET}      $base ($result)"
      SKIP=$((SKIP + 1)) ;;
  esac
done

# Summary
echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}Summary${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo -e "  ${GREEN}PASS${RESET}:          $PASS"
echo -e "  ${RED}FAIL${RESET}:          $FAIL"
echo -e "  ${RED}RUNTIME_FAIL${RESET}: $RUNTIME_FAIL"
echo -e "  ${YELLOW}TIMEOUT${RESET}:       $TIMEOUT"
echo -e "  ${YELLOW}COMPILE_FAIL${RESET}: $COMPILE_FAIL"
echo -e "  ${YELLOW}SKIP${RESET}:          $SKIP"
echo -e "  Total:        $TOTAL"
echo ""
echo -e "Compile: ${CYAN}${COMPILE_ELAPSED}s${RESET}  Run: ${CYAN}${RUN_ELAPSED}s${RESET}  Total: ${CYAN}$((COMPILE_ELAPSED + RUN_ELAPSED))s${RESET}"

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo -e "\n${RED}Failed tests:${RESET}"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
fi
if [ ${#RUNTIME_FAILED_TESTS[@]} -gt 0 ]; then
  echo -e "\n${RED}Runtime failures:${RESET}"
  for t in "${RUNTIME_FAILED_TESTS[@]}"; do echo "  - $t"; done
fi
if [ ${#TIMEOUT_TESTS[@]} -gt 0 ]; then
  echo -e "\n${YELLOW}Timed out tests:${RESET}"
  for t in "${TIMEOUT_TESTS[@]}"; do echo "  - $t"; done
fi
if [ ${#COMPILE_FAILED_TESTS[@]} -gt 0 ]; then
  echo -e "\n${YELLOW}Compile failures:${RESET}"
  for t in "${COMPILE_FAILED_TESTS[@]}"; do echo "  - $t"; done
fi

# Exit with failure if any tests failed
[ $FAIL -eq 0 ] && [ $RUNTIME_FAIL -eq 0 ]

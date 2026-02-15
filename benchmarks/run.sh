#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "========================================"
echo "  woj Benchmark Suite"
echo "  Clojure/JVM vs woj/WebAssembly"
echo "========================================"

# Check for hyperfine
if ! command -v hyperfine &> /dev/null; then
    echo "Error: hyperfine not found. Install with: brew install hyperfine"
    exit 1
fi

echo ""
echo "========================================"
echo "  Clojure/JVM (Criterium)"
echo "========================================"
clj -M:bench

echo ""
echo "========================================"
echo "  woj/WebAssembly (Hyperfine)"
echo "========================================"
echo "Note: woj benchmarks use internal loops to amortize startup overhead."
echo "Divide total time by iteration count for per-operation time."
echo ""

# Compile all woj benchmarks first
echo "Compiling woj benchmarks..."
for f in benchmarks/woj/*.clj; do
  name=$(basename "$f" .clj)
  clj -M:run "$f" > "/tmp/bench_${name}.wat"
  echo "  Compiled $name"
done

echo ""

# Run fib benchmark (100 iterations)
echo "=== Fibonacci (fib 30) x 100 iterations ==="
result=$(wasmtime -W gc=y -W function-references=y --invoke bench-fib /tmp/bench_fib.wat 2>&1 | grep -v warning)
echo "Result: $result"
hyperfine --warmup 3 --min-runs 10 \
  "wasmtime -W gc=y -W function-references=y --invoke bench-fib /tmp/bench_fib.wat"
echo "  -> Divide by 100 for per-call time"

echo ""

# Run sum_loop benchmark (10000 iterations)
echo "=== Sum Loop (sum 1..10000) x 10000 iterations ==="
result=$(wasmtime -W gc=y -W function-references=y --invoke bench-sum-loop /tmp/bench_sum_loop.wat 2>&1 | grep -v warning)
echo "Result: $result"
hyperfine --warmup 3 --min-runs 10 \
  "wasmtime -W gc=y -W function-references=y --invoke bench-sum-loop /tmp/bench_sum_loop.wat"
echo "  -> Divide by 10000 for per-call time"

echo ""

# Run vector_build benchmark (1000 iterations)
echo "=== Vector Build (1000 elements) x 1000 iterations ==="
result=$(wasmtime -W gc=y -W function-references=y --invoke bench-vector-build /tmp/bench_vector_build.wat 2>&1 | grep -v warning)
echo "Result: $result"
hyperfine --warmup 3 --min-runs 10 \
  "wasmtime -W gc=y -W function-references=y --invoke bench-vector-build /tmp/bench_vector_build.wat"
echo "  -> Divide by 1000 for per-call time"

echo ""

# Run vector_sum benchmark (1000 iterations)
echo "=== Vector Sum (1000 elements) x 1000 iterations ==="
result=$(wasmtime -W gc=y -W function-references=y --invoke bench-vector-sum /tmp/bench_vector_sum.wat 2>&1 | grep -v warning)
echo "Result: $result"
hyperfine --warmup 3 --min-runs 10 \
  "wasmtime -W gc=y -W function-references=y --invoke bench-vector-sum /tmp/bench_vector_sum.wat"
echo "  -> Divide by 1000 for per-call time"

echo ""
echo "========================================"
echo "  Benchmark Complete"
echo "========================================"

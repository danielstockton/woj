Compile and run a woj file through the full pipeline.

Arguments: $ARGUMENTS (e.g., "examples/hello.clj double 21")

Steps:
1. Parse the arguments to extract: input file, function name, and function arguments
2. Compile the .clj file to WAT using: `clj -M:run <input.clj>`
3. Save the WAT output to a temp file
4. Convert WAT to WASM using: `wat2wasm <file.wat> -o <file.wasm>`
5. Run with wasmtime: `wasmtime --invoke <function> <file.wasm> <args...>`
6. Show the result

If no function name is provided, just compile and show the WAT output.
If compilation fails, show the error message.

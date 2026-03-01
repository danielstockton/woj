;; woj I/O library - WASI-based file operations
;; Requires wasmtime --dir flag for filesystem access

(ns woj.io)

(defn slurp
  "Read the entire contents of a file as a string.
   Uses WASI path_open + fd_read with preopened directory fd 3.
   Returns nil if the file cannot be opened or read.
   Note: paths are relative to the preopened directory."
  [filename]
  (wasi-slurp filename))

(defn eprintln
  "Print a string to stderr followed by a newline."
  [s]
  (wasi-stderr (str s "\n")))

(defn eprint
  "Print a string to stderr."
  [s]
  (wasi-stderr (str s)))

(defn args
  "Get command-line arguments as a vector of strings."
  []
  (wasi-args))

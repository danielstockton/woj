import { createWasiShim } from './wasi-shim.js';
import { watToWasm as watToWasmEncode } from './wat-to-wasm.js';

// ============================================
// State
// ============================================

let compilerModule = null;
let compilerInstance = null;
let compilerShim = null;
let compilerVfs = null;
let accumulatedForms = [];
let editorView = null;
let ready = false;

const REPL_PRELUDE = `(def __repl-pr-str nil)

(defn __repl-pr-coll [open close s]
  (if (nil? s)
    (str open close)
    (loop [result (str open (__repl-pr-str (first s)))
           remaining (rest s)]
      (if (nil? (seq remaining))
        (str result close)
        (recur (str result " " (__repl-pr-str (first remaining)))
               (rest remaining))))))

(defn __repl-pr-map [m]
  (let [ks (keys m)]
    (if (nil? (seq ks))
      "{}"
      (loop [result (str "{" (__repl-pr-str (first ks)) " " (__repl-pr-str (get m (first ks))))
             remaining (rest ks)]
        (if (nil? (seq remaining))
          (str result "}")
          (recur (str result ", " (__repl-pr-str (first remaining)) " " (__repl-pr-str (get m (first remaining))))
                 (rest remaining)))))))

(set! __repl-pr-str (fn [x]
  (cond
    (nil? x) "nil"
    (integer? x) (str x)
    (string? x) (str "\\"" x "\\"")
    (keyword? x) (str ":" (name x))
    (float? x) (str x)
    (vector? x) (__repl-pr-coll "[" "]" (seq x))
    (map? x) (__repl-pr-map x)
    (set? x) (__repl-pr-coll "#{" "}" (seq x))
    (cons? x) (__repl-pr-coll "(" ")" x)
    (lazy-seq? x) (__repl-pr-coll "(" ")" (seq x))
    (fn? x) "#<fn>"
    (atom? x) (str "#<atom " (__repl-pr-str (deref x)) ">")
    :else (str x))))
`;

// ============================================
// Form classification
// ============================================

const DEF_OPS = new Set(['def', 'defn', 'defmacro', 'defprotocol', 'extend-type', 'extend-protocol']);

function isDefLike(source) {
  const trimmed = source.trim();
  if (!trimmed.startsWith('(')) return false;
  const rest = trimmed.slice(1).trimStart();
  for (const op of DEF_OPS) {
    if (rest.startsWith(op) && (rest.length === op.length || /[\s(]/.test(rest[op.length]))) {
      return true;
    }
  }
  return false;
}

function getDefName(source) {
  const m = source.match(/^\(\s*(?:def\w*)\s+(\S+)/);
  return m ? m[1] : null;
}

function splitForms(input) {
  const forms = [];
  let depth = 0;
  let inString = false;
  let escape = false;
  let inComment = false;
  let start = -1;

  for (let i = 0; i < input.length; i++) {
    const c = input[i];

    if (inComment) {
      if (c === '\n') inComment = false;
      continue;
    }
    if (escape) { escape = false; continue; }
    if (c === '\\' && inString) { escape = true; continue; }
    if (c === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (c === ';') { inComment = true; continue; }

    if (c === '(' || c === '[' || c === '{') {
      if (depth === 0) start = i;
      depth++;
    } else if (c === ')' || c === ']' || c === '}') {
      depth--;
      if (depth === 0 && start !== -1) {
        forms.push(input.slice(start, i + 1));
        start = -1;
      }
    }
  }
  return forms;
}

// ============================================
// Compilation pipeline
// ============================================

async function compileSource(source) {
  compilerVfs['input.clj'] = source;
  compilerShim.resetOutput();

  const t0 = performance.now();
  try {
    compilerInstance.exports['compile-repl-input']();
  } catch (e) {
    const stderr = compilerShim.getStderr();
    throw new Error(stderr || e.message);
  }
  const t1 = performance.now();

  const stderr = compilerShim.getStderr();
  if (stderr) console.log(stderr.trimEnd());
  console.log(`  compile-repl-input: ${(t1 - t0) | 0}ms`);

  let wat = compilerShim.getStdout();

  if (!wat.trim()) {
    throw new Error(stderr || 'Compiler produced no output');
  }
  return wat;
}

function watToWasm(wat) {
  const patched = wat.replace('(start $start)', '(export "_start" (func $start))');
  return watToWasmEncode(patched);
}

async function runUserWasm(wasmBytes) {
  const memRef = { current: null };
  const decoder = new TextDecoder();
  let stdoutBuf = '';

  const imports = {
    wasi_snapshot_preview1: {
      fd_write(fd, iovs, count, nwritten) {
        const mem = memRef.current;
        const view = new DataView(mem.buffer);
        const bytes = new Uint8Array(mem.buffer);
        let totalWritten = 0;
        for (let i = 0; i < count; i++) {
          const ptr = view.getUint32(iovs + i * 8, true);
          const len = view.getUint32(iovs + i * 8 + 4, true);
          const text = decoder.decode(bytes.slice(ptr, ptr + len));
          if (fd === 1) stdoutBuf += text;
          totalWritten += len;
        }
        view.setUint32(nwritten, totalWritten, true);
        return 0;
      },
      fd_read: () => 0,
      fd_close: () => 0,
      fd_seek: () => 0,
      path_open: () => 0,
      fd_filestat_get: () => 0,
      args_sizes_get: () => 0,
      args_get: () => 0,
      clock_time_get: () => 0,
    }
  };

  const tr0 = performance.now();
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const tr1 = performance.now();
  memRef.current = instance.exports.memory;
  instance.exports._start();
  const tr2 = performance.now();
  instance.exports.__repl_eval();
  const tr3 = performance.now();
  console.log(`  user wasm: ${(tr1 - tr0) | 0}ms compile+inst, ${(tr2 - tr1) | 0}ms _start, ${(tr3 - tr2) | 0}ms eval`);
  return stdoutBuf;
}

// ============================================
// REPL eval
// ============================================

async function replEval(input) {
  const forms = splitForms(input);
  if (forms.length === 0) return null;

  const defs = forms.filter(f => isDefLike(f));
  const exprs = forms.filter(f => !isDefLike(f));

  let evalBody;
  if (exprs.length > 0) {
    const sideEffects = exprs.slice(0, -1).join('\n');
    const lastExpr = exprs[exprs.length - 1];
    evalBody = sideEffects
      ? `(do ${sideEffects} (__repl-pr-str ${lastExpr}))`
      : `(__repl-pr-str ${lastExpr})`;
  } else {
    evalBody = '""';
  }

  const evalFn = `(defn __repl_eval [] (println ${evalBody}))`;

  const fullSource = [
    accumulatedForms.join('\n'),
    REPL_PRELUDE,
    defs.join('\n'),
    evalFn,
  ].join('\n');

  const t0 = performance.now();
  const wat = await compileSource(fullSource);
  const t1 = performance.now();
  const wasmBytes = watToWasm(wat);
  const t2 = performance.now();
  const output = await runUserWasm(wasmBytes);
  const t3 = performance.now();

  const timing = `${(t1 - t0) | 0}ms compile, ${(t2 - t1) | 0}ms encode, ${(t3 - t2) | 0}ms run`;

  if (defs.length > 0) {
    accumulatedForms.push(...defs);
  }

  let result;
  if (defs.length > 0 && exprs.length === 0) {
    result = "#'" + getDefName(defs[defs.length - 1]);
  } else {
    result = output.trimEnd();
  }

  return { result, timing };
}

// ============================================
// UI — CodeMirror 6 + vim, REPL-style
// ============================================

const statusEl = document.getElementById('status');
const outputEl = document.getElementById('output');
const history = [];
let historyIdx = -1;
let running = false;

function appendOutput(text, className) {
  const line = document.createElement('div');
  if (className) line.className = className;
  line.textContent = text;
  outputEl.appendChild(line);
  outputEl.scrollTop = outputEl.scrollHeight;
}

function setEditorContent(text) {
  editorView.dispatch({
    changes: { from: 0, to: editorView.state.doc.length, insert: text },
  });
}

async function handleSubmit() {
  if (!ready || running) return;
  const input = editorView.state.doc.toString().trim();
  if (!input) return;

  // If parens aren't balanced, don't submit — let the user keep typing
  if (!isBalanced(input)) return false;

  // Add to history
  history.push(input);
  historyIdx = history.length;

  // Echo input
  appendOutput('woj=> ' + input, 'input-echo');

  // Clear editor
  setEditorContent('');

  if (input === ':reset') {
    accumulatedForms = [];
    appendOutput('State cleared.', 'info');
    return true;
  }
  if (input === ':help') {
    appendOutput('Type Clojure expressions to evaluate.', 'info');
    appendOutput(':reset - clear accumulated definitions', 'info');
    appendOutput(':help  - show this message', 'info');
    return true;
  }

  running = true;
  statusEl.textContent = 'Evaluating...';

  try {
    const ret = await replEval(input);
    if (ret !== null) {
      if (ret.result !== '') {
        appendOutput(ret.result, 'result');
      }
      appendOutput(ret.timing, 'timing');
    }
  } catch (e) {
    appendOutput('Error: ' + e.message, 'error');
    console.error(e);
  } finally {
    running = false;
    statusEl.textContent = '';
  }
  return true;
}

function historyUp() {
  if (history.length === 0) return;
  if (historyIdx > 0) {
    historyIdx--;
    setEditorContent(history[historyIdx]);
  }
}

function historyDown() {
  if (history.length === 0) return;
  if (historyIdx < history.length - 1) {
    historyIdx++;
    setEditorContent(history[historyIdx]);
  } else {
    historyIdx = history.length;
    setEditorContent('');
  }
}

function isBalanced(s) {
  let depth = 0;
  let inString = false;
  let escape = false;
  for (const c of s) {
    if (escape) { escape = false; continue; }
    if (c === '\\' && inString) { escape = true; continue; }
    if (c === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (c === '(' || c === '[' || c === '{') depth++;
    if (c === ')' || c === ']' || c === '}') depth--;
  }
  return depth <= 0;
}

async function setupEditor() {
  const {
    EditorView, keymap, drawSelection,
    EditorState,
    defaultKeymap, indentWithTab,
    StreamLanguage,
    clojure,
    vim, Vim,
  } = await import('/cm-bundle.js');

  // Enter: eval if balanced, otherwise newline. Shift+Enter: always newline.
  const replKeymap = keymap.of([
    {
      key: 'Enter',
      run: (view) => {
        const doc = view.state.doc.toString().trim();
        if (doc && isBalanced(doc)) {
          handleSubmit();
          return true;
        }
        // Unbalanced — insert newline
        return false;
      },
    },
    {
      key: 'Mod-Enter',
      run: () => { handleSubmit(); return true; },
    },
    {
      key: 'ArrowUp',
      run: (view) => {
        // Only cycle history if on the first line
        if (view.state.doc.lines <= 1) {
          historyUp();
          return true;
        }
        return false;
      },
    },
    {
      key: 'ArrowDown',
      run: (view) => {
        // Only cycle history if on the last line
        if (view.state.doc.lines <= 1) {
          historyDown();
          return true;
        }
        return false;
      },
    },
  ]);

  const theme = EditorView.theme({
    '&': { backgroundColor: 'transparent' },
    '.cm-content': { fontFamily: 'var(--font-mono)' },
    '.cm-cursor': { borderLeftColor: 'var(--accent)' },
  });

  editorView = new EditorView({
    state: EditorState.create({
      doc: '',
      extensions: [
        // replKeymap BEFORE vim so Enter intercepts first in insert mode
        replKeymap,
        vim(),
        drawSelection(),
        StreamLanguage.define(clojure),
        keymap.of([indentWithTab, ...defaultKeymap]),
        theme,
        EditorView.lineWrapping,
      ],
    }),
    parent: document.getElementById('editor-wrap'),
  });

  // Vim normal mode: j/k cycle history when single-line
  if (Vim) {
    Vim.defineAction('historyUp', () => { historyUp(); });
    Vim.defineAction('historyDown', () => { historyDown(); });
  }
}

// ============================================
// Initialization
// ============================================

async function init() {
  await setupEditor();

  try {
    statusEl.textContent = 'Loading compiler...';
    const response = await fetch('/woj-compiler.wasm');
    const bytes = await response.arrayBuffer();
    const sizeMB = (bytes.byteLength / 1024 / 1024).toFixed(1);
    statusEl.textContent = `Initializing core (${sizeMB} MB)...`;

    compilerModule = await WebAssembly.compile(bytes);
    compilerVfs = { ...window.VFS_BUNDLE };
    compilerShim = createWasiShim(compilerVfs, ['woj', '--path', 'lib', '--repl']);

    const t0 = performance.now();
    compilerInstance = await WebAssembly.instantiate(compilerModule, compilerShim.imports);
    compilerShim.setMemory(compilerInstance.exports.memory);
    compilerInstance.exports._start();
    const t1 = performance.now();

    const stderr = compilerShim.getStderr();
    if (stderr) console.log(stderr.trimEnd());

    statusEl.textContent = `Ready (${((t1 - t0) / 1000).toFixed(1)}s init). Enter to eval, Shift+Enter for newline.`;
    ready = true;
    editorView.focus();
  } catch (e) {
    statusEl.textContent = 'Failed to initialize: ' + e.message;
    console.error(e);
  }
}

init();

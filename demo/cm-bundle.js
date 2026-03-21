// CodeMirror 6 bundle — esbuild combines all packages into one file
export { EditorView, keymap, drawSelection } from '@codemirror/view';
export { EditorState } from '@codemirror/state';
export { defaultKeymap, indentWithTab } from '@codemirror/commands';
export { StreamLanguage } from '@codemirror/language';
export { clojure } from '@codemirror/legacy-modes/mode/clojure';
export { vim, Vim } from '@replit/codemirror-vim';

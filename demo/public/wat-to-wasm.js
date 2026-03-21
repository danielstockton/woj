// wat-to-wasm.js — WAT text → WASM binary converter
// Ported from woj/binary.cljc + woj/wat.clj
// Supports the WasmGC subset used by woj compiler output.
//
// Performance-oriented: uses a single growable Uint8Array buffer (Buf)
// to avoid thousands of intermediate array allocations.

// ============================================
// Growable byte buffer
// ============================================

class Buf {
  constructor(initialSize = 65536) {
    this.arr = new Uint8Array(initialSize);
    this.len = 0;
  }
  ensure(n) {
    if (this.len + n > this.arr.length) {
      const newSize = Math.max(this.arr.length * 2, this.len + n);
      const newArr = new Uint8Array(newSize);
      newArr.set(this.arr);
      this.arr = newArr;
    }
  }
  push(b) {
    this.ensure(1);
    this.arr[this.len++] = b;
  }
  pushAll(bytes) {
    // bytes can be Uint8Array or regular array
    const n = bytes.length;
    this.ensure(n);
    if (bytes instanceof Uint8Array) {
      this.arr.set(bytes, this.len);
    } else {
      for (let i = 0; i < n; i++) this.arr[this.len + i] = bytes[i];
    }
    this.len += n;
  }
  uleb(value) {
    if (value === 0) { this.push(0); return; }
    let v = value;
    while (v !== 0) {
      let b = v & 0x7F;
      v >>>= 7;
      if (v !== 0) b |= 0x80;
      this.push(b);
    }
  }
  sleb(value) {
    let v = value;
    while (true) {
      const b = v & 0x7F;
      v >>= 7;
      const done = (v === 0 && (b & 0x40) === 0) || (v === -1 && (b & 0x40) !== 0);
      this.push(done ? b : (b | 0x80));
      if (done) break;
    }
  }
  f64(value) {
    this.ensure(8);
    _f64View[0] = value;
    for (let i = 0; i < 8; i++) this.arr[this.len + i] = _f64Bytes[i];
    this.len += 8;
  }
  f32(value) {
    this.ensure(4);
    _f32View[0] = value;
    for (let i = 0; i < 4; i++) this.arr[this.len + i] = _f32Bytes[i];
    this.len += 4;
  }
  name(s) {
    const utf8 = _encoder.encode(s);
    this.uleb(utf8.length);
    this.pushAll(utf8);
  }
  // Get a sub-buffer's contents as Uint8Array
  toBytes() {
    return this.arr.subarray(0, this.len);
  }
}

// Shared float conversion buffers
const _f64Buf = new ArrayBuffer(8);
const _f64View = new Float64Array(_f64Buf);
const _f64Bytes = new Uint8Array(_f64Buf);
const _f32Buf = new ArrayBuffer(4);
const _f32View = new Float32Array(_f32Buf);
const _f32Bytes = new Uint8Array(_f32Buf);
const _encoder = new TextEncoder();

// ============================================
// WASM type constants
// ============================================

const VT_I32 = 0x7F, VT_I64 = 0x7E, VT_F32 = 0x7D, VT_F64 = 0x7C;
const PT_I8 = 0x78, PT_I16 = 0x77;
const RT_REF = 0x64, RT_REF_NULL = 0x63;
const HT_FUNC = 0x70, HT_EXTERN = 0x6F, HT_ANY = 0x6E, HT_EQ = 0x6D;
const HT_I31 = 0x6C, HT_STRUCT = 0x6B, HT_ARRAY = 0x6A, HT_EXN = 0x69;
const HT_NONE = 0x71, HT_NOEXTERN = 0x72, HT_NOFUNC = 0x73;
const CT_FUNC = 0x60, CT_STRUCT = 0x5F, CT_ARRAY = 0x5E;
const ST_SUB = 0x50, ST_SUB_FINAL = 0x4F;

const HEAP_TYPE_MAP = {
  func: HT_FUNC, extern: HT_EXTERN, any: HT_ANY, eq: HT_EQ,
  i31: HT_I31, struct: HT_STRUCT, array: HT_ARRAY, exn: HT_EXN,
  none: HT_NONE, nofunc: HT_NOFUNC, noextern: HT_NOEXTERN
};

/** Write heap type to buf */
function writeHeapType(buf, ht) {
  if (typeof ht === 'number') { buf.sleb(ht); return; }
  const v = HEAP_TYPE_MAP[ht];
  if (v !== undefined) { buf.push(v); return; }
  throw new Error(`Unknown heap type: ${ht}`);
}

/** Write val type to buf */
function writeValType(buf, vt) {
  if (typeof vt === 'string') {
    switch (vt) {
      case 'i32': buf.push(VT_I32); return;
      case 'i64': buf.push(VT_I64); return;
      case 'f32': buf.push(VT_F32); return;
      case 'f64': buf.push(VT_F64); return;
      case 'funcref': buf.push(HT_FUNC); return;
      case 'externref': buf.push(HT_EXTERN); return;
      case 'anyref': buf.push(RT_REF_NULL); buf.push(HT_ANY); return;
      case 'i31ref': buf.push(RT_REF); buf.push(HT_I31); return;
      case 'structref': buf.push(RT_REF_NULL); buf.push(HT_STRUCT); return;
      case 'arrayref': buf.push(RT_REF_NULL); buf.push(HT_ARRAY); return;
      case 'i8': buf.push(PT_I8); return;
      case 'i16': buf.push(PT_I16); return;
      default: throw new Error(`Unknown val type: ${vt}`);
    }
  }
  if (vt && typeof vt === 'object') {
    if (vt.ref !== undefined) { buf.push(RT_REF); writeHeapType(buf, vt.ref); return; }
    if (vt.refNull !== undefined) { buf.push(RT_REF_NULL); writeHeapType(buf, vt.refNull); return; }
  }
  throw new Error(`Cannot encode val type: ${JSON.stringify(vt)}`);
}

function writeFieldType(buf, valType, mutable) {
  writeValType(buf, valType);
  buf.push(mutable ? 0x01 : 0x00);
}

function writeFuncType(buf, params, results) {
  buf.push(CT_FUNC);
  buf.uleb(params.length);
  for (const p of params) writeValType(buf, p);
  buf.uleb(results.length);
  for (const r of results) writeValType(buf, r);
}

// ============================================
// Opcode table
// ============================================

// Immediate formats
const I = {
  N:0, U:1, S:2, S64:3, F64:4, F32:5, BLK:6, MEM:7, BRT:8,
  CI:9, GT:10, GTF:11, GTD:12, GTN:13, GTT:14, GC:15, GBC:16,
  RN:17, RF:18, MEMX:19, TAG:20
};

const OPCODES = new Map();
const opDefs = [
  ['unreachable',0x00,I.N],['nop',0x01,I.N],
  ['block',0x02,I.BLK],['loop',0x03,I.BLK],['if',0x04,I.BLK],
  ['else',0x05,I.N],['end',0x0B,I.N],
  ['br',0x0C,I.U],['br_if',0x0D,I.U],['br_table',0x0E,I.BRT],
  ['return',0x0F,I.N],['call',0x10,I.U],
  ['call_indirect',0x11,I.CI],['return_call',0x12,I.U],
  ['call_ref',0x14,I.U],['return_call_ref',0x15,I.U],
  ['try',0x06,I.BLK],['catch',0x07,I.TAG],['catch_all',0x19,I.N],['throw',0x08,I.TAG],
  ['drop',0x1A,I.N],['select',0x1B,I.N],
  ['local.get',0x20,I.U],['local.set',0x21,I.U],['local.tee',0x22,I.U],
  ['global.get',0x23,I.U],['global.set',0x24,I.U],
  ['i32.load',0x28,I.MEM],['i64.load',0x29,I.MEM],
  ['i32.load8_s',0x2C,I.MEM],['i32.load8_u',0x2D,I.MEM],
  ['i32.load16_s',0x2E,I.MEM],['i32.load16_u',0x2F,I.MEM],
  ['i32.store',0x36,I.MEM],['i32.store8',0x3A,I.MEM],
  ['i32.store16',0x3B,I.MEM],['i64.store',0x37,I.MEM],
  ['f64.load',0x2B,I.MEM],['f64.store',0x39,I.MEM],
  ['memory.size',0x3F,I.MEMX],['memory.grow',0x40,I.MEMX],
  ['i32.const',0x41,I.S],['i64.const',0x42,I.S64],
  ['f32.const',0x43,I.F32],['f64.const',0x44,I.F64],
  ['i32.eqz',0x45,I.N],['i32.eq',0x46,I.N],['i32.ne',0x47,I.N],
  ['i32.lt_s',0x48,I.N],['i32.lt_u',0x49,I.N],
  ['i32.gt_s',0x4A,I.N],['i32.gt_u',0x4B,I.N],
  ['i32.le_s',0x4C,I.N],['i32.le_u',0x4D,I.N],
  ['i32.ge_s',0x4E,I.N],['i32.ge_u',0x4F,I.N],
  ['i64.eqz',0x50,I.N],['i64.eq',0x51,I.N],['i64.ne',0x52,I.N],
  ['i64.lt_s',0x53,I.N],['i64.gt_s',0x55,I.N],
  ['i64.le_s',0x57,I.N],['i64.ge_s',0x59,I.N],
  ['f64.eq',0x61,I.N],['f64.ne',0x62,I.N],
  ['f64.lt',0x63,I.N],['f64.gt',0x64,I.N],
  ['f64.le',0x65,I.N],['f64.ge',0x66,I.N],
  ['i32.add',0x6A,I.N],['i32.sub',0x6B,I.N],['i32.mul',0x6C,I.N],
  ['i32.div_s',0x6D,I.N],['i32.div_u',0x6E,I.N],
  ['i32.rem_s',0x6F,I.N],['i32.rem_u',0x70,I.N],
  ['i32.and',0x71,I.N],['i32.or',0x72,I.N],['i32.xor',0x73,I.N],
  ['i32.shl',0x74,I.N],['i32.shr_s',0x75,I.N],['i32.shr_u',0x76,I.N],
  ['i32.rotl',0x77,I.N],['i32.rotr',0x78,I.N],
  ['i32.clz',0x67,I.N],['i32.ctz',0x68,I.N],['i32.popcnt',0x69,I.N],
  ['i64.add',0x7C,I.N],['i64.sub',0x7D,I.N],['i64.mul',0x7E,I.N],
  ['i64.div_s',0x7F,I.N],['i64.div_u',0x80,I.N],
  ['i64.rem_s',0x81,I.N],['i64.rem_u',0x82,I.N],
  ['i64.and',0x83,I.N],['i64.or',0x84,I.N],['i64.xor',0x85,I.N],
  ['i64.shl',0x86,I.N],['i64.shr_s',0x87,I.N],['i64.shr_u',0x88,I.N],
  ['f64.abs',0x99,I.N],['f64.neg',0x9A,I.N],
  ['f64.ceil',0x9B,I.N],['f64.floor',0x9C,I.N],
  ['f64.trunc',0x9D,I.N],['f64.nearest',0x9E,I.N],['f64.sqrt',0x9F,I.N],
  ['f64.add',0xA0,I.N],['f64.sub',0xA1,I.N],
  ['f64.mul',0xA2,I.N],['f64.div',0xA3,I.N],
  ['i32.wrap_i64',0xA7,I.N],
  ['i32.trunc_f64_s',0xAA,I.N],['i32.trunc_f64_u',0xAB,I.N],
  ['i64.extend_i32_s',0xAC,I.N],['i64.extend_i32_u',0xAD,I.N],
  ['f64.convert_i32_s',0xB7,I.N],['f64.convert_i32_u',0xB8,I.N],
  ['f64.convert_i64_s',0xB9,I.N],['f64.promote_f32',0xBB,I.N],
  ['i64.reinterpret_f64',0xBD,I.N],['f64.reinterpret_i64',0xBF,I.N],
  ['ref.null',0xD0,I.RN],['ref.is_null',0xD1,I.N],
  ['ref.func',0xD2,I.RF],['ref.eq',0xD3,I.N],['ref.as_non_null',0xD4,I.N],
];
// Multi-byte opcodes (0xFC/0xFB prefix)
const gcOpDefs = [
  ['i32.trunc_sat_f64_s',[0xFC,0x02],I.N],['i32.trunc_sat_f64_u',[0xFC,0x03],I.N],
  ['struct.new',[0xFB,0x00],I.GT],['struct.new_default',[0xFB,0x01],I.GT],
  ['struct.get',[0xFB,0x02],I.GTF],['struct.get_s',[0xFB,0x03],I.GTF],
  ['struct.get_u',[0xFB,0x04],I.GTF],['struct.set',[0xFB,0x05],I.GTF],
  ['array.new',[0xFB,0x06],I.GT],['array.new_default',[0xFB,0x07],I.GT],
  ['array.new_fixed',[0xFB,0x08],I.GTN],['array.new_data',[0xFB,0x09],I.GTD],
  ['array.new_elem',[0xFB,0x0A],I.GTD],
  ['array.get',[0xFB,0x0B],I.GT],['array.get_s',[0xFB,0x0C],I.GT],
  ['array.get_u',[0xFB,0x0D],I.GT],['array.set',[0xFB,0x0E],I.GT],
  ['array.len',[0xFB,0x0F],I.N],['array.fill',[0xFB,0x10],I.GT],
  ['array.copy',[0xFB,0x11],I.GTT],
  ['ref.test',[0xFB,0x14],I.GC],['ref.cast',[0xFB,0x16],I.GC],
  ['br_on_cast',[0xFB,0x18],I.GBC],['br_on_cast_fail',[0xFB,0x19],I.GBC],
  ['ref.i31',[0xFB,0x1C],I.N],['i31.get_s',[0xFB,0x1D],I.N],['i31.get_u',[0xFB,0x1E],I.N],
];
for (const [name, byte, imm] of opDefs) OPCODES.set(name, { bytes: [byte], imm });
for (const [name, bytes, imm] of gcOpDefs) OPCODES.set(name, { bytes, imm });

// Memory instruction set for fast lookup
const MEM_OPS = new Set([
  'i32.load','i64.load','f64.load','i32.load8_s','i32.load8_u',
  'i32.load16_s','i32.load16_u','i32.store','i32.store8',
  'i32.store16','i64.store','f64.store'
]);

// Array instructions with type index + rest operands
const ARRAY_TYPE_OPS = new Set([
  'array.new','array.new_default','array.get','array.get_s','array.get_u',
  'array.set','array.fill'
]);

// ============================================
// Tokenizer — returns flat arrays of type-tagged tokens
// ============================================
// Token types: 0=lparen, 1=rparen, 2=string, 3=atom
const T_LP = 0, T_RP = 1, T_STR = 2, T_ATOM = 3;

function tokenize(s) {
  const len = s.length;
  // Use parallel arrays instead of objects for speed
  const types = [];  // token type
  const values = []; // token value (string or null)
  let i = 0;
  while (i < len) {
    const c = s.charCodeAt(i);
    // Whitespace: space=32, tab=9, newline=10, cr=13
    if (c === 32 || c === 9 || c === 10 || c === 13) { i++; continue; }
    // Line comment: ;;
    if (c === 0x3B && i + 1 < len && s.charCodeAt(i + 1) === 0x3B) {
      i += 2;
      while (i < len && s.charCodeAt(i) !== 10) i++;
      i++; continue;
    }
    // Block comment: (;
    if (c === 0x28 && i + 1 < len && s.charCodeAt(i + 1) === 0x3B) {
      i += 2; let depth = 1;
      while (i < len - 1 && depth > 0) {
        const cc = s.charCodeAt(i);
        if (cc === 0x28 && s.charCodeAt(i + 1) === 0x3B) { depth++; i += 2; }
        else if (cc === 0x3B && s.charCodeAt(i + 1) === 0x29) { depth--; i += 2; }
        else i++;
      }
      continue;
    }
    // (
    if (c === 0x28) { types.push(T_LP); values.push(null); i++; continue; }
    // )
    if (c === 0x29) { types.push(T_RP); values.push(null); i++; continue; }
    // String
    if (c === 0x22) {
      let j = i + 1;
      let str = '';
      while (j < len) {
        const ch = s.charCodeAt(j);
        if (ch === 0x22) { j++; break; } // closing quote
        if (ch === 0x5C) { // backslash
          const next = s.charCodeAt(j + 1);
          if (next === 0x6E) { str += '\n'; j += 2; }       // \n
          else if (next === 0x74) { str += '\t'; j += 2; }   // \t
          else if (next === 0x72) { str += '\r'; j += 2; }   // \r
          else if (next === 0x5C) { str += '\\'; j += 2; }   // \\
          else if (next === 0x22) { str += '"'; j += 2; }    // \"
          else if (next === 0x27) { str += "'"; j += 2; }    // \'
          else {
            // Hex escape \xx
            const h1 = hexVal(next), h2 = j + 2 < len ? hexVal(s.charCodeAt(j + 2)) : -1;
            if (h1 >= 0 && h2 >= 0) {
              str += String.fromCharCode((h1 << 4) | h2);
              j += 3;
            } else {
              str += '\\'; str += s[j + 1]; j += 2;
            }
          }
        } else {
          str += s[j]; j++;
        }
      }
      types.push(T_STR); values.push(str);
      i = j; continue;
    }
    // Atom
    {
      let j = i;
      while (j < len) {
        const ch = s.charCodeAt(j);
        if (ch === 32 || ch === 9 || ch === 10 || ch === 13 ||
            ch === 0x28 || ch === 0x29 || ch === 0x3B) break;
        j++;
      }
      types.push(T_ATOM); values.push(s.substring(i, j));
      i = j;
    }
  }
  return { types, values, length: types.length };
}

function hexVal(charCode) {
  if (charCode >= 0x30 && charCode <= 0x39) return charCode - 0x30;
  if (charCode >= 0x61 && charCode <= 0x66) return charCode - 0x61 + 10;
  if (charCode >= 0x41 && charCode <= 0x46) return charCode - 0x41 + 10;
  return -1;
}

// ============================================
// S-expression parser
// ============================================

function parseSexpr(tokens, pos) {
  if (pos >= tokens.length) throw new Error('Unexpected end of input');
  const t = tokens.types[pos];
  if (t === T_LP) {
    const items = [];
    pos++;
    while (pos < tokens.length && tokens.types[pos] !== T_RP) {
      const r = parseSexpr(tokens, pos);
      items.push(r.result);
      pos = r.pos;
    }
    if (pos >= tokens.length) throw new Error('Unclosed paren');
    return { result: items, pos: pos + 1 };
  }
  if (t === T_RP) throw new Error('Unexpected )');
  if (t === T_STR) return { result: { string: tokens.values[pos] }, pos: pos + 1 };
  return { result: tokens.values[pos], pos: pos + 1 };
}

function parseWat(source) {
  const tokens = tokenize(source);
  return parseSexpr(tokens, 0).result;
}

// ============================================
// Helpers
// ============================================

function isNameRef(s) { return typeof s === 'string' && s.charCodeAt(0) === 0x24; }
function stringVal(x) { return (x && typeof x === 'object' && 'string' in x) ? x.string : null; }
const isVec = Array.isArray;

function parseIntLiteral(s) {
  if (s.indexOf('_') >= 0) s = s.replace(/_/g, '');
  if (s.charCodeAt(0) === 0x30 && s.charCodeAt(1) === 0x78) return parseInt(s.substring(2), 16);
  if (s.charCodeAt(0) === 0x2D && s.charCodeAt(1) === 0x30 && s.charCodeAt(2) === 0x78)
    return -parseInt(s.substring(3), 16);
  return s | 0 || parseInt(s, 10);
}

function parseFloatLiteral(s) {
  if (s.indexOf('_') >= 0) s = s.replace(/_/g, '');
  if (s === 'nan') return NaN;
  if (s === 'inf') return Infinity;
  if (s === '-inf') return -Infinity;
  if (s.charCodeAt(1) === 0x78 || (s.charCodeAt(0) === 0x2D && s.charCodeAt(2) === 0x78)) {
    const neg = s.charCodeAt(0) === 0x2D;
    const hex = neg ? s.substring(1) : s;
    const m = hex.match(/^0x([0-9a-fA-F]+)(?:\.([0-9a-fA-F]*))?(?:p([+-]?\d+))?$/i);
    if (!m) return parseFloat(s);
    const intPart = parseInt(m[1], 16);
    let fracPart = 0;
    if (m[2]) fracPart = parseInt(m[2], 16) / Math.pow(16, m[2].length);
    const exp = m[3] ? parseInt(m[3]) : 0;
    const val = (intPart + fracPart) * Math.pow(2, exp);
    return neg ? -val : val;
  }
  return parseFloat(s);
}

function resolveIdx(s, indexMap) {
  if (typeof s === 'number') return s;
  if (isNameRef(s)) {
    const idx = indexMap[s];
    if (idx === undefined) throw new Error(`Unresolved reference: ${s}`);
    return idx;
  }
  if (typeof s === 'string') return parseIntLiteral(s);
  throw new Error(`Cannot resolve index: ${s}`);
}

// ============================================
// Module analysis
// ============================================

function parseParamResult(forms) {
  const params = [], results = [];
  for (const form of forms) {
    if (!isVec(form)) continue;
    const h = form[0];
    if (h === 'param') {
      if (form.length > 2 && isNameRef(form[1])) params.push({ name: form[1], type: form[2] });
      else for (let i = 1; i < form.length; i++) params.push({ type: form[i] });
    } else if (h === 'result') {
      for (let i = 1; i < form.length; i++) results.push(form[i]);
    }
  }
  return { params, results };
}

function parseFuncDecl(form) {
  let items = form.slice(1);
  let name = null;
  if (isNameRef(items[0])) { name = items[0]; items = items.slice(1); }
  const exports = [], remaining = [];
  for (const item of items) {
    if (isVec(item) && item[0] === 'export') exports.push(stringVal(item[1]));
    else remaining.push(item);
  }
  items = remaining;
  let typeUse = null;
  if (items[0] && isVec(items[0]) && items[0][0] === 'type') { typeUse = items[0][1]; items = items.slice(1); }
  const params = [], results = [], locals = [], body = [];
  for (const item of items) {
    if (isVec(item)) {
      const h = item[0];
      if (h === 'param') {
        if (item.length > 2 && isNameRef(item[1])) params.push({ name: item[1], type: item[2] });
        else for (let i = 1; i < item.length; i++) params.push({ type: item[i] });
      } else if (h === 'result') {
        for (let i = 1; i < item.length; i++) results.push(item[i]);
      } else if (h === 'local') {
        if (item.length > 2 && isNameRef(item[1])) locals.push({ name: item[1], type: item[2] });
        else for (let i = 1; i < item.length; i++) locals.push({ type: item[i] });
      } else body.push(item);
    } else body.push(item);
  }
  return { name, exports, typeUse, params, results, locals, body };
}

function parseGlobalDecl(form) {
  let items = form.slice(1);
  let name = null;
  if (isNameRef(items[0])) { name = items[0]; items = items.slice(1); }
  const exports = [], remaining = [];
  for (const item of items) {
    if (isVec(item) && item[0] === 'export') exports.push(stringVal(item[1]));
    else remaining.push(item);
  }
  items = remaining;
  const typeForm = items[0];
  let mutable = false, valType;
  if (isVec(typeForm) && typeForm[0] === 'mut') { mutable = true; valType = typeForm[1]; }
  else valType = typeForm;
  return { name, exports, mutable, type: valType, init: items.slice(1) };
}

function parseImportDecl(form) {
  return { module: stringVal(form[1]), field: stringVal(form[2]), kind: form[3][0], desc: form[3].slice(1) };
}

function parseMemoryDecl(form) {
  let items = form.slice(1);
  const exports = [], remaining = [];
  for (const item of items) {
    if (isVec(item) && item[0] === 'export') exports.push(stringVal(item[1]));
    else remaining.push(item);
  }
  return { exports, min: remaining[0] ? parseInt(remaining[0]) : null,
           max: remaining[1] ? parseInt(remaining[1]) : null };
}

function parseDataDecl(form) {
  let items = form.slice(1);
  let name = null;
  if (isNameRef(items[0])) { name = items[0]; items = items.slice(1); }
  const data = items.map(x => (x && typeof x === 'object' && 'string' in x) ? x.string : String(x)).join('');
  return { name, data };
}

function parseElemDecl(form) {
  const items = form.slice(1);
  if (items[0] === 'declare') return { kind: 'declare', type: items[1], funcs: items.slice(2) };
  return { kind: 'other', raw: form };
}

function parseTagDecl(form) {
  let items = form.slice(1);
  let name = null;
  if (isNameRef(items[0])) { name = items[0]; items = items.slice(1); }
  const paramTypes = [];
  for (const item of items) {
    if (isVec(item) && item[0] === 'param')
      for (let i = 1; i < item.length; i++) paramTypes.push(item[i]);
  }
  return { name, paramTypes };
}

function analyzeModule(moduleSexpr) {
  if (!isVec(moduleSexpr) || moduleSexpr[0] !== 'module')
    throw new Error('Expected (module ...)');

  const imports = [], types = [], funcs = [], globals = [], memories = [];
  const datas = [], elems = [], exports = [], tags = [];
  let startFn = null;

  for (let fi = 1; fi < moduleSexpr.length; fi++) {
    const form = moduleSexpr[fi];
    if (!isVec(form)) continue;
    switch (form[0]) {
      case 'import': imports.push(parseImportDecl(form)); break;
      case 'type': {
        const name = isNameRef(form[1]) ? form[1] : null;
        types.push({ name, body: name ? form[2] : form[1] }); break;
      }
      case 'func': funcs.push(parseFuncDecl(form)); break;
      case 'global': globals.push(parseGlobalDecl(form)); break;
      case 'memory': memories.push(parseMemoryDecl(form)); break;
      case 'data': datas.push(parseDataDecl(form)); break;
      case 'elem': elems.push(parseElemDecl(form)); break;
      case 'export': exports.push(form); break;
      case 'tag': tags.push(parseTagDecl(form)); break;
      case 'start': startFn = form[1]; break;
    }
  }

  const typeIndex = {};
  for (let i = 0; i < types.length; i++) if (types[i].name) typeIndex[types[i].name] = i;

  const funcImports = imports.filter(imp => imp.kind === 'func');
  const funcIndex = {};
  for (let i = 0; i < funcImports.length; i++) {
    const name = isNameRef(funcImports[i].desc[0]) ? funcImports[i].desc[0] : null;
    if (name) funcIndex[name] = i;
  }
  const nFuncImports = funcImports.length;
  for (let i = 0; i < funcs.length; i++) if (funcs[i].name) funcIndex[funcs[i].name] = nFuncImports + i;

  const globalIndex = {};
  for (let i = 0; i < globals.length; i++) if (globals[i].name) globalIndex[globals[i].name] = i;

  const dataIndex = {};
  for (let i = 0; i < datas.length; i++) if (datas[i].name) dataIndex[datas[i].name] = i;

  const tagIndex = {};
  for (let i = 0; i < tags.length; i++) if (tags[i].name) tagIndex[tags[i].name] = i;

  const fieldIndices = {};
  for (const t of types) {
    if (!t.name || !isVec(t.body)) continue;
    let structForm = null;
    if (t.body[0] === 'sub') {
      const inner = t.body[t.body.length - 1];
      if (isVec(inner) && inner[0] === 'struct') structForm = inner;
    } else if (t.body[0] === 'struct') structForm = t.body;
    if (!structForm) continue;
    const fm = {};
    for (let i = 1; i < structForm.length; i++) {
      const field = structForm[i];
      if (isVec(field) && field[0] === 'field' && isNameRef(field[1])) fm[field[1]] = i - 1;
    }
    if (Object.keys(fm).length > 0) fieldIndices[t.name] = fm;
  }

  return { imports, types, funcs, globals, memories, datas, elems, exports, tags, start: startFn,
           typeIndex, funcIndex, globalIndex, dataIndex, tagIndex, fieldIndices, nFuncImports };
}

// ============================================
// Value type resolution
// ============================================

function resolveHeapTypeStr(ht) {
  const m = { func:'func', extern:'extern', any:'any', eq:'eq', i31:'i31',
              struct:'struct', array:'array', none:'none', nofunc:'nofunc',
              noextern:'noextern', exn:'exn' };
  if (m[ht]) return m[ht];
  throw new Error(`Unknown heap type: ${ht}`);
}

function resolveValType(typeStr, typeIndex) {
  if (typeof typeStr === 'string') {
    switch (typeStr) {
      case 'i32': case 'i64': case 'f32': case 'f64':
      case 'anyref': case 'funcref': case 'externref': case 'i31ref':
      case 'structref': case 'arrayref': case 'i8': case 'i16':
        return typeStr;
      default:
        if (isNameRef(typeStr)) {
          const idx = typeIndex[typeStr];
          if (idx === undefined) throw new Error(`Unknown type: ${typeStr}`);
          return { refNull: idx };
        }
        throw new Error(`Unknown value type: ${typeStr}`);
    }
  }
  if (isVec(typeStr)) {
    if (typeStr[0] === 'ref') {
      if (typeStr[1] === 'null') {
        const ht = typeStr[2];
        return { refNull: isNameRef(ht) ? typeIndex[ht] : resolveHeapTypeStr(ht) };
      }
      const ht = typeStr[1];
      return { ref: isNameRef(ht) ? typeIndex[ht] : resolveHeapTypeStr(ht) };
    }
    if (typeStr[0] === 'mut') return resolveValType(typeStr[1], typeIndex);
    throw new Error(`Unknown compound type: ${JSON.stringify(typeStr)}`);
  }
  throw new Error(`Cannot resolve type: ${JSON.stringify(typeStr)}`);
}

// ============================================
// Type definition encoding (write to buf)
// ============================================

function writeFieldFromWat(buf, fieldForm, typeIndex) {
  let items = fieldForm.slice(1);
  if (isNameRef(items[0])) items = items.slice(1);
  const typeForm = items[0];
  let mutable = false, vtRaw;
  if (isVec(typeForm) && typeForm[0] === 'mut') { mutable = true; vtRaw = typeForm[1]; }
  else vtRaw = typeForm;
  writeFieldType(buf, resolveValType(vtRaw, typeIndex), mutable);
}

function writeTypeBody(buf, body, typeIndex) {
  if (isVec(body) && body[0] === 'struct') {
    buf.push(CT_STRUCT);
    buf.uleb(body.length - 1);
    for (let i = 1; i < body.length; i++) writeFieldFromWat(buf, body[i], typeIndex);
    return;
  }
  if (isVec(body) && body[0] === 'array') {
    buf.push(CT_ARRAY);
    const elemForm = body[1];
    let mutable = false, vtRaw;
    if (isVec(elemForm) && elemForm[0] === 'mut') { mutable = true; vtRaw = elemForm[1]; }
    else vtRaw = elemForm;
    writeFieldType(buf, resolveValType(vtRaw, typeIndex), mutable);
    return;
  }
  if (isVec(body) && body[0] === 'func') {
    const { params, results } = parseParamResult(body.slice(1));
    writeFuncType(buf, params.map(p => resolveValType(p.type, typeIndex)),
                  results.map(r => resolveValType(r, typeIndex)));
    return;
  }
  throw new Error(`Unknown type body: ${JSON.stringify(body)}`);
}

function writeTypeDef(buf, typeDef, typeIndex) {
  const { body } = typeDef;
  if (isVec(body) && body[0] === 'sub') {
    let items = body.slice(1);
    const parents = [];
    while (isNameRef(items[0])) { parents.push(typeIndex[items[0]]); items = items.slice(1); }
    buf.push(ST_SUB);
    buf.uleb(parents.length);
    for (const p of parents) buf.uleb(p);
    writeTypeBody(buf, items[0], typeIndex);
    return;
  }
  if (isVec(body)) {
    buf.push(ST_SUB_FINAL); buf.uleb(0);
    writeTypeBody(buf, body, typeIndex);
    return;
  }
  throw new Error(`Cannot encode type def: ${JSON.stringify(body)}`);
}

// ============================================
// Block type
// ============================================

function writeBlockType(buf, bt) {
  if (bt === null || bt === undefined) { buf.push(0x40); return; }
  if (typeof bt === 'number') { buf.sleb(bt); return; }
  writeValType(buf, bt);
}

function resolveBlockType(items, typeIndex) {
  const first = items[0];
  if (isVec(first) && first[0] === 'result') {
    const resultTypes = first.slice(1).map(t => resolveValType(t, typeIndex));
    if (resultTypes.length === 1) return [resultTypes[0], items.slice(1)];
    throw new Error('Multi-value block types not yet supported');
  }
  if (isVec(first) && first[0] === 'type') return [resolveIdx(first[1], typeIndex), items.slice(1)];
  return [null, items];
}

function parseRefType(form, typeIndex) {
  if (typeof form === 'string') {
    switch (form) {
      case 'anyref': return { nullable: true, ht: 'any' };
      case 'funcref': return { nullable: true, ht: 'func' };
      case 'externref': return { nullable: true, ht: 'extern' };
      case 'eqref': return { nullable: true, ht: 'eq' };
      case 'i31ref': return { nullable: false, ht: 'i31' };
      case 'structref': return { nullable: true, ht: 'struct' };
      case 'arrayref': return { nullable: true, ht: 'array' };
      default:
        if (isNameRef(form)) return { nullable: false, ht: resolveIdx(form, typeIndex) };
        throw new Error(`Unknown ref type: ${form}`);
    }
  }
  if (isVec(form)) {
    const isNull = form[1] === 'null';
    const htRaw = isNull ? form[2] : form[1];
    return { nullable: isNull, ht: isNameRef(htRaw) ? resolveIdx(htRaw, typeIndex) : resolveHeapTypeStr(htRaw) };
  }
  throw new Error(`Bad ref type: ${JSON.stringify(form)}`);
}

// ============================================
// Instruction encoding — write directly to buf
// ============================================

function writeInstrs(buf, instrs, ctx) {
  for (let i = 0; i < instrs.length; i++) writeInstr(buf, instrs[i], ctx);
}

function writeInstr(buf, instr, ctx) {
  const { typeIndex, funcIndex, globalIndex, dataIndex, tagIndex,
          fieldIndices, localIndex, labelStack } = ctx;

  // Bare string instruction
  if (typeof instr === 'string') {
    const info = OPCODES.get(instr);
    if (info && info.imm === I.N) { buf.pushAll(info.bytes); return; }
    throw new Error(`Unknown bare instruction: ${instr}`);
  }

  if (!isVec(instr)) throw new Error(`Cannot encode instruction: ${JSON.stringify(instr)}`);

  const op = instr[0];

  // Block/loop
  if (op === 'block' || op === 'loop') {
    let idx = 1;
    let label = null;
    if (idx < instr.length && isNameRef(instr[idx])) { label = instr[idx]; idx++; }
    const items = instr.slice(idx);
    const [bt, remaining] = resolveBlockType(items, typeIndex);
    const newStack = [label, ...labelStack];
    const innerCtx = { ...ctx, labelStack: newStack };
    const info = OPCODES.get(op);
    buf.pushAll(info.bytes);
    writeBlockType(buf, bt);
    writeInstrs(buf, remaining, innerCtx);
    buf.push(0x0B);
    return;
  }

  if (op === 'if') {
    let idx = 1;
    let label = null;
    if (idx < instr.length && isNameRef(instr[idx])) { label = instr[idx]; idx++; }
    const items = instr.slice(idx);
    const [bt, remaining] = resolveBlockType(items, typeIndex);
    const newStack = [label, ...labelStack];
    const innerCtx = { ...ctx, labelStack: newStack };
    let thenForms = null, elseForms = null;
    const condForms = [];
    for (const form of remaining) {
      if (isVec(form) && form[0] === 'then') thenForms = form.slice(1);
      else if (isVec(form) && form[0] === 'else') elseForms = form.slice(1);
      else condForms.push(form);
    }
    writeInstrs(buf, condForms, ctx);
    buf.push(0x04);
    writeBlockType(buf, bt);
    if (thenForms) writeInstrs(buf, thenForms, innerCtx);
    if (elseForms) { buf.push(0x05); writeInstrs(buf, elseForms, innerCtx); }
    buf.push(0x0B);
    return;
  }

  if (op === 'try') {
    let idx = 1;
    let label = null;
    if (idx < instr.length && isNameRef(instr[idx])) { label = instr[idx]; idx++; }
    const items = instr.slice(idx);
    const [bt, remaining] = resolveBlockType(items, typeIndex);
    const newStack = [label, ...labelStack];
    const innerCtx = { ...ctx, labelStack: newStack };
    let doBody = [];
    const catches = [];
    for (const form of remaining) {
      if (isVec(form)) {
        if (form[0] === 'do') doBody = form.slice(1);
        else if (form[0] === 'catch') catches.push({ tag: form[1], body: form.slice(2) });
        else if (form[0] === 'catch_all') catches.push({ tag: null, body: form.slice(1) });
      }
    }
    buf.push(0x06);
    writeBlockType(buf, bt);
    writeInstrs(buf, doBody, innerCtx);
    for (const c of catches) {
      if (c.tag) { buf.push(0x07); buf.uleb(resolveIdx(c.tag, tagIndex)); }
      else buf.push(0x19);
      writeInstrs(buf, c.body, innerCtx);
    }
    buf.push(0x0B);
    return;
  }

  // Branch
  if (op === 'br' || op === 'br_if') {
    const labelRef = instr[1];
    let labelIdx;
    if (isNameRef(labelRef)) {
      labelIdx = labelStack.indexOf(labelRef);
      if (labelIdx === -1) throw new Error(`Unknown label: ${labelRef}`);
    } else labelIdx = parseIntLiteral(labelRef);
    writeInstrs(buf, instr.slice(2), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.uleb(labelIdx);
    return;
  }

  if (op === 'br_table') {
    const args = instr.slice(1);
    const labelRefs = [], exprForms = [];
    for (const a of args) {
      if (typeof a === 'string' && (isNameRef(a) || /^\d+$/.test(a))) labelRefs.push(a);
      else if (isVec(a)) exprForms.push(a);
    }
    const resolved = labelRefs.map(ref =>
      isNameRef(ref) ? labelStack.indexOf(ref) : parseIntLiteral(ref));
    writeInstrs(buf, exprForms, ctx);
    buf.push(0x0E);
    buf.uleb(resolved.length - 1);
    for (const l of resolved) buf.uleb(l);
    return;
  }

  // Call
  if (op === 'call' || op === 'return_call') {
    const funcIdx = resolveIdx(instr[1], funcIndex);
    writeInstrs(buf, instr.slice(2), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.uleb(funcIdx);
    return;
  }

  if (op === 'call_ref' || op === 'return_call_ref') {
    const typeIdx = resolveIdx(instr[1], typeIndex);
    writeInstrs(buf, instr.slice(2), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.uleb(typeIdx);
    return;
  }

  // Variables
  if (op === 'local.get' || op === 'local.set' || op === 'local.tee') {
    const varIdx = resolveIdx(instr[1], localIndex);
    writeInstrs(buf, instr.slice(2), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.uleb(varIdx);
    return;
  }

  if (op === 'global.get' || op === 'global.set') {
    const varIdx = resolveIdx(instr[1], globalIndex);
    writeInstrs(buf, instr.slice(2), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.uleb(varIdx);
    return;
  }

  // Constants
  if (op === 'i32.const') {
    let v = parseIntLiteral(instr[1]);
    if (v > 0x7FFFFFFF) v = v | 0;
    buf.push(0x41); buf.sleb(v);
    return;
  }
  if (op === 'i64.const') { buf.push(0x42); buf.sleb(parseIntLiteral(instr[1])); return; }
  if (op === 'f64.const') { buf.push(0x44); buf.f64(parseFloatLiteral(instr[1])); return; }
  if (op === 'f32.const') { buf.push(0x43); buf.f32(parseFloatLiteral(instr[1])); return; }

  // Memory instructions
  if (MEM_OPS.has(op)) {
    let offset = 0, align = 0;
    const operands = [];
    for (let i = 1; i < instr.length; i++) {
      const a = instr[i];
      if (typeof a === 'string' && a.charCodeAt(0) === 0x6F && a.startsWith('offset='))
        offset = parseIntLiteral(a.substring(7));
      else if (typeof a === 'string' && a.charCodeAt(0) === 0x61 && a.startsWith('align='))
        align = parseIntLiteral(a.substring(6));
      else operands.push(a);
    }
    const alignLog2 = align <= 1 ? 0 : align === 2 ? 1 : align === 4 ? 2 : align === 8 ? 3 : 0;
    writeInstrs(buf, operands, ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.uleb(alignLog2);
    buf.uleb(offset);
    return;
  }

  if (op === 'memory.size' || op === 'memory.grow') {
    writeInstrs(buf, instr.slice(1), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.push(0x00);
    return;
  }

  // Struct instructions
  if (op === 'struct.new') {
    const typeIdx = resolveIdx(instr[1], typeIndex);
    writeInstrs(buf, instr.slice(2), ctx);
    buf.push(0xFB); buf.push(0x00); buf.uleb(typeIdx);
    return;
  }
  if (op === 'struct.new_default') {
    buf.push(0xFB); buf.push(0x01); buf.uleb(resolveIdx(instr[1], typeIndex));
    return;
  }
  if (op === 'struct.get' || op === 'struct.get_s' || op === 'struct.get_u') {
    const typeRef = instr[1];
    const typeIdx = resolveIdx(typeRef, typeIndex);
    const fieldRef = instr[2];
    let fieldIdx;
    if (isNameRef(fieldRef)) {
      const fields = fieldIndices[typeRef];
      fieldIdx = fields && fields[fieldRef];
      if (fieldIdx === undefined) throw new Error(`Unknown field ${fieldRef} on ${typeRef}`);
    } else fieldIdx = parseIntLiteral(fieldRef);
    writeInstrs(buf, instr.slice(3), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.uleb(typeIdx); buf.uleb(fieldIdx);
    return;
  }
  if (op === 'struct.set') {
    const typeRef = instr[1];
    const typeIdx = resolveIdx(typeRef, typeIndex);
    const fieldRef = instr[2];
    let fieldIdx;
    if (isNameRef(fieldRef)) fieldIdx = fieldIndices[typeRef][fieldRef];
    else fieldIdx = parseIntLiteral(fieldRef);
    writeInstrs(buf, instr.slice(3), ctx);
    buf.push(0xFB); buf.push(0x05); buf.uleb(typeIdx); buf.uleb(fieldIdx);
    return;
  }

  // Array type ops
  if (ARRAY_TYPE_OPS.has(op)) {
    const typeIdx = resolveIdx(instr[1], typeIndex);
    writeInstrs(buf, instr.slice(2), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.uleb(typeIdx);
    return;
  }
  if (op === 'array.new_fixed') {
    const typeIdx = resolveIdx(instr[1], typeIndex);
    const n = parseIntLiteral(instr[2]);
    writeInstrs(buf, instr.slice(3), ctx);
    buf.push(0xFB); buf.push(0x08); buf.uleb(typeIdx); buf.uleb(n);
    return;
  }
  if (op === 'array.new_data') {
    const typeIdx = resolveIdx(instr[1], typeIndex);
    const dataIdx = resolveIdx(instr[2], dataIndex);
    writeInstrs(buf, instr.slice(3), ctx);
    buf.push(0xFB); buf.push(0x09); buf.uleb(typeIdx); buf.uleb(dataIdx);
    return;
  }
  if (op === 'array.new_elem') {
    const typeIdx = resolveIdx(instr[1], typeIndex);
    const elemIdx = parseIntLiteral(instr[2]);
    writeInstrs(buf, instr.slice(3), ctx);
    buf.push(0xFB); buf.push(0x0A); buf.uleb(typeIdx); buf.uleb(elemIdx);
    return;
  }
  if (op === 'array.copy') {
    const typeIdx1 = resolveIdx(instr[1], typeIndex);
    const typeIdx2 = resolveIdx(instr[2], typeIndex);
    writeInstrs(buf, instr.slice(3), ctx);
    buf.push(0xFB); buf.push(0x11); buf.uleb(typeIdx1); buf.uleb(typeIdx2);
    return;
  }
  if (op === 'array.len') {
    writeInstrs(buf, instr.slice(1), ctx);
    buf.push(0xFB); buf.push(0x0F);
    return;
  }

  // Reference instructions
  if (op === 'ref.null') {
    const ht = instr[1];
    buf.push(0xD0);
    writeHeapType(buf, isNameRef(ht) ? resolveIdx(ht, typeIndex) : resolveHeapTypeStr(ht));
    return;
  }
  if (op === 'ref.is_null') { writeInstrs(buf, instr.slice(1), ctx); buf.push(0xD1); return; }
  if (op === 'ref.func') { buf.push(0xD2); buf.uleb(resolveIdx(instr[1], funcIndex)); return; }
  if (op === 'ref.i31') { writeInstrs(buf, instr.slice(1), ctx); buf.push(0xFB); buf.push(0x1C); return; }
  if (op === 'i31.get_s') { writeInstrs(buf, instr.slice(1), ctx); buf.push(0xFB); buf.push(0x1D); return; }
  if (op === 'i31.get_u') { writeInstrs(buf, instr.slice(1), ctx); buf.push(0xFB); buf.push(0x1E); return; }
  if (op === 'ref.eq') { writeInstrs(buf, instr.slice(1), ctx); buf.push(0xD3); return; }
  if (op === 'ref.as_non_null') { writeInstrs(buf, instr.slice(1), ctx); buf.push(0xD4); return; }

  // ref.test / ref.cast
  if (op === 'ref.test' || op === 'ref.cast') {
    const rt = parseRefType(instr[1], typeIndex);
    writeInstrs(buf, instr.slice(2), ctx);
    const info = OPCODES.get(op);
    buf.pushAll(info.bytes);
    // Adjust last byte for nullable (+1)
    if (rt.nullable) buf.arr[buf.len - 1]++;
    writeHeapType(buf, rt.ht);
    return;
  }

  // br_on_cast / br_on_cast_fail
  if (op === 'br_on_cast' || op === 'br_on_cast_fail') {
    const labelRef = instr[1];
    let labelIdx;
    if (isNameRef(labelRef)) {
      labelIdx = labelStack.indexOf(labelRef);
      if (labelIdx === -1) throw new Error(`Unknown label: ${labelRef}`);
    } else labelIdx = parseIntLiteral(labelRef);
    const rt1 = parseRefType(instr[2], typeIndex);
    const rt2 = parseRefType(instr[3], typeIndex);
    const flags = (rt1.nullable ? 0x01 : 0x00) | (rt2.nullable ? 0x02 : 0x00);
    writeInstrs(buf, instr.slice(4), ctx);
    buf.pushAll(OPCODES.get(op).bytes);
    buf.push(flags);
    buf.uleb(labelIdx);
    writeHeapType(buf, rt1.ht);
    writeHeapType(buf, rt2.ht);
    return;
  }

  // throw
  if (op === 'throw') {
    const tagIdx = resolveIdx(instr[1], tagIndex);
    writeInstrs(buf, instr.slice(2), ctx);
    buf.push(0x08); buf.uleb(tagIdx);
    return;
  }

  // All other no-immediate instructions
  const info = OPCODES.get(op);
  if (info && info.imm === I.N) {
    writeInstrs(buf, instr.slice(1), ctx);
    buf.pushAll(info.bytes);
    return;
  }

  throw new Error(`Unknown instruction: ${op}`);
}

// ============================================
// Full module binary encoding
// ============================================

function encodeModuleFromWat(analysis) {
  const { imports, types, funcs, globals, memories, datas, elems, tags, start,
          typeIndex, funcIndex, globalIndex, dataIndex, tagIndex,
          fieldIndices, nFuncImports } = analysis;

  // Build signature cache for existing func types
  const existingFuncSigs = new Map();
  for (let i = 0; i < types.length; i++) {
    const { body } = types[i];
    let fb = null;
    if (isVec(body) && body[0] === 'func') fb = body;
    else if (isVec(body) && (body[0] === 'sub' || body[0] === 'sub_final')) {
      const inner = body[body.length - 1];
      if (isVec(inner) && inner[0] === 'func') fb = inner;
    }
    if (fb) {
      const { params, results } = parseParamResult(fb.slice(1));
      const pt = params.map(p => resolveValType(p.type, typeIndex));
      const rt = results.map(r => resolveValType(r, typeIndex));
      existingFuncSigs.set(JSON.stringify({ params: pt, results: rt }), i);
    }
  }

  const extraTypes = [];

  function findOrCreateFuncType(sig) {
    const key = JSON.stringify(sig);
    const existing = existingFuncSigs.get(key);
    if (existing !== undefined) return existing;
    for (let i = 0; i < extraTypes.length; i++) {
      if (JSON.stringify(extraTypes[i].sig) === key) return types.length + i;
    }
    const idx = types.length + extraTypes.length;
    extraTypes.push({ sig });
    return idx;
  }

  const funcImports = imports.filter(imp => imp.kind === 'func');
  const importFuncTypeIndices = funcImports.map(imp => {
    let desc = imp.desc;
    if (isNameRef(desc[0])) desc = desc.slice(1);
    const typeForm = desc.find(d => isVec(d) && d[0] === 'type');
    if (typeForm) return resolveIdx(typeForm[1], typeIndex);
    const { params, results } = parseParamResult(desc);
    return findOrCreateFuncType({
      params: params.map(p => resolveValType(p.type, typeIndex)),
      results: results.map(r => resolveValType(r, typeIndex))
    });
  });

  const definedFuncTypeIndices = funcs.map(f => {
    if (f.typeUse) return resolveIdx(f.typeUse, typeIndex);
    return findOrCreateFuncType({
      params: f.params.map(p => resolveValType(p.type, typeIndex)),
      results: f.results.map(r => resolveValType(r, typeIndex))
    });
  });

  const baseCtx = { typeIndex, funcIndex, globalIndex, dataIndex, tagIndex,
                    fieldIndices, localIndex: {}, labelStack: [] };

  // We'll build each section into a temp Buf, then write the section header + body to output
  const out = new Buf(131072);

  // WASM header
  out.pushAll([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]);

  // Helper: write a section from a temp buf
  function writeSection(sectionId, writeFn) {
    const tmp = new Buf(8192);
    writeFn(tmp);
    if (tmp.len === 0) return;
    out.push(sectionId);
    out.uleb(tmp.len);
    out.pushAll(tmp.toBytes());
  }

  // ---- Type section (1) ----
  writeSection(1, (sec) => {
    sec.uleb(types.length + extraTypes.length); // will be patched if extraTypes grows
  });
  // Actually, extraTypes may grow during import/function processing below,
  // so we need to defer the type section. Let's collect everything first, then assemble.

  // Reset: we need two passes. First pass: compute all type indices. Second: encode.
  out.len = 8; // reset to after header

  // ---- Compute everything first, then encode sections in order ----

  // Pre-compute code section (which needs local indices)
  const codeBufs = funcs.map(f => {
    const localIdx = {};
    for (let i = 0; i < f.params.length; i++) if (f.params[i].name) localIdx[f.params[i].name] = i;
    const nParams = f.params.length;
    for (let i = 0; i < f.locals.length; i++) if (f.locals[i].name) localIdx[f.locals[i].name] = nParams + i;
    const funcCtx = { ...baseCtx, localIndex: localIdx };

    const localTypes = f.locals.map(l => resolveValType(l.type, typeIndex));
    // Compress runs
    const runs = [];
    for (const t of localTypes) {
      const ts = typeof t === 'string' ? t : JSON.stringify(t);
      if (runs.length > 0 && runs[runs.length - 1].key === ts) runs[runs.length - 1].count++;
      else runs.push({ type: t, key: ts, count: 1 });
    }

    const codeBuf = new Buf(256);
    codeBuf.uleb(runs.length);
    for (const r of runs) { codeBuf.uleb(r.count); writeValType(codeBuf, r.type); }
    writeInstrs(codeBuf, f.body, funcCtx);
    codeBuf.push(0x0B); // end
    return codeBuf;
  });

  // Now extraTypes is fully populated. Encode sections in order.

  // Type section (1)
  writeSection(1, (sec) => {
    const total = types.length + extraTypes.length;
    sec.uleb(total);
    for (const t of types) writeTypeDef(sec, t, typeIndex);
    for (const et of extraTypes) writeFuncType(sec, et.sig.params, et.sig.results);
  });

  // Import section (2)
  if (imports.length > 0) {
    writeSection(2, (sec) => {
      sec.uleb(imports.length);
      for (const imp of imports) {
        sec.name(imp.module);
        sec.name(imp.field);
        if (imp.kind === 'func') {
          sec.push(0x00);
          sec.uleb(importFuncTypeIndices[funcImports.indexOf(imp)]);
        } else if (imp.kind === 'memory') {
          sec.push(0x02); sec.push(0x00); sec.uleb(0);
        }
      }
    });
  }

  // Function section (3)
  if (funcs.length > 0) {
    writeSection(3, (sec) => {
      sec.uleb(definedFuncTypeIndices.length);
      for (const idx of definedFuncTypeIndices) sec.uleb(idx);
    });
  }

  // Memory section (5)
  if (memories.length > 0) {
    writeSection(5, (sec) => {
      sec.uleb(memories.length);
      for (const mem of memories) {
        if (mem.max != null) { sec.push(0x01); sec.uleb(mem.min); sec.uleb(mem.max); }
        else { sec.push(0x00); sec.uleb(mem.min); }
      }
    });
  }

  // Tag section (13)
  if (tags.length > 0) {
    writeSection(13, (sec) => {
      sec.uleb(tags.length);
      for (const t of tags) {
        const paramTypes = t.paramTypes.map(p => resolveValType(p, typeIndex));
        const typeIdx = findOrCreateFuncType({ params: paramTypes, results: [] });
        sec.push(0x00); sec.uleb(typeIdx);
      }
    });
  }

  // Global section (6)
  if (globals.length > 0) {
    writeSection(6, (sec) => {
      sec.uleb(globals.length);
      for (const g of globals) {
        writeValType(sec, resolveValType(g.type, typeIndex));
        sec.push(g.mutable ? 0x01 : 0x00);
        writeInstrs(sec, g.init, baseCtx);
        sec.push(0x0B);
      }
    });
  }

  // Export section (7)
  {
    // Collect all exports
    const expBuf = new Buf(4096);
    let expCount = 0;
    for (const mem of memories) {
      for (const name of mem.exports) { expBuf.name(name); expBuf.push(0x02); expBuf.uleb(0); expCount++; }
    }
    for (let i = 0; i < funcs.length; i++) {
      for (const name of funcs[i].exports) {
        expBuf.name(name); expBuf.push(0x00); expBuf.uleb(nFuncImports + i); expCount++;
      }
    }
    for (let i = 0; i < globals.length; i++) {
      for (const name of globals[i].exports) {
        expBuf.name(name); expBuf.push(0x03); expBuf.uleb(i); expCount++;
      }
    }
    for (const exp of analysis.exports) {
      if (isVec(exp) && exp[0] === 'export') {
        const name = stringVal(exp[1]);
        const desc = exp[2];
        const kind = desc[0];
        const kindByte = kind === 'func' ? 0x00 : kind === 'global' ? 0x03 : kind === 'memory' ? 0x02 : 0x01;
        const idxMap = kind === 'func' ? funcIndex : kind === 'global' ? globalIndex : {};
        expBuf.name(name); expBuf.push(kindByte); expBuf.uleb(resolveIdx(desc[1], idxMap)); expCount++;
      }
    }
    if (expCount > 0) {
      const sec = new Buf(expBuf.len + 8);
      sec.uleb(expCount);
      sec.pushAll(expBuf.toBytes());
      out.push(7);
      out.uleb(sec.len);
      out.pushAll(sec.toBytes());
    }
  }

  // Start section (8)
  if (start) {
    const startIdx = resolveIdx(start, funcIndex);
    const sec = new Buf(8);
    sec.uleb(startIdx);
    out.push(8); out.uleb(sec.len); out.pushAll(sec.toBytes());
  }

  // Element section (9)
  if (elems.length > 0) {
    writeSection(9, (sec) => {
      sec.uleb(elems.length);
      for (const e of elems) {
        if (e.kind === 'declare') {
          sec.push(0x03); sec.push(0x00);
          sec.uleb(e.funcs.length);
          for (const f of e.funcs) sec.uleb(resolveIdx(f, funcIndex));
        }
      }
    });
  }

  // Data count section (12)
  if (datas.length > 0) {
    const sec = new Buf(8);
    sec.uleb(datas.length);
    out.push(12); out.uleb(sec.len); out.pushAll(sec.toBytes());
  }

  // Code section (10)
  if (codeBufs.length > 0) {
    writeSection(10, (sec) => {
      sec.uleb(codeBufs.length);
      for (const cb of codeBufs) {
        sec.uleb(cb.len);
        sec.pushAll(cb.toBytes());
      }
    });
  }

  // Data section (11)
  if (datas.length > 0) {
    writeSection(11, (sec) => {
      sec.uleb(datas.length);
      for (const d of datas) {
        const s = d.data;
        sec.push(0x01); // passive
        sec.uleb(s.length);
        for (let i = 0; i < s.length; i++) sec.push(s.charCodeAt(i));
      }
    });
  }

  return out.toBytes();
}

// ============================================
// Public API
// ============================================

export function watToWasm(watSource) {
  const parsed = parseWat(watSource);
  const analysis = analyzeModule(parsed);
  return encodeModuleFromWat(analysis);
}

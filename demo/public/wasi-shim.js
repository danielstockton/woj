// WASI polyfill for running the woj compiler in the browser.
// Implements the 9 WASI imports the compiler needs.

export function createWasiShim(virtualFS, args) {
  // File descriptor table: 0=stdin, 1=stdout, 2=stderr, 3+=opened files
  let nextFd = 3;
  const fdTable = new Map(); // fd -> { path, data (Uint8Array), pos }

  // Output capture
  let stdoutBuf = '';
  let stderrBuf = '';

  // WASM memory (set after instantiation)
  let memory = null;

  function setMemory(mem) {
    memory = mem;
  }

  function getStdout() { return stdoutBuf; }
  function getStderr() { return stderrBuf; }
  function resetOutput() { stdoutBuf = ''; stderrBuf = ''; }

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  function mem8() { return new Uint8Array(memory.buffer); }
  function mem32() { return new DataView(memory.buffer); }

  // fd_write(fd, iovs_ptr, iovs_count, nwritten_ptr) -> errno
  function fd_write(fd, iovs, count, nwritten) {
    const view = mem32();
    const bytes = mem8();
    let totalWritten = 0;

    for (let i = 0; i < count; i++) {
      const ptr = view.getUint32(iovs + i * 8, true);
      const len = view.getUint32(iovs + i * 8 + 4, true);
      const chunk = bytes.slice(ptr, ptr + len);
      const text = decoder.decode(chunk);

      if (fd === 1) {
        stdoutBuf += text;
      } else if (fd === 2) {
        stderrBuf += text;
      }
      totalWritten += len;
    }

    view.setUint32(nwritten, totalWritten, true);
    return 0;
  }

  // fd_read(fd, iovs_ptr, iovs_count, nread_ptr) -> errno
  function fd_read(fd, iovs, count, nread) {
    const view = mem32();
    const bytes = mem8();
    const entry = fdTable.get(fd);
    if (!entry) {
      view.setUint32(nread, 0, true);
      return 8; // EBADF
    }

    let totalRead = 0;
    for (let i = 0; i < count; i++) {
      const ptr = view.getUint32(iovs + i * 8, true);
      const len = view.getUint32(iovs + i * 8 + 4, true);
      const remaining = entry.data.length - entry.pos;
      const toRead = Math.min(len, remaining);

      if (toRead > 0) {
        bytes.set(entry.data.subarray(entry.pos, entry.pos + toRead), ptr);
        entry.pos += toRead;
        totalRead += toRead;
      }
    }

    view.setUint32(nread, totalRead, true);
    return 0;
  }

  // path_open(dirfd, dirflags, path_ptr, path_len, oflags,
  //           fs_rights_base(i64), fs_rights_inheriting(i64), fdflags, fd_ptr)
  // i64 params arrive as BigInt in JS
  function path_open(dirfd, dirflags, pathPtr, pathLen, oflags,
                     rightsBase, rightsInh, fdflags, fdPtr) {
    const bytes = mem8();
    const view = mem32();

    const pathBytes = bytes.slice(pathPtr, pathPtr + pathLen);
    const path = decoder.decode(pathBytes);

    const content = virtualFS[path];
    if (content === undefined) {
      return 44; // ENOENT
    }

    const fd = nextFd++;
    const data = typeof content === 'string' ? encoder.encode(content) : content;
    fdTable.set(fd, { path, data, pos: 0 });
    view.setUint32(fdPtr, fd, true);
    return 0;
  }

  // fd_close(fd) -> errno
  function fd_close(fd) {
    fdTable.delete(fd);
    return 0;
  }

  // fd_seek(fd, offset(i64), whence, newoff_ptr) -> errno
  // offset arrives as BigInt
  function fd_seek(fd, offset, whence, newoffPtr) {
    const entry = fdTable.get(fd);
    if (!entry) return 8;

    const off = Number(offset);
    if (whence === 0) entry.pos = off;                        // SEEK_SET
    else if (whence === 1) entry.pos += off;                  // SEEK_CUR
    else if (whence === 2) entry.pos = entry.data.length + off; // SEEK_END

    const view = mem32();
    view.setBigUint64(newoffPtr, BigInt(entry.pos), true);
    return 0;
  }

  // fd_filestat_get(fd, buf_ptr) -> errno
  function fd_filestat_get(fd, buf) {
    const entry = fdTable.get(fd);
    if (!entry) return 8;

    const view = mem32();
    // filestat struct: dev(8) ino(8) filetype(1+pad to 8) nlink(8) size(8) ...
    // Total 64 bytes. We just need to write the size at offset 32.
    for (let i = 0; i < 64; i += 4) {
      view.setUint32(buf + i, 0, true);
    }
    // filetype at offset 16: 4 = regular file
    view.setUint8(buf + 16, 4);
    // size at offset 32 (i64, little-endian)
    view.setUint32(buf + 32, entry.data.length, true);
    view.setUint32(buf + 36, 0, true);
    return 0;
  }

  // args_sizes_get(argc_ptr, argv_buf_size_ptr) -> errno
  function args_sizes_get(argcPtr, bufSizePtr) {
    const view = mem32();
    view.setUint32(argcPtr, args.length, true);
    let totalSize = 0;
    for (const arg of args) {
      totalSize += encoder.encode(arg).length + 1; // +1 for null terminator
    }
    view.setUint32(bufSizePtr, totalSize, true);
    return 0;
  }

  // args_get(argv_ptr, argv_buf_ptr) -> errno
  function args_get(argvPtr, argvBufPtr) {
    const view = mem32();
    const bytes = mem8();
    let bufOffset = argvBufPtr;

    for (let i = 0; i < args.length; i++) {
      view.setUint32(argvPtr + i * 4, bufOffset, true);
      const encoded = encoder.encode(args[i]);
      bytes.set(encoded, bufOffset);
      bytes[bufOffset + encoded.length] = 0; // null terminator
      bufOffset += encoded.length + 1;
    }
    return 0;
  }

  // clock_time_get(id, precision(i64), time_ptr) -> errno
  // precision arrives as BigInt
  function clock_time_get(id, precision, timePtr) {
    const view = mem32();
    const now = BigInt(Math.floor(performance.now() * 1e6)); // nanoseconds
    view.setBigUint64(timePtr, now, true);
    return 0;
  }

  // The import object matching the WAT signatures exactly
  const imports = {
    wasi_snapshot_preview1: {
      fd_write,
      fd_read,
      fd_close,
      fd_seek,
      path_open,
      fd_filestat_get,
      args_sizes_get,
      args_get,
      clock_time_get,
    }
  };

  return { imports, setMemory, getStdout, getStderr, resetOutput };
}

// Minimal WASI shim for compiled user code (only fd_write matters)
export function createUserWasiShim() {
  let memory = null;
  let stdoutBuf = '';

  const decoder = new TextDecoder();

  function setMemory(mem) { memory = mem; }
  function getStdout() { return stdoutBuf; }
  function resetOutput() { stdoutBuf = ''; }

  function fd_write(fd, iovs, count, nwritten) {
    const view = new DataView(memory.buffer);
    const bytes = new Uint8Array(memory.buffer);
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
  }

  const stub = () => 0;

  const imports = {
    wasi_snapshot_preview1: {
      fd_write,
      fd_read: stub,
      fd_close: stub,
      fd_seek: stub,       // (i32, i64, i32, i32) — BigInt offset ignored
      path_open: stub,     // (i32, i32, i32, i32, i32, i64, i64, i32, i32)
      fd_filestat_get: stub,
      args_sizes_get: stub,
      args_get: stub,
      clock_time_get: stub, // (i32, i64, i32) — BigInt precision ignored
    }
  };

  return { imports, setMemory, getStdout, resetOutput };
}

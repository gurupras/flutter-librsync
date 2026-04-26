import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi/bindings.dart' as b;

export 'ffi/bindings.dart' show LibrsyncException;

// ─── Chunk size ───────────────────────────────────────────────────────────────

/// Default chunk size used when reading files for streaming operations.
const int defaultChunkSize = 256 * 1024; // 256 KB

// ─── SigHandle ────────────────────────────────────────────────────────────────

/// A parsed signature ready to be used as the basis for one or more
/// [DeltaStream] sessions.
///
/// Parse once with [SigHandle.fromBytes], then create multiple [DeltaStream]s
/// from the same handle without re-parsing.  Call [close] when done with all
/// delta sessions.
///
/// ```dart
/// final sig = SigHandle.fromBytes(sigBytes);
/// try {
///   final delta = DeltaStream(sig);
///   // ...feed and end delta...
/// } finally {
///   sig.close();
/// }
/// ```
final class SigHandle {
  final int _handle;
  bool _closed = false;

  SigHandle._(this._handle);

  /// Internal: raw native handle for use by sibling session classes.
  /// Not part of the public API — do not call from outside the package.
  int get internalHandle => _handle;

  /// Parses [sigBytes] into an in-memory lookup structure.
  ///
  /// The library copies the input — [sigBytes] may be freed immediately after.
  factory SigHandle.fromBytes(Uint8List sigBytes) {
    final ptr = b.copyToNative(sigBytes);
    try {
      final handle = b.sigParseHandle(ptr, sigBytes.length);
      if (handle == 0) throw const b.LibrsyncException('failed to parse signature');
      return SigHandle._(handle);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Frees the parsed signature.
  ///
  /// Safe to call even while [DeltaStream]s created from this handle are still
  /// active — those sessions hold their own internal reference.
  void close() {
    if (_closed) return;
    b.sigFreeHandle(_handle);
    _closed = true;
  }
}

// ─── SignatureStream ──────────────────────────────────────────────────────────

/// A streaming signature session.
///
/// Feed chunks of the source file via [feed]; call [end] to finalise.
/// Each call returns the signature bytes produced for that chunk (may be empty).
/// [end] flushes any remaining output and invalidates the session.
///
/// On an error path (before [end] is called), call [close] to release resources.
///
/// **Deprecated:** prefer [SignatureSession] (zero-copy + cleaner API) or
/// the `Stream<Uint8List>.rsyncSignature()` extension for stream pipelines.
///
/// ```dart
/// final stream = SignatureStream();
/// try {
///   for (final chunk in chunks) {
///     final out = stream.feed(chunk);
///     if (out.isNotEmpty) sink.add(out);
///   }
///   final tail = stream.end();
///   if (tail.isNotEmpty) sink.add(tail);
/// } catch (_) {
///   stream.close();
///   rethrow;
/// }
/// ```
final class SignatureStream {
  final int _handle;
  bool _ended = false;

  SignatureStream({
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = b.librsyncBlake2,
  }) : _handle = b.signatureNewHandle(blockLen, strongLen, sigType) {
    if (_handle == 0) {
      throw const b.LibrsyncException('failed to create signature session');
    }
  }

  /// Feeds [input] into the session.
  ///
  /// The first call returns the 12-byte signature header immediately,
  /// regardless of whether any complete blocks were processed.
  /// Subsequent calls return output for each complete block accumulated;
  /// consecutive calls may return an empty [Uint8List] if the buffered data
  /// has not yet reached a [blockLen]-byte boundary.  This is normal — output
  /// will arrive on a later [feed] call or on [end].
  Uint8List feed(Uint8List input) {
    final ptr = b.copyToNative(input);
    try {
      return b.signatureFeedHandle(_handle, ptr, input.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Zero-copy variant of [feed] for callers managing their own C-heap buffers.
  ///
  /// [ptr] must remain valid and unmodified until this call returns.
  /// The caller retains ownership of [ptr] — this method never frees it.
  Uint8List feedPtr(ffi.Pointer<ffi.Uint8> ptr, int length) =>
      b.signatureFeedHandle(_handle, ptr, length);

  /// Fully zero-copy feed: writes any output directly into [dst] (capacity
  /// [dstLen]) and returns the number of bytes written. [bytesWrittenPtr] is a
  /// caller-provided `size_t` scratch slot used to receive the count from
  /// native code (allocate once with `calloc<Size>()` and reuse).
  /// [morePendingPtr] is an `int32_t` scratch slot that is set to 1 iff
  /// output remains buffered internally; drain by re-calling with
  /// `inputLen: 0` until it is 0.
  ///
  /// All five pointers belong to the caller; this method never allocates.
  @Deprecated('Use SignatureSession (lib/src/sessions.dart) for the clean API.')
  int feedInto(
    ffi.Pointer<ffi.Uint8> inputPtr, int inputLen,
    ffi.Pointer<ffi.Uint8> dst, int dstLen,
    ffi.Pointer<ffi.Size> bytesWrittenPtr,
    ffi.Pointer<ffi.Int32> morePendingPtr,
  ) {
    b.signatureFeedIntoHandle(
        _handle, inputPtr, inputLen, dst, dstLen, bytesWrittenPtr, morePendingPtr);
    return bytesWrittenPtr.value;
  }

  /// Fully zero-copy end: drains the final output into [dst] in [dstLen]-sized
  /// chunks. Call repeatedly until [morePendingPtr] reads 0. The handle is
  /// dropped on the call that sets [morePendingPtr] to 0; do not call [close]
  /// after that.
  @Deprecated('Use SignatureSession (lib/src/sessions.dart) for the clean API.')
  int endInto(
    ffi.Pointer<ffi.Uint8> dst, int dstLen,
    ffi.Pointer<ffi.Size> bytesWrittenPtr,
    ffi.Pointer<ffi.Int32> morePendingPtr,
  ) {
    b.signatureEndIntoHandle(_handle, dst, dstLen, bytesWrittenPtr, morePendingPtr);
    if (morePendingPtr.value == 0) _ended = true;
    return bytesWrittenPtr.value;
  }

  /// Finalises the session and returns any remaining output.
  ///
  /// Invalidates the handle — do not call [close] after [end].
  Uint8List end() {
    // Set _ended before the native call so close() is a no-op if end() throws.
    _ended = true;
    return b.signatureEndHandle(_handle);
  }

  /// Abandons the session without finalising.
  ///
  /// Use only on the error path when [end] has not been called.
  void close() {
    if (_ended) return;
    b.signatureFreeHandle(_handle);
    _ended = true;
  }
}

// ─── DeltaStream ─────────────────────────────────────────────────────────────

/// A streaming delta session.
///
/// Create from a [SigHandle], feed chunks of the new file via [feed], finalise
/// with [end].  The [SigHandle] remains valid and may be reused for further
/// [DeltaStream] sessions.
///
/// ```dart
/// final sig = SigHandle.fromBytes(sigBytes);
/// final stream = DeltaStream(sig);
/// try {
///   for (final chunk in newFileChunks) {
///     final out = stream.feed(chunk);
///     if (out.isNotEmpty) sink.add(out);
///   }
///   final tail = stream.end();
///   if (tail.isNotEmpty) sink.add(tail);
/// } catch (_) {
///   stream.close();
///   rethrow;
/// } finally {
///   sig.close();
/// }
/// ```
final class DeltaStream {
  final int _handle;
  bool _ended = false;

  DeltaStream(SigHandle sig)
      : _handle = b.deltaNewHandle(sig._handle) {
    if (_handle == 0) {
      throw const b.LibrsyncException('failed to create delta session');
    }
  }

  /// Feeds [input] (a chunk of the new file) into the session.
  ///
  /// Returns delta bytes produced so far. May be empty — the library buffers
  /// literals internally up to 16 MB before flushing.
  Uint8List feed(Uint8List input) {
    final ptr = b.copyToNative(input);
    try {
      return b.deltaFeedHandle(_handle, ptr, input.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Zero-copy variant of [feed] for callers managing their own C-heap buffers.
  ///
  /// [ptr] must remain valid and unmodified until this call returns.
  /// The caller retains ownership of [ptr] — this method never frees it.
  Uint8List feedPtr(ffi.Pointer<ffi.Uint8> ptr, int length) =>
      b.deltaFeedHandle(_handle, ptr, length);

  /// Fully zero-copy feed. See [SignatureStream.feedInto] for semantics.
  @Deprecated('Use DeltaSession (lib/src/sessions.dart) for the clean API.')
  int feedInto(
    ffi.Pointer<ffi.Uint8> inputPtr, int inputLen,
    ffi.Pointer<ffi.Uint8> dst, int dstLen,
    ffi.Pointer<ffi.Size> bytesWrittenPtr,
    ffi.Pointer<ffi.Int32> morePendingPtr,
  ) {
    b.deltaFeedIntoHandle(
        _handle, inputPtr, inputLen, dst, dstLen, bytesWrittenPtr, morePendingPtr);
    return bytesWrittenPtr.value;
  }

  /// Fully zero-copy end. See [SignatureStream.endInto] for semantics.
  @Deprecated('Use DeltaSession (lib/src/sessions.dart) for the clean API.')
  int endInto(
    ffi.Pointer<ffi.Uint8> dst, int dstLen,
    ffi.Pointer<ffi.Size> bytesWrittenPtr,
    ffi.Pointer<ffi.Int32> morePendingPtr,
  ) {
    b.deltaEndIntoHandle(_handle, dst, dstLen, bytesWrittenPtr, morePendingPtr);
    if (morePendingPtr.value == 0) _ended = true;
    return bytesWrittenPtr.value;
  }

  /// Finalises the session and flushes all remaining output.
  ///
  /// Invalidates the handle — do not call [close] after [end].
  Uint8List end() {
    // Set _ended before the native call so close() is a no-op if end() throws.
    _ended = true;
    return b.deltaEndHandle(_handle);
  }

  /// Abandons the session without finalising.
  ///
  /// Use only on the error path when [end] has not been called.
  void close() {
    if (_ended) return;
    b.deltaFreeHandle(_handle);
    _ended = true;
  }
}

// ─── PatchStream ─────────────────────────────────────────────────────────────

/// A streaming patch session.
///
/// The patch algorithm requires random access to the base file.  Use
/// [PatchStream.fromFile] or [PatchStream.fromBytes] — both copy base data to
/// C-heap memory at construction time so the Go patch goroutine can access it
/// from any OS thread without Dart callbacks.
///
/// Feed delta chunks via [feed]; call [end] to apply the delta and receive all
/// reconstructed bytes.
///
/// ```dart
/// final stream = PatchStream.fromFile(file);
/// try {
///   for (final chunk in deltaChunks) {
///     final partial = stream.feed(chunk);
///     if (partial.isNotEmpty) sink.add(partial);
///   }
///   final tail = stream.end();
///   if (tail.isNotEmpty) sink.add(tail);
/// } catch (_) {
///   stream.close();
///   rethrow;
/// }
/// ```
final class PatchStream {
  final int _handle;
  bool _ended = false;

  // Non-null only for the deprecated raw-callback constructor path.
  // Both are null/nullptr for the safe fromBytes/fromFile path.
  final ffi.NativeCallable<b.ReadAtFn>? _callable;
  final ffi.Pointer<b.RsReadSeekerT> _seekerPtr;

  PatchStream._(this._handle, this._callable, this._seekerPtr);

  /// Creates a [PatchStream] backed by the file at [path].
  ///
  /// Go opens the file and reads it on demand using thread-safe random access
  /// (pread on POSIX, overlapped I/O on Windows).  The file is never fully
  /// loaded into memory — suitable for arbitrarily large base files.
  /// Go closes the file when the session ends or is freed.
  ///
  /// Throws [LibrsyncException] if the file cannot be opened.
  factory PatchStream.fromPath(String path) {
    final handle = b.patchNewPathHandle(path);
    if (handle == 0) {
      throw b.LibrsyncException('failed to open base file: $path');
    }
    return PatchStream._(handle, null, ffi.nullptr);
  }

  /// Creates a [PatchStream] backed by an in-memory [base].
  ///
  /// The base data is copied to C-heap memory at construction so the Go patch
  /// goroutine can read it safely from any OS thread.
  factory PatchStream.fromBytes(Uint8List base) {
    final dataPtr = b.copyToNative(base);
    // Go takes ownership of dataPtr on success — do NOT free on success path.
    final handle = b.patchNewBufHandle(dataPtr, base.length);
    if (handle == 0) {
      calloc.free(dataPtr);
      throw const b.LibrsyncException('failed to create patch session');
    }
    return PatchStream._(handle, null, ffi.nullptr);
  }

  /// Creates a [PatchStream] backed by [file].
  ///
  /// The file is read from the beginning into C-heap memory at construction so
  /// the Go patch goroutine can read it safely from any OS thread.  [file] may
  /// be closed after this constructor returns.  **Do not call from the UI isolate.**
  factory PatchStream.fromFile(RandomAccessFile file) {
    file.setPositionSync(0);
    final bytes = file.readSync(file.lengthSync());
    return PatchStream.fromBytes(bytes);
  }

  /// Creates a [PatchStream] backed by a caller-supplied [readAt] callback.
  ///
  /// **Deprecated.** `NativeCallable.isolateLocal` is unsafe when the Go patch
  /// goroutine invokes the callback from a background OS thread.  Use
  /// [PatchStream.fromBytes] or [PatchStream.fromFile] instead — they use a
  /// C-heap readAt that is thread-safe.
  ///
  /// [readAt] receives `(offset, buffer)` and must fill [buffer] from the base
  /// file starting at [offset].  Returns bytes read; fewer than
  /// `buffer.length` is only permitted at EOF.
  @Deprecated(
    'NativeCallable.isolateLocal is called from a Go background OS thread, '
    'which is unsafe. Use PatchStream.fromBytes or PatchStream.fromFile instead.',
  )
  factory PatchStream.withCallback(
      int Function(int offset, Uint8List buffer) readAt) {
    final seekerPtr = calloc<b.RsReadSeekerT>();

    final callable = ffi.NativeCallable<b.ReadAtFn>.isolateLocal(
      (ffi.Pointer<ffi.Void> _, int offset, ffi.Pointer<ffi.Uint8> buf,
          int len, ffi.Pointer<ffi.Size> bytesRead) {
        try {
          final view = buf.asTypedList(len);
          final n = readAt(offset, view);
          bytesRead.value = n;
          return 0;
        } catch (_) {
          bytesRead.value = 0;
          return -1;
        }
      },
      exceptionalReturn: -1,
    );

    seekerPtr.ref.userdata = ffi.nullptr;
    seekerPtr.ref.read_at = callable.nativeFunction;

    final handle = b.patchNewHandle(seekerPtr);
    if (handle == 0) {
      callable.close();
      calloc.free(seekerPtr);
      throw const b.LibrsyncException('failed to create patch session');
    }
    return PatchStream._(handle, callable, seekerPtr);
  }

  /// Sends a [delta] chunk to the patch goroutine.
  ///
  /// Returns any reconstructed bytes produced so far.  May be empty — all
  /// output is guaranteed to be flushed by [end].
  Uint8List feed(Uint8List delta) {
    final ptr = b.copyToNative(delta);
    try {
      return b.patchFeedHandle(_handle, ptr, delta.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Zero-copy variant of [feed] for callers managing their own C-heap buffers.
  ///
  /// [ptr] must remain valid and unmodified until this call returns.
  /// The caller retains ownership of [ptr] — this method never frees it.
  Uint8List feedPtr(ffi.Pointer<ffi.Uint8> ptr, int length) =>
      b.patchFeedHandle(_handle, ptr, length);

  /// Fully zero-copy feed. See [SignatureStream.feedInto] for semantics.
  @Deprecated('Use PatchSession (lib/src/sessions.dart) for the clean API.')
  int feedInto(
    ffi.Pointer<ffi.Uint8> deltaPtr, int deltaLen,
    ffi.Pointer<ffi.Uint8> dst, int dstLen,
    ffi.Pointer<ffi.Size> bytesWrittenPtr,
    ffi.Pointer<ffi.Int32> morePendingPtr,
  ) {
    b.patchFeedIntoHandle(
        _handle, deltaPtr, deltaLen, dst, dstLen, bytesWrittenPtr, morePendingPtr);
    return bytesWrittenPtr.value;
  }

  /// Fully zero-copy end. See [SignatureStream.endInto] for semantics.
  @Deprecated('Use PatchSession (lib/src/sessions.dart) for the clean API.')
  int endInto(
    ffi.Pointer<ffi.Uint8> dst, int dstLen,
    ffi.Pointer<ffi.Size> bytesWrittenPtr,
    ffi.Pointer<ffi.Int32> morePendingPtr,
  ) {
    b.patchEndIntoHandle(_handle, dst, dstLen, bytesWrittenPtr, morePendingPtr);
    if (morePendingPtr.value == 0) {
      _ended = true;
      _teardown();
    }
    return bytesWrittenPtr.value;
  }

  /// Finalises the session and returns any remaining reconstructed bytes.
  ///
  /// Invalidates the handle — do not call [close] after [end].
  Uint8List end() {
    // Set _ended before the native call: Go's librsync_patch_end drops the
    // handle unconditionally (even on error), so close() must not free it again.
    _ended = true;
    try {
      return b.patchEndHandle(_handle);
    } finally {
      _teardown();
    }
  }

  /// Abandons the session without finalising.
  ///
  /// Use only on the error path when [end] has not been called.
  void close() {
    if (_ended) return;
    _ended = true;
    b.patchFreeHandle(_handle);
    _teardown();
  }

  void _teardown() {
    _callable?.close();
    if (_seekerPtr != ffi.nullptr) calloc.free(_seekerPtr);
  }
}

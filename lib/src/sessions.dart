// ignore_for_file: deprecated_member_use_from_same_package
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi/bindings.dart' as b;
import 'streaming.dart' show SigHandle;

export 'ffi/bindings.dart' show LibrsyncException;
export 'streaming.dart' show SigHandle;

/// Default output buffer capacity for sessions when none is specified.
/// Sized to fit one delta literal flush (16 MB) at a 16:1 compression ratio,
/// or several signature blocks; tune per workload if needed.
const int defaultOutputCapacity = 1 << 20; // 1 MB

/// Callback invoked with each output chunk produced by a session.
///
/// **Lifetime:** the [Uint8List] passed to this callback is a view over the
/// session's internal C-heap output buffer.  It is valid only for the duration
/// of this call.  To retain the bytes past the callback, copy them
/// (e.g. `Uint8List.fromList(chunk)`) or pass them to a sink that copies
/// synchronously (e.g. [IOSink.add], [BytesBuilder.add]).
typedef RsyncOnChunk = void Function(Uint8List chunk);

// ─── RsyncBuffer ──────────────────────────────────────────────────────────────

/// A reusable C-heap byte buffer with a [Uint8List] view over the same memory.
///
/// Use this to read input directly into native memory and avoid per-chunk
/// copies between Dart and C heaps:
///
/// ```dart
/// final buf = RsyncBuffer(64 * 1024);
/// try {
///   int n;
///   while ((n = file.readIntoSync(buf.view)) > 0) {
///     session.feed(buf, n, sink.add);
///   }
/// } finally {
///   buf.dispose();
/// }
/// ```
final class RsyncBuffer {
  /// Allocates a buffer of [capacity] bytes on the C heap.
  factory RsyncBuffer(int capacity) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
    final ptr = calloc<ffi.Uint8>(capacity);
    return RsyncBuffer._(ptr, capacity);
  }

  RsyncBuffer._(this._ptr, this.capacity) : _view = _ptr.asTypedList(capacity);

  /// Buffer capacity in bytes.
  final int capacity;
  final ffi.Pointer<ffi.Uint8> _ptr;
  final Uint8List _view;
  bool _disposed = false;

  /// Writable [Uint8List] view backed by the underlying C-heap memory.
  ///
  /// Use with `RandomAccessFile.readIntoSync(buf.view)` or
  /// `view.setRange(0, n, source)` to fill the buffer in place.
  Uint8List get view {
    if (_disposed) throw StateError('RsyncBuffer is disposed');
    return _view;
  }

  /// Raw native pointer to the first byte. Most callers should use [view].
  ffi.Pointer<ffi.Uint8> get ptr {
    if (_disposed) throw StateError('RsyncBuffer is disposed');
    return _ptr;
  }

  /// Frees the underlying C-heap memory. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    calloc.free(_ptr);
  }
}

// ─── _IntoSession (shared base) ───────────────────────────────────────────────

abstract class _IntoSession {
  _IntoSession({required int outputCapacity})
      : _outCap = outputCapacity {
    if (outputCapacity <= 0) {
      throw ArgumentError.value(
          outputCapacity, 'outputCapacity', 'must be positive');
    }
    _outPtr = calloc<ffi.Uint8>(outputCapacity);
    _outView = _outPtr.asTypedList(outputCapacity);
    _bw = calloc<ffi.Size>();
    _more = calloc<ffi.Int32>();
  }

  final int _outCap;
  late final ffi.Pointer<ffi.Uint8> _outPtr;
  late final Uint8List _outView;
  late final ffi.Pointer<ffi.Size> _bw;
  late final ffi.Pointer<ffi.Int32> _more;

  // Lazily-allocated session-owned input scratch for [feedBytes].
  RsyncBuffer? _inputScratch;

  bool _ended = false;
  bool _disposed = false;

  // Subclasses dispatch the actual native call.
  void _feedNative(ffi.Pointer<ffi.Uint8> inputPtr, int inputLen);
  void _endNative();
  void _freeNative();

  /// Feeds [n] bytes from the start of [input] into the session, dispatching
  /// any output chunks to [onChunk].
  ///
  /// [input] must have capacity >= [n]. Internally drains any output produced
  /// (one or more callback invocations) before returning.
  void feed(RsyncBuffer input, int n, RsyncOnChunk onChunk) {
    _checkOpen();
    if (n < 0 || n > input.capacity) {
      throw ArgumentError.value(n, 'n', '0..${input.capacity}');
    }
    _feedNative(input.ptr, n);
    _emit(onChunk);
    while (_more.value != 0) {
      _feedNative(input.ptr, 0);
      _emit(onChunk);
    }
  }

  /// Convenience: feeds a Dart-managed [bytes] chunk by copying into a
  /// session-owned C-heap scratch buffer.
  ///
  /// Slightly slower than [feed] (one Dart→C copy per call) but avoids forcing
  /// the caller to manage an [RsyncBuffer]. The internal scratch grows as
  /// needed and is freed when the session is closed.
  void feedBytes(Uint8List bytes, RsyncOnChunk onChunk) {
    _checkOpen();
    if (bytes.isEmpty) {
      // Pure drain.
      _feedNative(_orInputScratch().ptr, 0);
      _emit(onChunk);
      while (_more.value != 0) {
        _feedNative(_orInputScratch().ptr, 0);
        _emit(onChunk);
      }
      return;
    }
    final scratch = _ensureInputCapacity(bytes.length);
    scratch.view.setRange(0, bytes.length, bytes);
    feed(scratch, bytes.length, onChunk);
  }

  /// Finalises the session and drains any remaining output through [onChunk].
  /// After this returns the session is closed; calling [feed], [feedBytes],
  /// or [end] again throws.
  void end(RsyncOnChunk onChunk) {
    _checkOpen();
    _ended = true;
    try {
      do {
        _endNative();
        _emit(onChunk);
      } while (_more.value != 0);
    } finally {
      _disposeScratch();
    }
  }

  /// Abandons the session without finalising. Idempotent. Use on the error
  /// path when [end] has not been called.
  void close() {
    if (_disposed) return;
    if (!_ended) {
      _ended = true;
      try {
        _freeNative();
      } finally {
        _disposeScratch();
      }
    } else {
      _disposeScratch();
    }
  }

  void _emit(RsyncOnChunk onChunk) {
    final n = _bw.value;
    if (n > 0) onChunk(Uint8List.sublistView(_outView, 0, n));
  }

  RsyncBuffer _orInputScratch() =>
      _inputScratch ??= RsyncBuffer(1); // 1-byte placeholder for pure drain

  RsyncBuffer _ensureInputCapacity(int needed) {
    final current = _inputScratch;
    if (current != null && current.capacity >= needed) return current;
    current?.dispose();
    return _inputScratch = RsyncBuffer(needed);
  }

  void _disposeScratch() {
    if (_disposed) return;
    _disposed = true;
    calloc.free(_outPtr);
    calloc.free(_bw);
    calloc.free(_more);
    _inputScratch?.dispose();
    _inputScratch = null;
  }

  void _checkOpen() {
    if (_disposed || _ended) {
      throw StateError('session is closed');
    }
  }
}

// ─── SignatureSession ────────────────────────────────────────────────────────

/// Streaming signature generation with zero-copy output.
///
/// ```dart
/// final session = SignatureSession();
/// final input = RsyncBuffer(64 * 1024);
/// final out = File(sigPath).openSync(mode: FileMode.write);
/// try {
///   final src = File(srcPath).openSync();
///   try {
///     int n;
///     while ((n = src.readIntoSync(input.view)) > 0) {
///       session.feed(input, n, out.writeFromSync);
///     }
///     session.end(out.writeFromSync);
///   } finally {
///     src.closeSync();
///   }
/// } finally {
///   out.closeSync();
///   input.dispose();
///   session.close();
/// }
/// ```
final class SignatureSession extends _IntoSession {
  /// Creates a new session.  [outputCapacity] sizes the internal C-heap
  /// output buffer (chunks larger than this are split across multiple
  /// callback invocations).
  factory SignatureSession({
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = b.librsyncBlake2,
    int outputCapacity = defaultOutputCapacity,
  }) {
    final handle = b.signatureNewHandle(blockLen, strongLen, sigType);
    if (handle == 0) {
      throw const b.LibrsyncException('failed to create signature session');
    }
    return SignatureSession._(handle, outputCapacity);
  }

  SignatureSession._(this._handle, int outputCapacity)
      : super(outputCapacity: outputCapacity);

  final int _handle;

  @override
  void _feedNative(ffi.Pointer<ffi.Uint8> inputPtr, int inputLen) {
    b.signatureFeedIntoHandle(
        _handle, inputPtr, inputLen, _outPtr, _outCap, _bw, _more);
  }

  @override
  void _endNative() {
    b.signatureEndIntoHandle(_handle, _outPtr, _outCap, _bw, _more);
  }

  @override
  void _freeNative() => b.signatureFreeHandle(_handle);
}

// ─── DeltaSession ────────────────────────────────────────────────────────────

/// Streaming delta generation against a parsed [SigHandle].
///
/// ```dart
/// final sig = SigHandle.fromBytes(File(sigPath).readAsBytesSync());
/// try {
///   final session = DeltaSession(sig);
///   final input = RsyncBuffer(64 * 1024);
///   try {
///     final newFile = File(newPath).openSync();
///     final out = File(deltaPath).openSync(mode: FileMode.write);
///     try {
///       int n;
///       while ((n = newFile.readIntoSync(input.view)) > 0) {
///         session.feed(input, n, out.writeFromSync);
///       }
///       session.end(out.writeFromSync);
///     } finally {
///       newFile.closeSync();
///       out.closeSync();
///     }
///   } finally {
///     input.dispose();
///     session.close();
///   }
/// } finally {
///   sig.close();
/// }
/// ```
final class DeltaSession extends _IntoSession {
  /// Creates a new delta session backed by [sig].  The signature handle
  /// remains valid and may back further sessions.
  factory DeltaSession(
    SigHandle sig, {
    int outputCapacity = defaultOutputCapacity,
  }) {
    final handle = b.deltaNewHandle(sig.internalHandle);
    if (handle == 0) {
      throw const b.LibrsyncException('failed to create delta session');
    }
    return DeltaSession._(handle, outputCapacity);
  }

  DeltaSession._(this._handle, int outputCapacity)
      : super(outputCapacity: outputCapacity);

  final int _handle;

  @override
  void _feedNative(ffi.Pointer<ffi.Uint8> inputPtr, int inputLen) {
    b.deltaFeedIntoHandle(
        _handle, inputPtr, inputLen, _outPtr, _outCap, _bw, _more);
  }

  @override
  void _endNative() {
    b.deltaEndIntoHandle(_handle, _outPtr, _outCap, _bw, _more);
  }

  @override
  void _freeNative() => b.deltaFreeHandle(_handle);
}

// ─── PatchSession ────────────────────────────────────────────────────────────

/// Streaming patch application.  The base file is accessed via random reads,
/// either from a file path (Go opens with thread-safe `pread`/overlapped I/O)
/// or from an in-memory copy.
///
/// ```dart
/// final session = PatchSession.fromPath(basisPath);
/// final input = RsyncBuffer(64 * 1024);
/// try {
///   final delta = File(deltaPath).openSync();
///   final out = File(patchedPath).openSync(mode: FileMode.write);
///   try {
///     int n;
///     while ((n = delta.readIntoSync(input.view)) > 0) {
///       session.feed(input, n, out.writeFromSync);
///     }
///     session.end(out.writeFromSync);
///   } finally {
///     delta.closeSync();
///     out.closeSync();
///   }
/// } finally {
///   input.dispose();
///   session.close();
/// }
/// ```
final class PatchSession extends _IntoSession {
  /// Backed by the file at [path].  Go opens the file and reads on demand;
  /// the file is never fully loaded into memory.  Suitable for arbitrarily
  /// large basis files.
  factory PatchSession.fromPath(
    String path, {
    int outputCapacity = defaultOutputCapacity,
  }) {
    final handle = b.patchNewPathHandle(path);
    if (handle == 0) {
      throw b.LibrsyncException('failed to open base file: $path');
    }
    return PatchSession._(handle, outputCapacity);
  }

  /// Backed by an in-memory copy of [base].  The bytes are copied to a
  /// thread-safe C-heap buffer at construction.
  factory PatchSession.fromBytes(
    Uint8List base, {
    int outputCapacity = defaultOutputCapacity,
  }) {
    final dataPtr = b.copyToNative(base);
    // Ownership transfers to Go on success; caller must free on failure only.
    final handle = b.patchNewBufHandle(dataPtr, base.length);
    if (handle == 0) {
      calloc.free(dataPtr);
      throw const b.LibrsyncException('failed to create patch session');
    }
    return PatchSession._(handle, outputCapacity);
  }

  PatchSession._(this._handle, int outputCapacity)
      : super(outputCapacity: outputCapacity);

  final int _handle;

  @override
  void _feedNative(ffi.Pointer<ffi.Uint8> inputPtr, int inputLen) {
    b.patchFeedIntoHandle(
        _handle, inputPtr, inputLen, _outPtr, _outCap, _bw, _more);
  }

  @override
  void _endNative() {
    b.patchEndIntoHandle(_handle, _outPtr, _outCap, _bw, _more);
  }

  @override
  void _freeNative() => b.patchFreeHandle(_handle);
}

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
  int _handle;
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

  /// Finalises the session and returns any remaining output.
  ///
  /// Invalidates the handle — do not call [close] after [end].
  Uint8List end() {
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
  int _handle;
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

  /// Finalises the session and flushes all remaining output.
  ///
  /// Invalidates the handle — do not call [close] after [end].
  Uint8List end() {
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
/// The patch algorithm requires random access to the base file.  Provide a
/// [readAt] callback that reads bytes from an arbitrary offset.  For file-backed
/// base data, use [PatchStream.fromFile].
///
/// Feed all delta chunks via [feed] (buffered internally), then call [end] to
/// apply the delta and receive all reconstructed bytes at once.
///
/// **Lifetime requirement:** the [readAt] callback (and its backing resources)
/// must remain alive from construction until [end] or [close] returns.
///
/// ```dart
/// final stream = PatchStream.fromFile(raf);
/// try {
///   for (final chunk in deltaChunks) {
///     stream.feed(chunk); // buffers; no output yet
///   }
///   final result = stream.end(); // applies delta, returns reconstructed file
///   sink.add(result);
/// } catch (_) {
///   stream.close();
///   rethrow;
/// }
/// ```
final class PatchStream {
  int _handle;
  bool _ended = false;

  // Owned resources — kept alive for the session lifetime.
  final ffi.NativeCallable<b.ReadAtFn> _callable;
  final ffi.Pointer<b.RsReadSeekerT> _seekerPtr;

  PatchStream._(this._handle, this._callable, this._seekerPtr);

  /// Creates a [PatchStream] backed by [readAt].
  ///
  /// [readAt] receives `(offset, buffer)` and must fill [buffer] starting at
  /// [offset] in the base file.  It returns the number of bytes read; returning
  /// fewer bytes than `buffer.length` is only permitted at EOF.
  factory PatchStream(int Function(int offset, Uint8List buffer) readAt) {
    final seekerPtr = calloc<b.RsReadSeekerT>();

    final callable = ffi.NativeCallable<b.ReadAtFn>.isolateLocal(
      (ffi.Pointer<ffi.Void> _, int offset, ffi.Pointer<ffi.Uint8> buf,
          int len, ffi.Pointer<ffi.Size> bytesRead) {
        try {
          final view = buf.asTypedList(len);
          final n = readAt(offset, view);
          bytesRead.value = n;
          return 0; // LIBRSYNC_OK
        } catch (_) {
          bytesRead.value = 0;
          return -1; // LIBRSYNC_ERR_ARGS
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

  /// Creates a [PatchStream] that reads the base file from [file].
  ///
  /// [file] must remain open for the session lifetime.
  factory PatchStream.fromFile(RandomAccessFile file) {
    return PatchStream((offset, buffer) {
      file.setPositionSync(offset);
      return file.readIntoSync(buffer);
    });
  }

  /// Creates a [PatchStream] from an in-memory base.
  ///
  /// Use for small files only.  For large files, prefer [PatchStream.fromFile].
  factory PatchStream.fromBytes(Uint8List base) {
    return PatchStream((offset, buffer) {
      final available = base.length - offset;
      if (available <= 0) return 0;
      final n = buffer.length < available ? buffer.length : available;
      buffer.setRange(0, n, base, offset);
      return n;
    });
  }

  /// Buffers a [delta] chunk. All reconstructed output is returned by [end].
  void feed(Uint8List delta) {
    final ptr = b.copyToNative(delta);
    try {
      b.patchFeedHandle(_handle, ptr, delta.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Finalises the session and returns any remaining reconstructed bytes.
  ///
  /// Invalidates the handle — do not call [close] after [end].
  Uint8List end() {
    _ended = true;
    try {
      return b.patchEndHandle(_handle);
    } finally {
      _teardownCallable();
    }
  }

  /// Abandons the session without finalising.
  ///
  /// Use only on the error path when [end] has not been called.
  void close() {
    if (_ended) return;
    _ended = true;
    b.patchFreeHandle(_handle);
    _teardownCallable();
  }

  void _teardownCallable() {
    _callable.close();
    calloc.free(_seekerPtr);
  }
}

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ─── C type for the patch read_at callback ────────────────────────────────────

/// Native type: int32_t (*read_at)(void* userdata, int64_t offset,
///                                  uint8_t* buf, size_t len, size_t* bytes_read)
typedef ReadAtFn = ffi.Int32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Int64,
  ffi.Pointer<ffi.Uint8>,
  ffi.Size,
  ffi.Pointer<ffi.Size>,
);

// ─── C struct ─────────────────────────────────────────────────────────────────

/// Mirrors rs_read_seeker_t in the C ABI.
final class RsReadSeekerT extends ffi.Struct {
  external ffi.Pointer<ffi.Void> userdata;
  // ignore: non_constant_identifier_names — mirrors snake_case C ABI field name.
  external ffi.Pointer<ffi.NativeFunction<ReadAtFn>> read_at;
}

// ─── Native function signatures ───────────────────────────────────────────────

typedef _NativeFree = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _NativeStrerror = ffi.Pointer<ffi.Char> Function(ffi.Int32);

// Batch API
typedef _NativeBatchSig = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>, ffi.Size,
  ffi.Uint32, ffi.Uint32, ffi.Uint32,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);
typedef _NativeBatchDelta = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>, ffi.Size,
  ffi.Pointer<ffi.Uint8>, ffi.Size,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);
typedef _NativeBatchPatch = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>, ffi.Size,
  ffi.Pointer<ffi.Uint8>, ffi.Size,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);

// Parsed signature handle
typedef _NativeSigParse = ffi.IntPtr Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _NativeSigFree = ffi.Void Function(ffi.IntPtr);

// Streaming signature
typedef _NativeSigNew = ffi.IntPtr Function(ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef _NativeSigFeed = ffi.Int32 Function(
  ffi.IntPtr,
  ffi.Pointer<ffi.Uint8>, ffi.Size,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);
typedef _NativeSigEnd = ffi.Int32 Function(
  ffi.IntPtr,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);
typedef _NativeSigStreamFree = ffi.Void Function(ffi.IntPtr);

// Streaming delta
typedef _NativeDeltaNew = ffi.IntPtr Function(ffi.IntPtr);
typedef _NativeDeltaFeed = ffi.Int32 Function(
  ffi.IntPtr,
  ffi.Pointer<ffi.Uint8>, ffi.Size,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);
typedef _NativeDeltaEnd = ffi.Int32 Function(
  ffi.IntPtr,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);
typedef _NativeDeltaFree = ffi.Void Function(ffi.IntPtr);

// Streaming patch
typedef _NativePatchNew = ffi.IntPtr Function(ffi.Pointer<RsReadSeekerT>);
typedef _NativePatchNewBuf = ffi.IntPtr Function(
    ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _NativePatchNewPath = ffi.IntPtr Function(ffi.Pointer<ffi.Char>);
typedef _NativePatchFeed = ffi.Int32 Function(
  ffi.IntPtr,
  ffi.Pointer<ffi.Uint8>, ffi.Size,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);
typedef _NativePatchEnd = ffi.Int32 Function(
  ffi.IntPtr,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
);
typedef _NativePatchFree = ffi.Void Function(ffi.IntPtr);

// ─── Library loader ───────────────────────────────────────────────────────────

ffi.DynamicLibrary _openLib() {
  const name = 'flutter_librsync';
  if (Platform.isIOS) return ffi.DynamicLibrary.process();
  if (Platform.isMacOS) return ffi.DynamicLibrary.open('lib$name.dylib');
  if (Platform.isAndroid || Platform.isLinux) {
    return ffi.DynamicLibrary.open('lib$name.so');
  }
  if (Platform.isWindows) return ffi.DynamicLibrary.open('$name.dll');
  throw UnsupportedError(
      'flutter_librsync: unsupported platform ${Platform.operatingSystem}');
}

final _lib = _openLib();

// ─── Bound functions ──────────────────────────────────────────────────────────

final _free = _lib
    .lookup<ffi.NativeFunction<_NativeFree>>('librsync_free')
    .asFunction<void Function(ffi.Pointer<ffi.Void>)>();

final _strerror = _lib
    .lookup<ffi.NativeFunction<_NativeStrerror>>('librsync_strerror')
    .asFunction<ffi.Pointer<ffi.Char> Function(int)>();

// Batch
final _batchSignature = _lib
    .lookup<ffi.NativeFunction<_NativeBatchSig>>('librsync_signature')
    .asFunction<
        int Function(
          ffi.Pointer<ffi.Uint8>, int,
          int, int, int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

final _batchDelta = _lib
    .lookup<ffi.NativeFunction<_NativeBatchDelta>>('librsync_delta')
    .asFunction<
        int Function(
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

final _batchPatch = _lib
    .lookup<ffi.NativeFunction<_NativeBatchPatch>>('librsync_patch')
    .asFunction<
        int Function(
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

// Parsed sig handle
final _sigParse = _lib
    .lookup<ffi.NativeFunction<_NativeSigParse>>('librsync_sig_parse')
    .asFunction<int Function(ffi.Pointer<ffi.Uint8>, int)>();

final _sigFree = _lib
    .lookup<ffi.NativeFunction<_NativeSigFree>>('librsync_sig_free')
    .asFunction<void Function(int)>();

// Streaming signature
final _signatureNew = _lib
    .lookup<ffi.NativeFunction<_NativeSigNew>>('librsync_signature_new')
    .asFunction<int Function(int, int, int)>();

final _signatureFeed = _lib
    .lookup<ffi.NativeFunction<_NativeSigFeed>>('librsync_signature_feed')
    .asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

final _signatureEnd = _lib
    .lookup<ffi.NativeFunction<_NativeSigEnd>>('librsync_signature_end')
    .asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

final _signatureStreamFree = _lib
    .lookup<ffi.NativeFunction<_NativeSigStreamFree>>('librsync_signature_free')
    .asFunction<void Function(int)>();

// Streaming delta
final _deltaNew = _lib
    .lookup<ffi.NativeFunction<_NativeDeltaNew>>('librsync_delta_new')
    .asFunction<int Function(int)>();

final _deltaFeed = _lib
    .lookup<ffi.NativeFunction<_NativeDeltaFeed>>('librsync_delta_feed')
    .asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

final _deltaEnd = _lib
    .lookup<ffi.NativeFunction<_NativeDeltaEnd>>('librsync_delta_end')
    .asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

final _deltaFree = _lib
    .lookup<ffi.NativeFunction<_NativeDeltaFree>>('librsync_delta_free')
    .asFunction<void Function(int)>();

// Streaming patch
final _patchNew = _lib
    .lookup<ffi.NativeFunction<_NativePatchNew>>('librsync_patch_new')
    .asFunction<int Function(ffi.Pointer<RsReadSeekerT>)>();

final _patchNewBuf = _lib
    .lookup<ffi.NativeFunction<_NativePatchNewBuf>>('librsync_patch_new_buf')
    .asFunction<int Function(ffi.Pointer<ffi.Uint8>, int)>();

final _patchNewPath = _lib
    .lookup<ffi.NativeFunction<_NativePatchNewPath>>('librsync_patch_new_path')
    .asFunction<int Function(ffi.Pointer<ffi.Char>)>();

final _patchFeed = _lib
    .lookup<ffi.NativeFunction<_NativePatchFeed>>('librsync_patch_feed')
    .asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

final _patchEnd = _lib
    .lookup<ffi.NativeFunction<_NativePatchEnd>>('librsync_patch_end')
    .asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>,
        )>();

final _patchFree = _lib
    .lookup<ffi.NativeFunction<_NativePatchFree>>('librsync_patch_free')
    .asFunction<void Function(int)>();

// ─── Internal helpers ─────────────────────────────────────────────────────────

/// Throws [LibrsyncException] if [code] is non-zero.
void checkReturn(int code) {
  if (code == 0) return;
  final msgPtr = _strerror(code);
  final String msg;
  if (msgPtr == ffi.nullptr) {
    msg = 'error code $code';
  } else {
    msg = msgPtr.cast<Utf8>().toDartString();
    _free(msgPtr.cast<ffi.Void>());
  }
  throw LibrsyncException(msg);
}

/// Copies native output buffer to a Dart [Uint8List] and frees the native
/// buffer. Returns an empty list if [outLenPtr] is zero.
Uint8List collectOutput(
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outPtrPtr,
  ffi.Pointer<ffi.Size> outLenPtr,
) {
  final len = outLenPtr.value;
  if (len == 0) return Uint8List(0);
  final ptr = outPtrPtr.value;
  final result = Uint8List.fromList(ptr.asTypedList(len));
  _free(ptr.cast<ffi.Void>());
  return result;
}

/// Copies [bytes] into a calloc-allocated native buffer.
///
/// Ownership of the returned pointer belongs to the caller.  Most callers
/// free it in a `finally` block; [patchNewBufHandle] transfers ownership to Go
/// on success and must NOT free it afterward.
ffi.Pointer<ffi.Uint8> copyToNative(Uint8List bytes) {
  final ptr = calloc<ffi.Uint8>(bytes.isEmpty ? 1 : bytes.length);
  if (bytes.isNotEmpty) ptr.asTypedList(bytes.length).setAll(0, bytes);
  return ptr;
}

// ─── Public batch helpers ─────────────────────────────────────────────────────

/// Runs [librsync_signature] (batch).
Uint8List nativeBatchSignature(
  Uint8List input, {
  required int blockLen,
  required int strongLen,
  required int sigType,
}) {
  final inPtr = copyToNative(input);
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(
      _batchSignature(inPtr, input.length, blockLen, strongLen, sigType,
          outPtrPtr, outLenPtr),
    );
    return collectOutput(outPtrPtr, outLenPtr);
  } finally {
    calloc.free(inPtr);
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

Uint8List nativeBatchDelta(Uint8List sig, Uint8List newData) {
  final sigPtr = copyToNative(sig);
  final dataPtr = copyToNative(newData);
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(
      _batchDelta(sigPtr, sig.length, dataPtr, newData.length,
          outPtrPtr, outLenPtr),
    );
    return collectOutput(outPtrPtr, outLenPtr);
  } finally {
    calloc.free(sigPtr);
    calloc.free(dataPtr);
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

Uint8List nativeBatchPatch(Uint8List base, Uint8List delta) {
  final basePtr = copyToNative(base);
  final deltaPtr = copyToNative(delta);
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(
      _batchPatch(basePtr, base.length, deltaPtr, delta.length,
          outPtrPtr, outLenPtr),
    );
    return collectOutput(outPtrPtr, outLenPtr);
  } finally {
    calloc.free(basePtr);
    calloc.free(deltaPtr);
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

// ─── Re-exports for streaming.dart ───────────────────────────────────────────

// Streaming signature
int signatureNewHandle(int blockLen, int strongLen, int sigType) =>
    _signatureNew(blockLen, strongLen, sigType);

// Note: signatureFeed/signatureEnd never write to outPtr on error (Go returns
// early before calling setOutput on failure), so no defensive catch is needed.
Uint8List signatureFeedHandle(
  int handle,
  ffi.Pointer<ffi.Uint8> inputPtr,
  int inputLen,
) {
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(_signatureFeed(handle, inputPtr, inputLen, outPtrPtr, outLenPtr));
    return collectOutput(outPtrPtr, outLenPtr);
  } finally {
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

Uint8List signatureEndHandle(int handle) {
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(_signatureEnd(handle, outPtrPtr, outLenPtr));
    return collectOutput(outPtrPtr, outLenPtr);
  } finally {
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

void signatureFreeHandle(int handle) => _signatureStreamFree(handle);

// Streaming delta
int sigParseHandle(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    _sigParse(ptr, len);

void sigFreeHandle(int handle) => _sigFree(handle);

int deltaNewHandle(int sigHandle) => _deltaNew(sigHandle);

// Note: deltaFeed/deltaEnd never write to outPtr on error (same invariant as
// signature functions above), so no defensive catch is needed.
Uint8List deltaFeedHandle(
  int handle,
  ffi.Pointer<ffi.Uint8> inputPtr,
  int inputLen,
) {
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(_deltaFeed(handle, inputPtr, inputLen, outPtrPtr, outLenPtr));
    return collectOutput(outPtrPtr, outLenPtr);
  } finally {
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

Uint8List deltaEndHandle(int handle) {
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(_deltaEnd(handle, outPtrPtr, outLenPtr));
    return collectOutput(outPtrPtr, outLenPtr);
  } finally {
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

void deltaFreeHandle(int handle) => _deltaFree(handle);

// Streaming patch
int patchNewHandle(ffi.Pointer<RsReadSeekerT> base) => _patchNew(base);

/// Creates a patch session backed by a C-heap copy of [dataPtr].
/// Go takes ownership of [dataPtr] on success (handle > 0) and will free it.
/// On failure (handle == 0) the caller must free [dataPtr].
int patchNewBufHandle(ffi.Pointer<ffi.Uint8> dataPtr, int dataLen) =>
    _patchNewBuf(dataPtr, dataLen);

/// Creates a patch session backed by [path] opened by Go.
/// Go opens the file, holds it for the session lifetime, and closes it on free/end.
/// Returns handle > 0 on success, 0 if the file cannot be opened.
int patchNewPathHandle(String path) {
  final pathPtr = path.toNativeUtf8();
  try {
    return _patchNewPath(pathPtr.cast());
  } finally {
    calloc.free(pathPtr);
  }
}

Uint8List patchFeedHandle(
  int handle,
  ffi.Pointer<ffi.Uint8> deltaPtr,
  int deltaLen,
) {
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(_patchFeed(handle, deltaPtr, deltaLen, outPtrPtr, outLenPtr));
    return collectOutput(outPtrPtr, outLenPtr);
  } catch (_) {
    // Go does not currently write to outPtr on error (setOutput is only called
    // on the success path), but this catch is retained defensively in case the
    // Go implementation changes.
    final outPtr = outPtrPtr.value;
    if (outPtr != ffi.nullptr) _free(outPtr.cast<ffi.Void>());
    rethrow;
  } finally {
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

Uint8List patchEndHandle(int handle) {
  final outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLenPtr = calloc<ffi.Size>();
  try {
    checkReturn(_patchEnd(handle, outPtrPtr, outLenPtr));
    return collectOutput(outPtrPtr, outLenPtr);
  } catch (_) {
    // Same rationale as patchFeedHandle.
    final outPtr = outPtrPtr.value;
    if (outPtr != ffi.nullptr) _free(outPtr.cast<ffi.Void>());
    rethrow;
  } finally {
    calloc.free(outPtrPtr);
    calloc.free(outLenPtr);
  }
}

void patchFreeHandle(int handle) => _patchFree(handle);

// ─── Constants ───────────────────────────────────────────────────────────────

/// BLAKE2 signature magic number (preferred).
const int librsyncBlake2 = 0x72730137;

/// MD4 signature magic number (deprecated legacy).
const int librsyncMd4 = 0x72730136;

// ─── Exception ────────────────────────────────────────────────────────────────

/// Thrown when a native librsync operation fails.
class LibrsyncException implements Exception {
  final String message;
  const LibrsyncException(this.message);

  @override
  String toString() => 'LibrsyncException: $message';
}

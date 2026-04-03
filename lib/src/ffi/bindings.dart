import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../interfaces.dart';

// ─── C type aliases ───────────────────────────────────────────────────────────

/// int64_t (*read)(void* ctx, uint8_t* buf, int64_t len)
typedef RsReadFn = ffi.Int64 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.Int64);

/// int64_t (*seek)(void* ctx, int64_t offset, int32_t whence)
typedef RsSeekFn = ffi.Int64 Function(
    ffi.Pointer<ffi.Void>, ffi.Int64, ffi.Int32);

/// int64_t (*write)(void* ctx, const uint8_t* buf, int64_t len)
typedef RsWriteFn = ffi.Int64 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.Int64);

// ─── C struct definitions ─────────────────────────────────────────────────────

/// Mirrors `rs_reader_t` in librsync.go (sequential reader, no seek).
final class RsReader extends ffi.Struct {
  external ffi.Pointer<ffi.NativeFunction<RsReadFn>> read;
  external ffi.Pointer<ffi.Void> ctx;
}

/// Mirrors `rs_read_seeker_t` in librsync.go (seekable reader).
final class RsReadSeeker extends ffi.Struct {
  external ffi.Pointer<ffi.NativeFunction<RsReadFn>> read;
  external ffi.Pointer<ffi.NativeFunction<RsSeekFn>> seek;
  external ffi.Pointer<ffi.Void> ctx;
}

/// Mirrors `rs_writer_t` in librsync.go.
final class RsWriter extends ffi.Struct {
  external ffi.Pointer<ffi.NativeFunction<RsWriteFn>> write;
  external ffi.Pointer<ffi.Void> ctx;
}

// ─── Native function types ────────────────────────────────────────────────────

typedef _NativeSignature = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<RsReader>,
    ffi.Pointer<RsWriter>,
    ffi.Uint32,
    ffi.Uint32,
    ffi.Uint32);

typedef _NativeDelta = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<RsReader>, ffi.Pointer<RsReader>, ffi.Pointer<RsWriter>);

typedef _NativePatch = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<RsReadSeeker>, ffi.Pointer<RsReader>, ffi.Pointer<RsWriter>);

typedef _NativeFreeString = ffi.Void Function(ffi.Pointer<ffi.Char>);

// ─── Library loader ───────────────────────────────────────────────────────────

ffi.DynamicLibrary _openLib() {
  const name = 'flutter_librsync';
  if (Platform.isIOS) {
    // iOS: statically linked into the process image.
    return ffi.DynamicLibrary.process();
  }
  if (Platform.isMacOS) {
    return ffi.DynamicLibrary.open('lib$name.dylib');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return ffi.DynamicLibrary.open('lib$name.so');
  }
  if (Platform.isWindows) {
    return ffi.DynamicLibrary.open('$name.dll');
  }
  throw UnsupportedError('flutter_librsync: unsupported platform ${Platform.operatingSystem}');
}

final _lib = _openLib();

// ─── Bound native functions ───────────────────────────────────────────────────

final _signature = _lib
    .lookup<ffi.NativeFunction<_NativeSignature>>('librsync_signature')
    .asFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<RsReader>,
            ffi.Pointer<RsWriter>, int, int, int)>();

final _delta = _lib
    .lookup<ffi.NativeFunction<_NativeDelta>>('librsync_delta')
    .asFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<RsReader>,
            ffi.Pointer<RsReader>, ffi.Pointer<RsWriter>)>();

final _patch = _lib
    .lookup<ffi.NativeFunction<_NativePatch>>('librsync_patch')
    .asFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<RsReadSeeker>,
            ffi.Pointer<RsReader>, ffi.Pointer<RsWriter>)>();

final _freeString = _lib
    .lookup<ffi.NativeFunction<_NativeFreeString>>('librsync_free_string')
    .asFunction<void Function(ffi.Pointer<ffi.Char>)>();

// ─── Public binding helpers ───────────────────────────────────────────────────

String? _checkError(ffi.Pointer<ffi.Char> errPtr) {
  if (errPtr == ffi.nullptr) return null;
  final msg = errPtr.cast<Utf8>().toDartString();
  _freeString(errPtr);
  return msg;
}

/// Calls `librsync_signature` with Dart [ReadSeeker] / [Writer] objects.
///
/// Must be called on the isolate that owns [input] and [output].
void nativeSignature(
  ReadSeeker input,
  Writer output, {
  required int blockLen,
  required int strongLen,
  required int sigType,
}) {
  // Build NativeCallables from Dart closures. These are valid only while the
  // C call is in progress (Go is single-threaded within our CGO boundary).
  final readCallable = ffi.NativeCallable<RsReadFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, ffi.Pointer<ffi.Uint8> buf, int len) {
      return input.readInto(buf.asTypedList(len));
    },
    exceptionalReturn: -1,
  );

  final writeCallable = ffi.NativeCallable<RsWriteFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, ffi.Pointer<ffi.Uint8> buf, int len) {
      output.write(Uint8List.fromList(buf.asTypedList(len)));
      return len;
    },
    exceptionalReturn: -1,
  );

  final reader = calloc<RsReader>();
  final writer = calloc<RsWriter>();

  try {
    reader.ref.read = readCallable.nativeFunction;
    reader.ref.ctx = ffi.nullptr;
    writer.ref.write = writeCallable.nativeFunction;
    writer.ref.ctx = ffi.nullptr;

    final errPtr = _signature(reader, writer, blockLen, strongLen, sigType);
    final err = _checkError(errPtr);
    if (err != null) throw LibrsyncException(err);
  } finally {
    calloc.free(reader);
    calloc.free(writer);
    readCallable.close();
    writeCallable.close();
  }
}

/// Calls `librsync_delta` with Dart [ReadSeeker] / [Writer] objects.
void nativeDelta(
  ReadSeeker sigInput,
  ReadSeeker newData,
  Writer output,
) {
  final sigReadCallable = ffi.NativeCallable<RsReadFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, ffi.Pointer<ffi.Uint8> buf, int len) {
      return sigInput.readInto(buf.asTypedList(len));
    },
    exceptionalReturn: -1,
  );

  final dataReadCallable = ffi.NativeCallable<RsReadFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, ffi.Pointer<ffi.Uint8> buf, int len) {
      return newData.readInto(buf.asTypedList(len));
    },
    exceptionalReturn: -1,
  );

  final writeCallable = ffi.NativeCallable<RsWriteFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, ffi.Pointer<ffi.Uint8> buf, int len) {
      output.write(Uint8List.fromList(buf.asTypedList(len)));
      return len;
    },
    exceptionalReturn: -1,
  );

  final sigReader = calloc<RsReader>();
  final dataReader = calloc<RsReader>();
  final writer = calloc<RsWriter>();

  try {
    sigReader.ref.read = sigReadCallable.nativeFunction;
    sigReader.ref.ctx = ffi.nullptr;
    dataReader.ref.read = dataReadCallable.nativeFunction;
    dataReader.ref.ctx = ffi.nullptr;
    writer.ref.write = writeCallable.nativeFunction;
    writer.ref.ctx = ffi.nullptr;

    final errPtr = _delta(sigReader, dataReader, writer);
    final err = _checkError(errPtr);
    if (err != null) throw LibrsyncException(err);
  } finally {
    calloc.free(sigReader);
    calloc.free(dataReader);
    calloc.free(writer);
    sigReadCallable.close();
    dataReadCallable.close();
    writeCallable.close();
  }
}

/// Calls `librsync_patch` with Dart [ReadSeeker] / [Writer] objects.
void nativePatch(
  ReadSeeker base,
  ReadSeeker delta,
  Writer output,
) {
  final baseReadCallable = ffi.NativeCallable<RsReadFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, ffi.Pointer<ffi.Uint8> buf, int len) {
      return base.readInto(buf.asTypedList(len));
    },
    exceptionalReturn: -1,
  );

  final baseSeekCallable = ffi.NativeCallable<RsSeekFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, int offset, int whence) {
      return base.seek(offset, whence);
    },
    exceptionalReturn: -1,
  );

  final deltaReadCallable = ffi.NativeCallable<RsReadFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, ffi.Pointer<ffi.Uint8> buf, int len) {
      return delta.readInto(buf.asTypedList(len));
    },
    exceptionalReturn: -1,
  );

  final writeCallable = ffi.NativeCallable<RsWriteFn>.isolateLocal(
    (ffi.Pointer<ffi.Void> _, ffi.Pointer<ffi.Uint8> buf, int len) {
      output.write(Uint8List.fromList(buf.asTypedList(len)));
      return len;
    },
    exceptionalReturn: -1,
  );

  final baseRS = calloc<RsReadSeeker>();
  final deltaReader = calloc<RsReader>();
  final writer = calloc<RsWriter>();

  try {
    baseRS.ref.read = baseReadCallable.nativeFunction;
    baseRS.ref.seek = baseSeekCallable.nativeFunction;
    baseRS.ref.ctx = ffi.nullptr;
    deltaReader.ref.read = deltaReadCallable.nativeFunction;
    deltaReader.ref.ctx = ffi.nullptr;
    writer.ref.write = writeCallable.nativeFunction;
    writer.ref.ctx = ffi.nullptr;

    final errPtr = _patch(baseRS, deltaReader, writer);
    final err = _checkError(errPtr);
    if (err != null) throw LibrsyncException(err);
  } finally {
    calloc.free(baseRS);
    calloc.free(deltaReader);
    calloc.free(writer);
    baseReadCallable.close();
    baseSeekCallable.close();
    deltaReadCallable.close();
    writeCallable.close();
  }
}

// ─── Exception ────────────────────────────────────────────────────────────────

/// Thrown when a native librsync operation fails.
class LibrsyncException implements Exception {
  final String message;
  const LibrsyncException(this.message);

  @override
  String toString() => 'LibrsyncException: $message';
}

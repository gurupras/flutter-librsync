// Web implementation of Librsync.
//
// This file is selected by the conditional export in flutter_librsync.dart
// when `dart.library.js_interop` is available (i.e. Flutter Web builds).
//
// Operations run in the browser main thread via the librsync WASM module.
// The WASM module must be loaded before use – call [Librsync.initialize]
// (or await [Librsync.ensureInitialized]) once at app startup.

// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'interfaces.dart';

export 'interfaces.dart';
export 'implementations.dart';

/// The BLAKE2 signature magic number (preferred, default).
const int blake2SigMagic = 0x72730137;

/// The MD4 signature magic number (deprecated legacy format).
const int md4SigMagic = 0x72730136;

// ─── JS interop declarations ──────────────────────────────────────────────────

@JS('librsync')
external _JsLibrsync? get _jsLibrsync;

extension type _JsLibrsync._(JSObject _) implements JSObject {
  external _JsSignatureJob newSignature(int blockLen, int strongLen, int sigType);
  external _JsDeltaJob newDelta(JSUint8Array sigBytes, [int bufSize]);
  external _JsPatchJob newPatch(JSUint8Array baseBytes);
  @JS('BLAKE2_SIG_MAGIC')
  external int get blake2SigMagicJs;
  @JS('MD4_SIG_MAGIC')
  external int get md4SigMagicJs;
}

extension type _JsSignatureJob._(JSObject _) implements JSObject {
  external void write(JSUint8Array data);
  external JSUint8Array finish();
}

extension type _JsDeltaJob._(JSObject _) implements JSObject {
  external JSUint8Array? write(JSUint8Array data);
  external JSUint8Array finish();
}

extension type _JsPatchJob._(JSObject _) implements JSObject {
  external void write(JSUint8Array data);
  external JSUint8Array finish();
}

// ─── WASM initialisation ──────────────────────────────────────────────────────

Completer<void>? _initCompleter;

/// librsync operations for Flutter Web, backed by a WebAssembly module.
///
/// **Initialisation required:** The librsync WASM module must be loaded and
/// the Go WASM runtime must be bootstrapped before any operation is called.
/// Add the following to your app's `web/index.html` `<head>` section:
///
/// ```html
/// <script src="assets/packages/flutter_librsync/web/wasm_exec.js"></script>
/// <script>
///   const go = new Go();
///   WebAssembly.instantiateStreaming(
///     fetch('assets/packages/flutter_librsync/web/librsync.wasm'),
///     go.importObject,
///   ).then(r => go.run(r.instance));
/// </script>
/// ```
///
/// Then call `await Librsync.ensureInitialized()` before the first operation.
abstract final class Librsync {
  Librsync._();

  /// Waits until the WASM module exposes the `librsync` global.
  ///
  /// Polls every 50 ms for up to [timeout] (default 10 s).
  static Future<void> ensureInitialized({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<void>();

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_jsLibrsync != null) {
        _initCompleter!.complete();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _initCompleter!.completeError(
      TimeoutException(
        'librsync WASM module not loaded within ${timeout.inSeconds}s. '
        'Make sure wasm_exec.js and librsync.wasm are loaded in index.html.',
        timeout,
      ),
    );
  }

  // ── Bytes-to-bytes ─────────────────────────────────────────────────────────

  static Future<Uint8List> signatureBytes(
    Uint8List input, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) async {
    await ensureInitialized();
    final job = _jsLibrsync!.newSignature(blockLen, strongLen, sigType);
    job.write(input.toJS);
    return job.finish().toDart;
  }

  static Future<Uint8List> deltaBytes(
    Uint8List sigBytes,
    Uint8List newFileBytes,
  ) async {
    await ensureInitialized();
    final job = _jsLibrsync!.newDelta(sigBytes.toJS);
    job.write(newFileBytes.toJS);
    return job.finish().toDart;
  }

  static Future<Uint8List> patchBytes(
    Uint8List baseBytes,
    Uint8List deltaBytes,
  ) async {
    await ensureInitialized();
    final job = _jsLibrsync!.newPatch(baseBytes.toJS);
    job.write(deltaBytes.toJS);
    return job.finish().toDart;
  }

  // ── Streaming bytes ────────────────────────────────────────────────────────

  /// Returns a [WebSignatureStream] that accepts chunks via [write]
  /// and produces the full signature bytes on [finish].
  static WebSignatureStream beginSignature({
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) {
    final lib = _jsLibrsync;
    if (lib == null) throw StateError('Call Librsync.ensureInitialized() first.');
    return WebSignatureStream._(lib.newSignature(blockLen, strongLen, sigType));
  }

  static WebDeltaStream beginDelta(Uint8List sigBytes) {
    final lib = _jsLibrsync;
    if (lib == null) throw StateError('Call Librsync.ensureInitialized() first.');
    return WebDeltaStream._(lib.newDelta(sigBytes.toJS));
  }

  static WebPatchStream beginPatch(Uint8List baseBytes) {
    final lib = _jsLibrsync;
    if (lib == null) throw StateError('Call Librsync.ensureInitialized() first.');
    return WebPatchStream._(lib.newPatch(baseBytes.toJS));
  }

  // ── Low-level synchronous (mirrored from native for API parity) ───────────

  static void signatureSync(
    ReadSeeker input,
    Writer output, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) {
    final lib = _jsLibrsync;
    if (lib == null) throw StateError('Call Librsync.ensureInitialized() first.');
    final job = lib.newSignature(blockLen, strongLen, sigType);
    final buf = Uint8List(65536);
    while (true) {
      final n = input.readInto(buf);
      if (n == 0) break;
      job.write(buf.sublist(0, n).toJS);
    }
    output.write(job.finish().toDart);
  }

  static void deltaSync(ReadSeeker sigInput, ReadSeeker newData, Writer output) {
    final lib = _jsLibrsync;
    if (lib == null) throw StateError('Call Librsync.ensureInitialized() first.');
    final sigBuf = _drain(sigInput);
    final job = lib.newDelta(sigBuf.toJS);
    final buf = Uint8List(65536);
    while (true) {
      final n = newData.readInto(buf);
      if (n == 0) break;
      job.write(buf.sublist(0, n).toJS);
    }
    output.write(job.finish().toDart);
  }

  static void patchSync(
    ReadSeeker base,
    ReadSeeker deltaInput,
    Writer output,
  ) {
    final lib = _jsLibrsync;
    if (lib == null) throw StateError('Call Librsync.ensureInitialized() first.');
    final baseBuf = _drain(base);
    final job = lib.newPatch(baseBuf.toJS);
    final buf = Uint8List(65536);
    while (true) {
      final n = deltaInput.readInto(buf);
      if (n == 0) break;
      job.write(buf.sublist(0, n).toJS);
    }
    output.write(job.finish().toDart);
  }
}

// ─── Stream helpers ───────────────────────────────────────────────────────────

class WebSignatureStream {
  final _JsSignatureJob _job;
  WebSignatureStream._(this._job);

  void write(Uint8List chunk) => _job.write(chunk.toJS);
  Uint8List finish() => _job.finish().toDart;
}

class WebDeltaStream {
  final _JsDeltaJob _job;
  WebDeltaStream._(this._job);

  Uint8List? write(Uint8List chunk) => _job.write(chunk.toJS)?.toDart;
  Uint8List finish() => _job.finish().toDart;
}

class WebPatchStream {
  final _JsPatchJob _job;
  WebPatchStream._(this._job);

  void write(Uint8List chunk) => _job.write(chunk.toJS);
  Uint8List finish() => _job.finish().toDart;
}

// ─── Private helpers ──────────────────────────────────────────────────────────

Uint8List _drain(ReadSeeker rs) {
  final builder = BytesBuilder();
  final buf = Uint8List(65536);
  while (true) {
    final n = rs.readInto(buf);
    if (n == 0) break;
    builder.add(buf.sublist(0, n));
  }
  return builder.takeBytes();
}

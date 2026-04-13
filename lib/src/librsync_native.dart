import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'ffi/bindings.dart' as native_ffi;
import 'interfaces.dart';
import 'streaming.dart';

export 'interfaces.dart';
export 'implementations.dart';
export 'ffi/bindings.dart' show LibrsyncException;
export 'streaming.dart'
    show SigHandle, SignatureStream, DeltaStream, PatchStream, defaultChunkSize;

/// The BLAKE2 signature magic number (preferred, default).
const int blake2SigMagic = 0x72730137;

/// The MD4 signature magic number (deprecated legacy format).
const int md4SigMagic = 0x72730136;

/// librsync operations for native platforms (Android, iOS, macOS, Linux, Windows).
///
/// ## Async file operations
/// Use [signatureFile], [deltaFile], [patchFile] for large files.  Internally
/// these use the streaming API with [defaultChunkSize]-byte chunks and run on
/// a background isolate so the UI thread is never blocked.
///
/// ## Async bytes operations
/// Use [signatureBytes], [deltaBytes], [patchBytes] when data is already in
/// memory.  These call the batch API — the full content must fit in memory.
///
/// ## Streaming (low-level)
/// Use [beginSignature], [beginDelta], [beginPatch] for custom streaming loops.
/// These session objects are synchronous and are intended to be called from a
/// background isolate.
abstract final class Librsync {
  Librsync._();

  // ── Async file-to-file ────────────────────────────────────────────────────

  /// Generates an rsync signature for the file at [inputPath] and writes it
  /// to [outputPath].
  static Future<void> signatureFile(
    String inputPath,
    String outputPath, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) =>
      Isolate.run(() => _signatureFileSync(
            inputPath, outputPath,
            blockLen: blockLen, strongLen: strongLen, sigType: sigType,
          ));

  /// Generates a delta between [sigPath] (signature) and [newFilePath] and
  /// writes the result to [outputPath].
  static Future<void> deltaFile(
    String sigPath,
    String newFilePath,
    String outputPath,
  ) =>
      Isolate.run(() => _deltaFileSync(sigPath, newFilePath, outputPath));

  /// Applies [deltaPath] to [basePath] and writes the reconstructed file to
  /// [outputPath].
  static Future<void> patchFile(
    String basePath,
    String deltaPath,
    String outputPath,
  ) =>
      Isolate.run(() => _patchFileSync(basePath, deltaPath, outputPath));

  // ── Async bytes ───────────────────────────────────────────────────────────

  /// Generates a signature for [input] and returns the signature bytes.
  static Future<Uint8List> signatureBytes(
    Uint8List input, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) {
    final tInput = TransferableTypedData.fromList([input]);
    return Isolate.run(() => native_ffi.nativeBatchSignature(
          tInput.materialize().asUint8List(),
          blockLen: blockLen, strongLen: strongLen, sigType: sigType,
        ));
  }

  /// Computes a delta between [sigBytes] and [newFileBytes].
  static Future<Uint8List> deltaBytes(
    Uint8List sigBytes,
    Uint8List newFileBytes,
  ) {
    final tSig = TransferableTypedData.fromList([sigBytes]);
    final tNew = TransferableTypedData.fromList([newFileBytes]);
    return Isolate.run(() => native_ffi.nativeBatchDelta(
          tSig.materialize().asUint8List(),
          tNew.materialize().asUint8List(),
        ));
  }

  /// Applies [deltaBytes] to [baseBytes] and returns the reconstructed bytes.
  static Future<Uint8List> patchBytes(
    Uint8List baseBytes,
    Uint8List deltaBytes,
  ) {
    final tBase = TransferableTypedData.fromList([baseBytes]);
    final tDelta = TransferableTypedData.fromList([deltaBytes]);
    return Isolate.run(() => native_ffi.nativeBatchPatch(
          tBase.materialize().asUint8List(),
          tDelta.materialize().asUint8List(),
        ));
  }

  // ── Mixed ─────────────────────────────────────────────────────────────────

  /// Convenience: signature from a file, result returned as bytes.
  static Future<Uint8List> signatureFileToBytes(
    String inputPath, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) =>
      Isolate.run(() {
        final builder = BytesBuilder(copy: false);
        _runSignatureStream(
          inputPath,
          onChunk: builder.add,
          blockLen: blockLen,
          strongLen: strongLen,
          sigType: sigType,
        );
        return builder.takeBytes();
      });

  /// Convenience: delta from files, result returned as bytes.
  static Future<Uint8List> deltaFileToBytes(
    String sigPath,
    String newFilePath,
  ) =>
      Isolate.run(() {
        final builder = BytesBuilder(copy: false);
        _runDeltaStream(sigPath, newFilePath, onChunk: builder.add);
        return builder.takeBytes();
      });

  // ── Low-level streaming (use inside your own isolate) ─────────────────────

  /// Returns a [SignatureStream] session.
  ///
  /// Feed chunks via [SignatureStream.feed] and finalise with [SignatureStream.end].
  /// The first [SignatureStream.feed] call always returns the 12-byte header.
  /// Subsequent calls may return empty output until enough data accumulates for
  /// a complete block — see [SignatureStream.feed] for details.
  /// **Do not call from the UI isolate.**
  static SignatureStream beginSignature({
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) =>
      SignatureStream(blockLen: blockLen, strongLen: strongLen, sigType: sigType);

  /// Returns a [DeltaStream] session backed by [sig].
  ///
  /// **Do not call from the UI isolate.**
  static DeltaStream beginDelta(SigHandle sig) => DeltaStream(sig);

  /// Returns a [PatchStream] session.
  ///
  /// [readAt] receives `(offset, buffer)` and must fill [buffer] from the base
  /// file at [offset].  Feed delta chunks via [PatchStream.feed]; call
  /// [PatchStream.end] to apply the delta and receive all reconstructed bytes.
  /// **Do not call from the UI isolate.**
  static PatchStream beginPatch(
          int Function(int offset, Uint8List buffer) readAt) =>
      PatchStream(readAt);

  // ── Legacy sync (ReadSeeker / Writer) ─────────────────────────────────────

  /// Generates a signature synchronously.  **Do not call from the UI isolate.**
  static void signatureSync(
    ReadSeeker input,
    Writer output, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) {
    final stream = SignatureStream(
        blockLen: blockLen, strongLen: strongLen, sigType: sigType);
    final buf = Uint8List(defaultChunkSize);
    try {
      while (true) {
        final n = input.readInto(buf);
        if (n == 0) break;
        final out = stream.feed(buf.sublist(0, n));
        if (out.isNotEmpty) output.write(out);
      }
      final tail = stream.end();
      if (tail.isNotEmpty) output.write(tail);
    } catch (_) {
      stream.close();
      rethrow;
    }
  }

  /// Generates a delta synchronously.  **Do not call from the UI isolate.**
  static void deltaSync(
    ReadSeeker sigInput,
    ReadSeeker newData,
    Writer output,
  ) {
    // Read signature fully — it's compact (~1% of file size).
    final sigBytes = _drainReadSeeker(sigInput);
    final sig = SigHandle.fromBytes(sigBytes);
    final stream = DeltaStream(sig);
    final buf = Uint8List(defaultChunkSize);
    try {
      while (true) {
        final n = newData.readInto(buf);
        if (n == 0) break;
        final out = stream.feed(buf.sublist(0, n));
        if (out.isNotEmpty) output.write(out);
      }
      final tail = stream.end();
      if (tail.isNotEmpty) output.write(tail);
    } catch (_) {
      stream.close();
      rethrow;
    } finally {
      sig.close();
    }
  }

  /// Applies a delta synchronously.  **Do not call from the UI isolate.**
  ///
  /// [base] must support [ReadSeeker.seek] since patch requires random access.
  static void patchSync(
    ReadSeeker base,
    ReadSeeker deltaInput,
    Writer output,
  ) {
    final stream = PatchStream((offset, buffer) {
      base.seek(offset, SeekOrigin.start);
      return base.readInto(buffer);
    });
    final buf = Uint8List(defaultChunkSize);
    try {
      while (true) {
        final n = deltaInput.readInto(buf);
        if (n == 0) break;
        stream.feed(buf.sublist(0, n));
      }
      final result = stream.end();
      if (result.isNotEmpty) output.write(result);
    } catch (_) {
      stream.close();
      rethrow;
    }
  }
}

// ─── File streaming helpers (run inside Isolate.run) ─────────────────────────

void _signatureFileSync(
  String inputPath,
  String outputPath, {
  required int blockLen,
  required int strongLen,
  required int sigType,
}) {
  final out = File(outputPath).openSync(mode: FileMode.write);
  try {
    _runSignatureStream(
      inputPath,
      onChunk: out.writeFromSync,
      blockLen: blockLen,
      strongLen: strongLen,
      sigType: sigType,
    );
  } finally {
    out.closeSync();
  }
}

void _runSignatureStream(
  String inputPath, {
  required void Function(Uint8List) onChunk,
  required int blockLen,
  required int strongLen,
  required int sigType,
}) {
  final stream =
      SignatureStream(blockLen: blockLen, strongLen: strongLen, sigType: sigType);
  final input = File(inputPath).openSync();
  final buf = Uint8List(defaultChunkSize);
  try {
    while (true) {
      final n = input.readIntoSync(buf);
      if (n == 0) break;
      final out = stream.feed(buf.sublist(0, n));
      if (out.isNotEmpty) onChunk(out);
    }
    final tail = stream.end();
    if (tail.isNotEmpty) onChunk(tail);
  } catch (_) {
    stream.close();
    rethrow;
  } finally {
    input.closeSync();
  }
}

void _deltaFileSync(
  String sigPath,
  String newFilePath,
  String outputPath,
) {
  final out = File(outputPath).openSync(mode: FileMode.write);
  try {
    _runDeltaStream(sigPath, newFilePath, onChunk: out.writeFromSync);
  } finally {
    out.closeSync();
  }
}

void _runDeltaStream(
  String sigPath,
  String newFilePath, {
  required void Function(Uint8List) onChunk,
}) {
  // Signature is compact — read it all at once.
  final sigBytes = File(sigPath).readAsBytesSync();
  final sig = SigHandle.fromBytes(sigBytes);
  final stream = DeltaStream(sig);
  final input = File(newFilePath).openSync();
  final buf = Uint8List(defaultChunkSize);
  try {
    while (true) {
      final n = input.readIntoSync(buf);
      if (n == 0) break;
      final out = stream.feed(buf.sublist(0, n));
      if (out.isNotEmpty) onChunk(out);
    }
    final tail = stream.end();
    if (tail.isNotEmpty) onChunk(tail);
  } catch (_) {
    stream.close();
    rethrow;
  } finally {
    input.closeSync();
    sig.close();
  }
}

void _patchFileSync(
  String basePath,
  String deltaPath,
  String outputPath,
) {
  final baseFile = File(basePath).openSync();
  final out = File(outputPath).openSync(mode: FileMode.write);
  final stream = PatchStream.fromFile(baseFile);
  final input = File(deltaPath).openSync();
  final buf = Uint8List(defaultChunkSize);
  try {
    while (true) {
      final n = input.readIntoSync(buf);
      if (n == 0) break;
      stream.feed(buf.sublist(0, n));
    }
    final result = stream.end();
    if (result.isNotEmpty) out.writeFromSync(result);
  } catch (_) {
    stream.close();
    rethrow;
  } finally {
    input.closeSync();
    baseFile.closeSync();
    out.closeSync();
  }
}

// ─── Private helpers ──────────────────────────────────────────────────────────

Uint8List _drainReadSeeker(ReadSeeker rs) {
  final builder = BytesBuilder();
  final buf = Uint8List(defaultChunkSize);
  while (true) {
    final n = rs.readInto(buf);
    if (n == 0) break;
    builder.add(buf.sublist(0, n));
  }
  return builder.takeBytes();
}

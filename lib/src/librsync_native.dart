import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'ffi/bindings.dart' as native_ffi;
import 'implementations.dart';
import 'interfaces.dart';
import 'streaming.dart';

export 'interfaces.dart';
export 'implementations.dart';
export 'ffi/bindings.dart' show LibrsyncException;
export 'streaming.dart'
    show SigHandle, SignatureStream, DeltaStream, PatchStream, defaultChunkSize;
export 'sessions.dart'
    show
        RsyncBuffer,
        RsyncOnChunk,
        SignatureSession,
        DeltaSession,
        PatchSession,
        defaultOutputCapacity;
export 'streams.dart' show RsyncStreamOps, RsyncStreams, defaultStreamChunkSize;

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

  /// Returns a [PatchStream] session backed by an in-memory [base].
  ///
  /// The base data is copied to C-heap at construction so the Go patch
  /// goroutine can access it from any OS thread.
  /// **Do not call from the UI isolate.**
  static PatchStream beginPatch(Uint8List base) =>
      PatchStream.fromBytes(base);

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
    final DeltaStream stream;
    try {
      stream = DeltaStream(sig);
    } catch (_) {
      sig.close();
      rethrow;
    }
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
  static void patchSync(
    ReadSeeker base,
    ReadSeeker deltaInput,
    Writer output,
  ) {
    final baseBytes = _drainReadSeeker(base);
    final deltaBytes = _drainReadSeeker(deltaInput);
    final result = native_ffi.nativeBatchPatch(baseBytes, deltaBytes);
    if (result.isNotEmpty) output.write(result);
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
  try {
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
    } finally {
      input.closeSync();
    }
  } catch (_) {
    stream.close();
    rethrow;
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
  try {
    final stream = DeltaStream(sig);
    try {
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
      } finally {
        input.closeSync();
      }
    } catch (_) {
      stream.close();
      rethrow;
    }
  } finally {
    sig.close();
  }
}

void _patchFileSync(
  String basePath,
  String deltaPath,
  String outputPath,
) {
  final baseBytes = File(basePath).readAsBytesSync();
  final stream = PatchStream.fromBytes(baseBytes);
  try {
    final deltaFile = File(deltaPath).openSync();
    try {
      final out = File(outputPath).openSync(mode: FileMode.write);
      final buf = Uint8List(defaultChunkSize);
      try {
        while (true) {
          final n = deltaFile.readIntoSync(buf);
          if (n == 0) break;
          final chunk = stream.feed(buf.sublist(0, n));
          if (chunk.isNotEmpty) out.writeFromSync(chunk);
        }
        final tail = stream.end();
        if (tail.isNotEmpty) out.writeFromSync(tail);
      } finally {
        out.closeSync();
      }
    } finally {
      deltaFile.closeSync();
    }
  } catch (_) {
    stream.close();
    rethrow;
  }
}

// ─── Private helpers ──────────────────────────────────────────────────────────

Uint8List _drainReadSeeker(ReadSeeker rs) {
  if (rs is BytesReadSeeker) return rs.remainingBytes;
  final builder = BytesBuilder(copy: false);
  final buf = Uint8List(defaultChunkSize);
  while (true) {
    final n = rs.readInto(buf);
    if (n == 0) break;
    builder.add(buf.sublist(0, n));
  }
  return builder.takeBytes();
}

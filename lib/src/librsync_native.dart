import 'dart:isolate';
import 'dart:typed_data';

import 'ffi/bindings.dart' as native_ffi;
import 'implementations.dart';
import 'interfaces.dart';

export 'interfaces.dart';
export 'implementations.dart';
export 'ffi/bindings.dart' show LibrsyncException;

/// The BLAKE2 signature magic number (preferred, default).
const int blake2SigMagic = 0x72730137;

/// The MD4 signature magic number (deprecated legacy format).
const int md4SigMagic = 0x72730136;

/// librsync operations for native platforms (Android, iOS, macOS, Linux, Windows).
///
/// All `async` methods run the computation on a background isolate so the UI
/// thread is never blocked.  Only [FileReadSeeker], [BytesReadSeeker],
/// [FileWriter], and [BytesWriter] are supported with async methods; for
/// custom [ReadSeeker] / [Writer] implementations use the `*Sync` variants
/// inside your own isolate.
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
      Isolate.run(() {
        final i = FileReadSeeker(inputPath);
        final o = FileWriter(outputPath);
        try {
          native_ffi.nativeSignature(i, o,
              blockLen: blockLen, strongLen: strongLen, sigType: sigType);
        } finally {
          i.close();
          o.close();
        }
      });

  /// Generates a delta between [sigPath] (signature) and [newFilePath],
  /// writing the result to [outputPath].
  static Future<void> deltaFile(
    String sigPath,
    String newFilePath,
    String outputPath,
  ) =>
      Isolate.run(() {
        final sig = FileReadSeeker(sigPath);
        final nd = FileReadSeeker(newFilePath);
        final out = FileWriter(outputPath);
        try {
          native_ffi.nativeDelta(sig, nd, out);
        } finally {
          sig.close();
          nd.close();
          out.close();
        }
      });

  /// Applies [deltaPath] to [basePath] and writes the reconstructed file to
  /// [outputPath].
  static Future<void> patchFile(
    String basePath,
    String deltaPath,
    String outputPath,
  ) =>
      Isolate.run(() {
        final base = FileReadSeeker(basePath);
        final delta = FileReadSeeker(deltaPath);
        final out = FileWriter(outputPath);
        try {
          native_ffi.nativePatch(base, delta, out);
        } finally {
          base.close();
          delta.close();
          out.close();
        }
      });

  // ── Async bytes-to-bytes ──────────────────────────────────────────────────

  /// Generates a signature for [input] and returns the signature bytes.
  static Future<Uint8List> signatureBytes(
    Uint8List input, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) =>
      Isolate.run(() {
        final i = BytesReadSeeker(input);
        final o = BytesWriter();
        native_ffi.nativeSignature(i, o,
            blockLen: blockLen, strongLen: strongLen, sigType: sigType);
        return o.takeBytes();
      });

  /// Computes a delta between [sigBytes] and [newFileBytes], returning the
  /// delta bytes.
  static Future<Uint8List> deltaBytes(
    Uint8List sigBytes,
    Uint8List newFileBytes,
  ) =>
      Isolate.run(() {
        final sig = BytesReadSeeker(sigBytes);
        final nd = BytesReadSeeker(newFileBytes);
        final out = BytesWriter();
        native_ffi.nativeDelta(sig, nd, out);
        return out.takeBytes();
      });

  /// Applies [deltaBytes] to [baseBytes] and returns the reconstructed bytes.
  static Future<Uint8List> patchBytes(
    Uint8List baseBytes,
    Uint8List deltaBytes,
  ) =>
      Isolate.run(() {
        final base = BytesReadSeeker(baseBytes);
        final delta = BytesReadSeeker(deltaBytes);
        final out = BytesWriter();
        native_ffi.nativePatch(base, delta, out);
        return out.takeBytes();
      });

  // ── Mixed (file base + bytes delta, etc.) ─────────────────────────────────

  /// Convenience: signature from a file, result returned as bytes.
  static Future<Uint8List> signatureFileToBytes(
    String inputPath, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) =>
      Isolate.run(() {
        final i = FileReadSeeker(inputPath);
        final o = BytesWriter();
        try {
          native_ffi.nativeSignature(i, o,
              blockLen: blockLen, strongLen: strongLen, sigType: sigType);
          return o.takeBytes();
        } finally {
          i.close();
        }
      });

  /// Convenience: delta from files, result returned as bytes.
  static Future<Uint8List> deltaFileToBytes(
    String sigPath,
    String newFilePath,
  ) =>
      Isolate.run(() {
        final sig = FileReadSeeker(sigPath);
        final nd = FileReadSeeker(newFilePath);
        final out = BytesWriter();
        try {
          native_ffi.nativeDelta(sig, nd, out);
          return out.takeBytes();
        } finally {
          sig.close();
          nd.close();
        }
      });

  // ── Low-level synchronous (use inside your own isolate) ───────────────────

  /// Generates a signature synchronously.
  ///
  /// Accepts any [ReadSeeker] / [Writer] implementation.
  /// **Do not call from the UI isolate** – this blocks for the duration of
  /// the operation.
  static void signatureSync(
    ReadSeeker input,
    Writer output, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = blake2SigMagic,
  }) =>
      native_ffi.nativeSignature(input, output,
          blockLen: blockLen, strongLen: strongLen, sigType: sigType);

  /// Generates a delta synchronously.  **Do not call from the UI isolate.**
  static void deltaSync(
    ReadSeeker sigInput,
    ReadSeeker newData,
    Writer output,
  ) =>
      native_ffi.nativeDelta(sigInput, newData, output);

  /// Applies a delta synchronously.  **Do not call from the UI isolate.**
  static void patchSync(
    ReadSeeker base,
    ReadSeeker deltaInput,
    Writer output,
  ) =>
      native_ffi.nativePatch(base, deltaInput, output);
}

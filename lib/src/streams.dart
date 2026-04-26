import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'ffi/bindings.dart' show librsyncBlake2;
import 'sessions.dart';

/// Stream-based wrappers for signature, delta, and patch operations.
///
/// These are convenience extensions over the Tier-3 [SignatureSession],
/// [DeltaSession], and [PatchSession] classes.  Each chunk emitted by the
/// returned [Stream] is a fresh [Uint8List] (the underlying session output
/// buffer is reused, so chunks are copied at the stream boundary).
///
/// **Threading:** these wrappers run synchronously on the calling isolate.
/// For UI-thread safety, run inside `Isolate.run` or use the
/// [Librsync.signatureFile] / [Librsync.deltaFile] / [Librsync.patchFile]
/// async file helpers, which already isolate-hop.
extension RsyncStreamOps on Stream<Uint8List> {
  /// Generates an rsync signature, emitting signature bytes as they are
  /// produced.  Drains the source stream and finalises the session before
  /// the returned stream completes.
  Stream<Uint8List> rsyncSignature({
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = librsyncBlake2,
    int outputCapacity = defaultOutputCapacity,
  }) async* {
    final session = SignatureSession(
      blockLen: blockLen,
      strongLen: strongLen,
      sigType: sigType,
      outputCapacity: outputCapacity,
    );
    try {
      final pending = <Uint8List>[];
      void collect(Uint8List chunk) =>
          pending.add(Uint8List.fromList(chunk));

      await for (final chunk in this) {
        session.feedBytes(chunk, collect);
        for (final out in pending) {
          yield out;
        }
        pending.clear();
      }
      session.end(collect);
      for (final out in pending) {
        yield out;
      }
    } finally {
      session.close();
    }
  }

  /// Computes a delta against [sig], emitting delta bytes as they are
  /// produced.  [sig] remains valid after the returned stream completes.
  Stream<Uint8List> rsyncDelta(
    SigHandle sig, {
    int outputCapacity = defaultOutputCapacity,
  }) async* {
    final session = DeltaSession(sig, outputCapacity: outputCapacity);
    try {
      final pending = <Uint8List>[];
      void collect(Uint8List chunk) =>
          pending.add(Uint8List.fromList(chunk));

      await for (final chunk in this) {
        session.feedBytes(chunk, collect);
        for (final out in pending) {
          yield out;
        }
        pending.clear();
      }
      session.end(collect);
      for (final out in pending) {
        yield out;
      }
    } finally {
      session.close();
    }
  }

  /// Applies a delta stream to a basis (provided by [PatchSession.fromPath]
  /// or [PatchSession.fromBytes]) and emits reconstructed bytes.  Takes
  /// ownership of [session] — closes it when the returned stream completes.
  Stream<Uint8List> rsyncPatch(
    PatchSession session,
  ) async* {
    try {
      final pending = <Uint8List>[];
      void collect(Uint8List chunk) =>
          pending.add(Uint8List.fromList(chunk));

      await for (final chunk in this) {
        session.feedBytes(chunk, collect);
        for (final out in pending) {
          yield out;
        }
        pending.clear();
      }
      session.end(collect);
      for (final out in pending) {
        yield out;
      }
    } finally {
      session.close();
    }
  }
}

// ─── File convenience ────────────────────────────────────────────────────────

/// Default chunk size for the file-stream convenience helpers below.
const int defaultStreamChunkSize = 256 * 1024;

/// Stream-based file helpers backing the Tier-2 API.
abstract final class RsyncStreams {
  RsyncStreams._();

  /// Reads [file] in [chunkSize]-byte chunks and emits its rsync signature.
  static Stream<Uint8List> signatureFile(
    File file, {
    int blockLen = 2048,
    int strongLen = 32,
    int sigType = librsyncBlake2,
    int chunkSize = defaultStreamChunkSize,
    int outputCapacity = defaultOutputCapacity,
  }) =>
      _readFile(file, chunkSize).rsyncSignature(
        blockLen: blockLen,
        strongLen: strongLen,
        sigType: sigType,
        outputCapacity: outputCapacity,
      );

  /// Reads [newFile] in [chunkSize]-byte chunks and emits the delta against
  /// [sig].  [sig] remains valid after the stream completes.
  static Stream<Uint8List> deltaFile(
    SigHandle sig,
    File newFile, {
    int chunkSize = defaultStreamChunkSize,
    int outputCapacity = defaultOutputCapacity,
  }) =>
      _readFile(newFile, chunkSize)
          .rsyncDelta(sig, outputCapacity: outputCapacity);

  /// Reads [deltaFile] in [chunkSize]-byte chunks and emits patched bytes
  /// against [session]'s basis.  Takes ownership of [session].
  static Stream<Uint8List> patchFile(
    PatchSession session,
    File deltaFile, {
    int chunkSize = defaultStreamChunkSize,
  }) =>
      _readFile(deltaFile, chunkSize).rsyncPatch(session);
}

/// Yields chunks of [chunkSize] read synchronously from [file].
///
/// Uses synchronous I/O (so the underlying FFI calls always pair with fresh
/// data) wrapped inside an async generator that yields control between
/// chunks. For very large files on the UI isolate, prefer reading from
/// [File.openRead] (truly async) and piping through the extension methods.
Stream<Uint8List> _readFile(File file, int chunkSize) async* {
  final raf = file.openSync();
  final buf = Uint8List(chunkSize);
  try {
    int n;
    while ((n = raf.readIntoSync(buf)) > 0) {
      yield Uint8List.sublistView(buf, 0, n).sublist(0);
    }
  } finally {
    raf.closeSync();
  }
}

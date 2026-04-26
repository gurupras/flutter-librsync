// Integration tests for the Tier-3 (sessions) and Tier-2 (Stream) APIs.
// Run with: flutter test integration_test/sessions_test.dart -d linux
//
// These exercise the new feedInto-backed RsyncBuffer/Session/Stream surface
// added by the API redesign.  They round-trip data through each session and
// compare the result against the batch API for correctness.

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_librsync/flutter_librsync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

Uint8List _randomBytes(int size, int seed) {
  final rng = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

Uint8List _changeTail(Uint8List basis, int seed) {
  final tail = basis.length ~/ 10;
  final head = basis.length - tail;
  final out = Uint8List(basis.length);
  out.setRange(0, head, basis);
  final rng = Random(seed);
  for (var i = head; i < basis.length; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// Drives a session by reading [source] in [chunkSize] chunks via an
/// [RsyncBuffer]. Returns the concatenated output as a Dart [Uint8List].
Uint8List _drainSignature(SignatureSession session, Uint8List source, int chunkSize) {
  final buf = RsyncBuffer(chunkSize);
  final out = BytesBuilder(copy: false);
  try {
    var off = 0;
    while (off < source.length) {
      final n = min(chunkSize, source.length - off);
      buf.view.setRange(0, n, source, off);
      session.feed(buf, n, (chunk) => out.add(Uint8List.fromList(chunk)));
      off += n;
    }
    session.end((chunk) => out.add(Uint8List.fromList(chunk)));
    return out.takeBytes();
  } finally {
    buf.dispose();
  }
}

Uint8List _drainDelta(DeltaSession session, Uint8List source, int chunkSize) {
  final buf = RsyncBuffer(chunkSize);
  final out = BytesBuilder(copy: false);
  try {
    var off = 0;
    while (off < source.length) {
      final n = min(chunkSize, source.length - off);
      buf.view.setRange(0, n, source, off);
      session.feed(buf, n, (chunk) => out.add(Uint8List.fromList(chunk)));
      off += n;
    }
    session.end((chunk) => out.add(Uint8List.fromList(chunk)));
    return out.takeBytes();
  } finally {
    buf.dispose();
  }
}

Uint8List _drainPatch(PatchSession session, Uint8List delta, int chunkSize) {
  final buf = RsyncBuffer(chunkSize);
  final out = BytesBuilder(copy: false);
  try {
    var off = 0;
    while (off < delta.length) {
      final n = min(chunkSize, delta.length - off);
      buf.view.setRange(0, n, delta, off);
      session.feed(buf, n, (chunk) => out.add(Uint8List.fromList(chunk)));
      off += n;
    }
    session.end((chunk) => out.add(Uint8List.fromList(chunk)));
    return out.takeBytes();
  } finally {
    buf.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('SignatureSession', () {
    test('round-trips a single small input', () async {
      final basis = _randomBytes(8 * 1024, 1);
      final ref = await Librsync.signatureBytes(basis);
      final session = SignatureSession();
      final got = _drainSignature(session, basis, 1024);
      expect(got, equals(ref));
    });

    test('matches batch signature across various chunk and outCap sizes',
        () async {
      final basis = _randomBytes(64 * 1024, 2);
      final ref = await Librsync.signatureBytes(basis);
      for (final chunk in [16, 256, 4096, 64 * 1024]) {
        for (final outCap in [16, 256, 4096, 1 << 20]) {
          final session = SignatureSession(outputCapacity: outCap);
          final got = _drainSignature(session, basis, chunk);
          expect(got, equals(ref),
              reason: 'chunk=$chunk outCap=$outCap');
        }
      }
    });

    test('feedBytes path matches batch signature', () async {
      final basis = _randomBytes(16 * 1024, 3);
      final ref = await Librsync.signatureBytes(basis);
      final session = SignatureSession();
      final out = BytesBuilder(copy: false);
      try {
        const chunk = 2048;
        for (var off = 0; off < basis.length; off += chunk) {
          final end = min(off + chunk, basis.length);
          session.feedBytes(
            Uint8List.sublistView(basis, off, end),
            (c) => out.add(Uint8List.fromList(c)),
          );
        }
        session.end((c) => out.add(Uint8List.fromList(c)));
      } finally {
        session.close();
      }
      expect(out.takeBytes(), equals(ref));
    });

    test('close before end is idempotent and frees state', () {
      final session = SignatureSession();
      session.close();
      session.close();
      expect(() => session.feedBytes(Uint8List(0), (_) {}),
          throwsStateError);
    });
  });

  group('DeltaSession', () {
    test('round-trips a small change', () async {
      final basis = _randomBytes(8 * 1024, 4);
      final modified = _changeTail(basis, 5);
      final sigBytes = await Librsync.signatureBytes(basis);
      final ref = await Librsync.deltaBytes(sigBytes, modified);
      final sig = SigHandle.fromBytes(sigBytes);
      try {
        final session = DeltaSession(sig);
        final got = _drainDelta(session, modified, 1024);
        expect(got, equals(ref));
      } finally {
        sig.close();
      }
    });

    test('SigHandle is reusable across sessions', () async {
      final basis = _randomBytes(4 * 1024, 6);
      final modified = _changeTail(basis, 7);
      final sigBytes = await Librsync.signatureBytes(basis);
      final sig = SigHandle.fromBytes(sigBytes);
      try {
        final ref = await Librsync.deltaBytes(sigBytes, modified);
        for (var i = 0; i < 3; i++) {
          final got = _drainDelta(DeltaSession(sig), modified, 512);
          expect(got, equals(ref), reason: 'iteration $i');
        }
      } finally {
        sig.close();
      }
    });
  });

  group('PatchSession', () {
    test('fromBytes round-trip reconstructs the new file', () async {
      final basis = _randomBytes(8 * 1024, 8);
      final modified = _changeTail(basis, 9);
      final sigBytes = await Librsync.signatureBytes(basis);
      final delta = await Librsync.deltaBytes(sigBytes, modified);
      final session = PatchSession.fromBytes(basis);
      final got = _drainPatch(session, delta, 1024);
      expect(got, equals(modified));
    });

    test('fromPath round-trip reconstructs the new file', () async {
      final tmp = await Directory.systemTemp.createTemp('librsync_patch_test');
      try {
        final basis = _randomBytes(16 * 1024, 10);
        final modified = _changeTail(basis, 11);
        final basisPath = p.join(tmp.path, 'basis.bin');
        await File(basisPath).writeAsBytes(basis);
        final sigBytes = await Librsync.signatureBytes(basis);
        final delta = await Librsync.deltaBytes(sigBytes, modified);
        final session = PatchSession.fromPath(basisPath);
        final got = _drainPatch(session, delta, 2048);
        expect(got, equals(modified));
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('fromPath throws on missing file', () {
      expect(
        () => PatchSession.fromPath('/nonexistent/file/path.bin'),
        throwsA(isA<LibrsyncException>()),
      );
    });
  });

  group('Stream API (Tier 2)', () {
    test('rsyncSignature on Stream<Uint8List> matches batch', () async {
      final basis = _randomBytes(32 * 1024, 12);
      final ref = await Librsync.signatureBytes(basis);

      Stream<Uint8List> chunks() async* {
        const cs = 4096;
        for (var off = 0; off < basis.length; off += cs) {
          final end = min(off + cs, basis.length);
          yield Uint8List.sublistView(basis, off, end);
        }
      }

      final out = BytesBuilder(copy: false);
      await for (final chunk in chunks().rsyncSignature()) {
        out.add(chunk);
      }
      expect(out.takeBytes(), equals(ref));
    });

    test('rsyncDelta + rsyncPatch round-trips the source', () async {
      final basis = _randomBytes(32 * 1024, 13);
      final modified = _changeTail(basis, 14);
      final sigBytes = await Librsync.signatureBytes(basis);
      final sig = SigHandle.fromBytes(sigBytes);
      try {
        Stream<Uint8List> newChunks() async* {
          const cs = 4096;
          for (var off = 0; off < modified.length; off += cs) {
            final end = min(off + cs, modified.length);
            yield Uint8List.sublistView(modified, off, end);
          }
        }

        final deltaOut = BytesBuilder(copy: false);
        await for (final chunk in newChunks().rsyncDelta(sig)) {
          deltaOut.add(chunk);
        }
        final delta = deltaOut.takeBytes();

        Stream<Uint8List> deltaChunks() async* {
          const cs = 4096;
          for (var off = 0; off < delta.length; off += cs) {
            final end = min(off + cs, delta.length);
            yield Uint8List.sublistView(delta, off, end);
          }
        }

        final patched = BytesBuilder(copy: false);
        await for (final chunk
            in deltaChunks().rsyncPatch(PatchSession.fromBytes(basis))) {
          patched.add(chunk);
        }
        expect(patched.takeBytes(), equals(modified));
      } finally {
        sig.close();
      }
    });

    test('RsyncStreams.signatureFile produces a usable signature', () async {
      final tmp = await Directory.systemTemp.createTemp('librsync_streams');
      try {
        final basis = _randomBytes(16 * 1024, 15);
        final basisPath = p.join(tmp.path, 'basis.bin');
        await File(basisPath).writeAsBytes(basis);
        final ref = await Librsync.signatureBytes(basis);

        final out = BytesBuilder(copy: false);
        await for (final chunk
            in RsyncStreams.signatureFile(File(basisPath), chunkSize: 4096)) {
          out.add(chunk);
        }
        expect(out.takeBytes(), equals(ref));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

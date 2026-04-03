// Integration tests – require the native library to be built and loaded.
// Run with: flutter test integration_test/librsync_test.dart -d linux

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_librsync/flutter_librsync.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ── Helper ─────────────────────────────────────────────────────────────────

  Uint8List makeData(int size, int fill) =>
      Uint8List(size)..fillRange(0, size, fill);

  bool equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String tmpPath(String name) =>
      '${Directory.systemTemp.path}/librsync_test_$name';

  // ── Bytes API ──────────────────────────────────────────────────────────────

  group('bytes round-trip', () {
    test('identical files produce empty-ish delta', () async {
      final data = makeData(16384, 0xAA);
      final sig = await Librsync.signatureBytes(data);
      expect(sig, isNotEmpty);

      final delta = await Librsync.deltaBytes(sig, data);
      expect(delta, isNotEmpty);

      final out = await Librsync.patchBytes(data, delta);
      expect(equal(data, out), isTrue);
    });

    test('single-byte change', () async {
      final basis = makeData(4096, 0x00);
      final modified = Uint8List.fromList(basis)..[2048] = 0xFF;

      final sig   = await Librsync.signatureBytes(basis);
      final delta = await Librsync.deltaBytes(sig, modified);
      final out   = await Librsync.patchBytes(basis, delta);

      expect(equal(modified, out), isTrue);
    });

    test('completely different data', () async {
      final basis    = makeData(8192, 0x00);
      final modified = makeData(8192, 0xFF);

      final sig   = await Librsync.signatureBytes(basis);
      final delta = await Librsync.deltaBytes(sig, modified);
      final out   = await Librsync.patchBytes(basis, delta);

      expect(equal(modified, out), isTrue);
    });

    test('modified file is larger than basis', () async {
      final basis    = makeData(4096, 0xAB);
      final modified = Uint8List(8192)..setAll(0, basis)..fillRange(4096, 8192, 0xCD);

      final sig   = await Librsync.signatureBytes(basis);
      final delta = await Librsync.deltaBytes(sig, modified);
      final out   = await Librsync.patchBytes(basis, delta);

      expect(equal(modified, out), isTrue);
    });

    test('modified file is smaller than basis', () async {
      final basis    = makeData(8192, 0x55);
      final modified = basis.sublist(0, 4096);

      final sig   = await Librsync.signatureBytes(basis);
      final delta = await Librsync.deltaBytes(sig, modified);
      final out   = await Librsync.patchBytes(basis, delta);

      expect(equal(modified, out), isTrue);
    });
  });

  // ── File API ───────────────────────────────────────────────────────────────

  group('file round-trip', () {
    test('signatureFile + deltaFile + patchFile', () async {
      final basis    = makeData(32768, 0x11);
      final modified = Uint8List.fromList(basis)..[16000] = 0x99;

      final basisPath    = tmpPath('basis.bin');
      final modifiedPath = tmpPath('modified.bin');
      final sigPath      = tmpPath('basis.sig');
      final deltaPath    = tmpPath('changes.delta');
      final outPath      = tmpPath('reconstructed.bin');

      File(basisPath).writeAsBytesSync(basis);
      File(modifiedPath).writeAsBytesSync(modified);

      await Librsync.signatureFile(basisPath, sigPath);
      await Librsync.deltaFile(sigPath, modifiedPath, deltaPath);
      await Librsync.patchFile(basisPath, deltaPath, outPath);

      final out = File(outPath).readAsBytesSync();
      expect(equal(modified, out), isTrue);

      // Cleanup
      for (final p in [basisPath, modifiedPath, sigPath, deltaPath, outPath]) {
        File(p).deleteSync();
      }
    });

    test('signatureFileToBytes', () async {
      final data = makeData(4096, 0xBB);
      final path = tmpPath('sig_test.bin');
      File(path).writeAsBytesSync(data);

      final sig = await Librsync.signatureFileToBytes(path);
      expect(sig, isNotEmpty);

      File(path).deleteSync();
    });
  });

  // ── Sync API ───────────────────────────────────────────────────────────────

  group('sync API', () {
    test('signatureSync + deltaSync + patchSync', () async {
      final basis    = makeData(2048, 0x77);
      final modified = Uint8List.fromList(basis)..[100] = 0x01;

      final Uint8List sigBytes, deltaBytes, outBytes;

      // signatureSync
      final sigWriter = BytesWriter();
      Librsync.signatureSync(BytesReadSeeker(basis), sigWriter);
      sigBytes = sigWriter.takeBytes();
      expect(sigBytes, isNotEmpty);

      // deltaSync
      final deltaWriter = BytesWriter();
      Librsync.deltaSync(
        BytesReadSeeker(sigBytes),
        BytesReadSeeker(modified),
        deltaWriter,
      );
      deltaBytes = deltaWriter.takeBytes();
      expect(deltaBytes, isNotEmpty);

      // patchSync
      final outWriter = BytesWriter();
      Librsync.patchSync(
        BytesReadSeeker(basis),
        BytesReadSeeker(deltaBytes),
        outWriter,
      );
      outBytes = outWriter.takeBytes();

      expect(equal(modified, outBytes), isTrue);
    });
  });
}

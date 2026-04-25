// Integration tests for the low-level streaming API.
// Run with: flutter test integration_test/streaming_test.dart -d linux

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:flutter_librsync/flutter_librsync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Uint8List makeData(int size, [int fill = 0xAA]) =>
      Uint8List(size)..fillRange(0, size, fill);

  Uint8List runSignatureStream(SignatureStream stream, Uint8List data,
      {int chunkSize = 4096}) {
    final builder = BytesBuilder(copy: false);
    for (var offset = 0; offset < data.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, data.length);
      final out = stream.feed(data.sublist(offset, end));
      if (out.isNotEmpty) builder.add(out);
    }
    final tail = stream.end();
    if (tail.isNotEmpty) builder.add(tail);
    return builder.takeBytes();
  }

  Uint8List runDeltaStream(DeltaStream stream, Uint8List data,
      {int chunkSize = 4096}) {
    final builder = BytesBuilder(copy: false);
    for (var offset = 0; offset < data.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, data.length);
      final out = stream.feed(data.sublist(offset, end));
      if (out.isNotEmpty) builder.add(out);
    }
    final tail = stream.end();
    if (tail.isNotEmpty) builder.add(tail);
    return builder.takeBytes();
  }

  group('SigHandle', () {
    late Uint8List validSig;

    setUpAll(() async {
      validSig = await Librsync.signatureBytes(makeData(4096));
    });

    test('fromBytes succeeds with a valid signature', () {
      final handle = SigHandle.fromBytes(validSig);
      handle.close();
    });

    test('fromBytes throws LibrsyncException for garbage bytes', () {
      expect(
        () => SigHandle.fromBytes(
            Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])),
        throwsA(isA<LibrsyncException>()),
      );
    });

    test('close is idempotent', () {
      final handle = SigHandle.fromBytes(validSig);
      handle.close();
      handle.close(); // must not crash
    });
  });

  group('SignatureStream', () {
    test('feed + end produces a non-empty signature', () {
      final stream = SignatureStream();
      final data = makeData(4096);
      final out = stream.feed(data);
      final tail = stream.end();
      expect(out.length + tail.length, greaterThan(0));
    });

    test('first feed always emits the 12-byte header immediately', () {
      final stream = SignatureStream();
      final first = stream.feed(makeData(1));
      expect(first.length, greaterThanOrEqualTo(12));
      stream.end();
    });

    test('empty-file input still produces the signature header', () {
      final stream = SignatureStream();
      final out = stream.feed(Uint8List(0));
      final tail = stream.end();
      expect(out.length + tail.length, greaterThanOrEqualTo(12));
    });

    test('chunked feeding produces the same bytes as a single feed', () {
      final data = makeData(16 * 1024);
      final sig1 = runSignatureStream(SignatureStream(), data,
          chunkSize: data.length);
      final sig2 = runSignatureStream(SignatureStream(), data, chunkSize: 1024);
      expect(sig1, equals(sig2));
    });

    test('output matches signatureBytes (batch API)', () async {
      final data = makeData(8 * 1024);
      final streamSig = runSignatureStream(SignatureStream(), data);
      final batchSig = await Librsync.signatureBytes(data);
      expect(streamSig, equals(batchSig));
    });

    test('custom blockLen / strongLen / sigType are accepted', () {
      final stream =
          SignatureStream(blockLen: 512, strongLen: 8, sigType: md4SigMagic);
      final out = runSignatureStream(stream, makeData(2048));
      expect(out, isNotEmpty);
    });

    test('close before end releases resources without crash', () {
      final stream = SignatureStream();
      stream.feed(makeData(128));
      stream.close();
    });

    test('large file (1 MB) round-trip via stream matches batch', () async {
      final data = Uint8List(1024 * 1024);
      for (var i = 0; i < data.length; i++) { data[i] = i & 0xFF; }

      final streamSig =
          runSignatureStream(SignatureStream(), data, chunkSize: 64 * 1024);
      final batchSig = await Librsync.signatureBytes(data);
      expect(streamSig, equals(batchSig));
    });
  });

  group('DeltaStream', () {
    late Uint8List basis;
    late SigHandle sigHandle;
    late Uint8List batchSigBytes;

    setUp(() async {
      basis = makeData(16 * 1024);
      batchSigBytes = await Librsync.signatureBytes(basis);
      sigHandle = SigHandle.fromBytes(batchSigBytes);
    });

    tearDown(() => sigHandle.close());

    test('produces a non-empty delta for modified data', () {
      final modified = Uint8List.fromList(basis)..[8000] = 0xFF;
      final delta = runDeltaStream(DeltaStream(sigHandle), modified);
      expect(delta, isNotEmpty);
    });

    test('produces a non-empty delta for identical data', () {
      // Even an identical file produces a valid (copy-literal) delta.
      final delta = runDeltaStream(DeltaStream(sigHandle), basis);
      expect(delta, isNotEmpty);
    });

    test('chunked feed produces the same delta as a single feed', () {
      final modified = Uint8List.fromList(basis)..[4000] = 0xBB;
      final delta1 =
          runDeltaStream(DeltaStream(sigHandle), modified, chunkSize: modified.length);
      final delta2 =
          runDeltaStream(DeltaStream(sigHandle), modified, chunkSize: 2048);
      expect(delta1, equals(delta2));
    });

    test('output matches deltaBytes (batch API)', () async {
      final modified = Uint8List.fromList(basis)..[1000] = 0x77;
      final streamDelta = runDeltaStream(DeltaStream(sigHandle), modified);
      final batchDelta = await Librsync.deltaBytes(batchSigBytes, modified);
      expect(streamDelta, equals(batchDelta));
    });

    test('SigHandle can be reused for multiple independent DeltaStreams', () {
      final modified1 = Uint8List.fromList(basis)..[100] = 0x11;
      final modified2 = Uint8List.fromList(basis)..[200] = 0x22;

      final delta1 = runDeltaStream(DeltaStream(sigHandle), modified1);
      final delta2 = runDeltaStream(DeltaStream(sigHandle), modified2);

      expect(delta1, isNotEmpty);
      expect(delta2, isNotEmpty);
      expect(delta1, isNot(equals(delta2)));
    });

    test('close before end releases resources without crash', () {
      final stream = DeltaStream(sigHandle);
      stream.feed(makeData(512));
      stream.close();
    });
  });

  group('feedPtr zero-copy', () {
    T withNativeBuffer<T>(Uint8List src, T Function(ffi.Pointer<ffi.Uint8>, int) fn) {
      final ptr = calloc<ffi.Uint8>(src.isEmpty ? 1 : src.length);
      try {
        if (src.isNotEmpty) ptr.asTypedList(src.length).setAll(0, src);
        return fn(ptr, src.length);
      } finally {
        calloc.free(ptr);
      }
    }

    test('SignatureStream.feedPtr produces same result as feed', () {
      final data = makeData(16 * 1024);

      // via feed (copies internally)
      final s1 = SignatureStream();
      final b1 = BytesBuilder(copy: false);
      for (var i = 0; i < data.length; i += 4096) {
        final chunk = data.sublist(i, (i + 4096).clamp(0, data.length));
        final out = s1.feed(chunk);
        if (out.isNotEmpty) b1.add(out);
      }
      b1.add(s1.end());
      final sigFeed = b1.takeBytes();

      // via feedPtr (zero-copy)
      final s2 = SignatureStream();
      final b2 = BytesBuilder(copy: false);
      for (var i = 0; i < data.length; i += 4096) {
        final chunk = data.sublist(i, (i + 4096).clamp(0, data.length));
        final out = withNativeBuffer(chunk, s2.feedPtr);
        if (out.isNotEmpty) b2.add(out);
      }
      b2.add(s2.end());
      final sigPtr = b2.takeBytes();

      expect(sigPtr, equals(sigFeed));
    });

    test('DeltaStream.feedPtr produces same result as feed', () async {
      final basis = makeData(16 * 1024);
      final modified = Uint8List.fromList(basis)..[8000] = 0xBB;

      final sigBytes = await Librsync.signatureBytes(basis);
      final sig = SigHandle.fromBytes(sigBytes);

      // via feed
      final d1 = DeltaStream(sig);
      final b1 = BytesBuilder(copy: false);
      for (var i = 0; i < modified.length; i += 4096) {
        final chunk = modified.sublist(i, (i + 4096).clamp(0, modified.length));
        final out = d1.feed(chunk);
        if (out.isNotEmpty) b1.add(out);
      }
      b1.add(d1.end());
      final deltaFeed = b1.takeBytes();

      // via feedPtr
      final d2 = DeltaStream(sig);
      final b2 = BytesBuilder(copy: false);
      for (var i = 0; i < modified.length; i += 4096) {
        final chunk = modified.sublist(i, (i + 4096).clamp(0, modified.length));
        final out = withNativeBuffer(chunk, d2.feedPtr);
        if (out.isNotEmpty) b2.add(out);
      }
      b2.add(d2.end());
      final deltaPtr = b2.takeBytes();

      sig.close();

      expect(deltaPtr, equals(deltaFeed));
    });

    test('feedPtr round-trip: sig + delta + patch reconstructs modified file',
        () async {
      final basis = makeData(32 * 1024);
      final modified = Uint8List.fromList(basis)
        ..[5000] = 0x11
        ..[20000] = 0x22;

      // signature via feedPtr
      final sigStream = SignatureStream();
      final sigBuilder = BytesBuilder(copy: false);
      for (var i = 0; i < basis.length; i += 4096) {
        final chunk = basis.sublist(i, (i + 4096).clamp(0, basis.length));
        final out = withNativeBuffer(chunk, sigStream.feedPtr);
        if (out.isNotEmpty) sigBuilder.add(out);
      }
      sigBuilder.add(sigStream.end());
      final sigBytes = sigBuilder.takeBytes();

      // delta via feedPtr
      final sig = SigHandle.fromBytes(sigBytes);
      final deltaStream = DeltaStream(sig);
      final deltaBuilder = BytesBuilder(copy: false);
      for (var i = 0; i < modified.length; i += 4096) {
        final chunk = modified.sublist(i, (i + 4096).clamp(0, modified.length));
        final out = withNativeBuffer(chunk, deltaStream.feedPtr);
        if (out.isNotEmpty) deltaBuilder.add(out);
      }
      deltaBuilder.add(deltaStream.end());
      final deltaBytes = deltaBuilder.takeBytes();
      sig.close();

      final result = await Librsync.patchBytes(basis, deltaBytes);
      expect(result, equals(modified));
    });

    test('feedPtr with single-chunk buffer matches chunked result', () async {
      final basis = makeData(8 * 1024, 0x33);
      final modified = Uint8List.fromList(basis)..[4000] = 0x99;

      final sigBytes = await Librsync.signatureBytes(basis);
      final sig = SigHandle.fromBytes(sigBytes);

      // single feedPtr call with entire modified file
      final stream = DeltaStream(sig);
      final builder = BytesBuilder(copy: false);
      final out = withNativeBuffer(modified, stream.feedPtr);
      if (out.isNotEmpty) builder.add(out);
      builder.add(stream.end());
      final deltaBytes = builder.takeBytes();
      sig.close();

      final result = await Librsync.patchBytes(basis, deltaBytes);
      expect(result, equals(modified));
    });
  });

  group('PatchStream', () {
    Uint8List runPatchStream(PatchStream stream, List<Uint8List> chunks) {
      final builder = BytesBuilder(copy: false);
      for (final chunk in chunks) {
        final out = stream.feed(chunk);
        if (out.isNotEmpty) builder.add(out);
      }
      final tail = stream.end();
      if (tail.isNotEmpty) builder.add(tail);
      return builder.takeBytes();
    }

    test('fromBytes reconstructs a modified file', () async {
      final basis = makeData(16 * 1024);
      final modified = Uint8List.fromList(basis)..[8000] = 0xAB;

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final stream = PatchStream.fromBytes(basis);
      final result = runPatchStream(stream, [deltaBytes]);
      expect(result, equals(modified));
    });

    test('fromBytes feed in chunks reconstructs correctly', () async {
      final basis = makeData(32 * 1024);
      final modified = Uint8List.fromList(basis)..[16000] = 0xCC;

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      // Feed delta in 1 KB chunks
      final chunks = <Uint8List>[];
      for (var i = 0; i < deltaBytes.length; i += 1024) {
        chunks.add(deltaBytes.sublist(i, (i + 1024).clamp(0, deltaBytes.length)));
      }

      final stream = PatchStream.fromBytes(basis);
      final result = runPatchStream(stream, chunks);
      expect(result, equals(modified));
    });

    test('fromBytes result matches patchBytes (batch API)', () async {
      final basis = makeData(8 * 1024, 0x55);
      final modified = Uint8List.fromList(basis)..[1234] = 0xFF;

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final streamResult =
          runPatchStream(PatchStream.fromBytes(basis), [deltaBytes]);
      final batchResult = await Librsync.patchBytes(basis, deltaBytes);
      expect(streamResult, equals(batchResult));
    });

    test('fromBytes handles larger modified file', () async {
      final basis = makeData(8 * 1024, 0x11);
      final modified =
          Uint8List(16 * 1024)..setAll(0, basis)..fillRange(8192, 16384, 0x22);

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final result =
          runPatchStream(PatchStream.fromBytes(basis), [deltaBytes]);
      expect(result, equals(modified));
    });

    test('fromBytes handles smaller modified file', () async {
      final basis = makeData(16 * 1024, 0x33);
      final modified = basis.sublist(0, 8 * 1024);

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final result =
          runPatchStream(PatchStream.fromBytes(basis), [deltaBytes]);
      expect(result, equals(modified));
    });

    test('close before end releases resources without crash', () async {
      final basis = makeData(4 * 1024);
      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, basis);

      final stream = PatchStream.fromBytes(basis);
      stream.feed(deltaBytes.sublist(0, deltaBytes.length ~/ 2));
      stream.close();
    });

    test('fromFile reconstructs a modified file', () async {
      final basis = makeData(16 * 1024);
      final modified = Uint8List.fromList(basis)..[8000] = 0xDD;

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final tmpPath =
          '${Directory.systemTemp.path}/ps_fromfile_${DateTime.now().microsecondsSinceEpoch}.bin';
      File(tmpPath).writeAsBytesSync(basis);
      final raf = File(tmpPath).openSync();
      try {
        final stream = PatchStream.fromFile(raf);
        final result = runPatchStream(stream, [deltaBytes]);
        expect(result, equals(modified));
      } finally {
        raf.closeSync();
        File(tmpPath).deleteSync();
      }
    });

    test('fromFile reads from start even when file position is not zero',
        () async {
      final basis = makeData(16 * 1024);
      final modified = Uint8List.fromList(basis)..[8000] = 0xDD;

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final tmpPath =
          '${Directory.systemTemp.path}/ps_fromfile_seek_${DateTime.now().microsecondsSinceEpoch}.bin';
      File(tmpPath).writeAsBytesSync(basis);
      final raf = File(tmpPath).openSync();
      try {
        // Advance position to simulate a caller that partially read the file.
        raf.setPositionSync(4096);
        final stream = PatchStream.fromFile(raf);
        final result = runPatchStream(stream, [deltaBytes]);
        expect(result, equals(modified),
            reason: 'fromFile must seek to 0 regardless of initial position');
      } finally {
        raf.closeSync();
        File(tmpPath).deleteSync();
      }
    });
  });

  group('PatchStream.fromPath', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('ps_frompath_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('reconstructs a modified file without loading base into memory',
        () async {
      final basis = makeData(32 * 1024);
      final modified = Uint8List.fromList(basis)..[16000] = 0xAB;

      final basePath = '${tmpDir.path}/base.bin';
      File(basePath).writeAsBytesSync(basis);

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final stream = PatchStream.fromPath(basePath);
      final builder = BytesBuilder(copy: false);
      final out = stream.feed(deltaBytes);
      if (out.isNotEmpty) builder.add(out);
      builder.add(stream.end());

      expect(builder.takeBytes(), equals(modified));
    });

    test('result matches fromBytes for same input', () async {
      final basis = makeData(16 * 1024, 0x55);
      final modified = Uint8List.fromList(basis)..[4000] = 0xFF;

      final basePath = '${tmpDir.path}/base.bin';
      File(basePath).writeAsBytesSync(basis);

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      Uint8List runStream(PatchStream s) {
        final b = BytesBuilder(copy: false);
        final out = s.feed(deltaBytes);
        if (out.isNotEmpty) b.add(out);
        b.add(s.end());
        return b.takeBytes();
      }

      expect(
        runStream(PatchStream.fromPath(basePath)),
        equals(runStream(PatchStream.fromBytes(basis))),
      );
    });

    test('feed in chunks reconstructs correctly', () async {
      final basis = makeData(32 * 1024);
      final modified = Uint8List.fromList(basis)..[20000] = 0x77;

      final basePath = '${tmpDir.path}/base.bin';
      File(basePath).writeAsBytesSync(basis);

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final stream = PatchStream.fromPath(basePath);
      final builder = BytesBuilder(copy: false);
      for (var i = 0; i < deltaBytes.length; i += 1024) {
        final chunk =
            deltaBytes.sublist(i, (i + 1024).clamp(0, deltaBytes.length));
        final out = stream.feed(chunk);
        if (out.isNotEmpty) builder.add(out);
      }
      builder.add(stream.end());

      expect(builder.takeBytes(), equals(modified));
    });

    test('throws LibrsyncException for non-existent path', () {
      expect(
        () => PatchStream.fromPath('${tmpDir.path}/does_not_exist.bin'),
        throwsA(isA<LibrsyncException>()),
      );
    });

    test('close before end releases resources without crash', () async {
      final basis = makeData(4 * 1024);
      final basePath = '${tmpDir.path}/base.bin';
      File(basePath).writeAsBytesSync(basis);

      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, basis);

      final stream = PatchStream.fromPath(basePath);
      stream.feed(deltaBytes.sublist(0, deltaBytes.length ~/ 2));
      stream.close();
    });
  });

  group('Librsync streaming factory methods', () {
    test('beginSignature produces same result as signatureBytes', () async {
      final data = makeData(8 * 1024);
      final stream = Librsync.beginSignature();
      final streamSig = runSignatureStream(stream, data);
      final batchSig = await Librsync.signatureBytes(data);
      expect(streamSig, equals(batchSig));
    });

    test('beginSignature forwards custom parameters', () async {
      final data = makeData(4 * 1024);
      final stream =
          Librsync.beginSignature(blockLen: 512, strongLen: 8, sigType: md4SigMagic);
      final sig = runSignatureStream(stream, data);
      expect(sig, isNotEmpty);
    });

    test('beginDelta produces same result as deltaBytes', () async {
      final basis = makeData(8 * 1024);
      final modified = Uint8List.fromList(basis)..[4000] = 0x42;
      final sigBytes = await Librsync.signatureBytes(basis);
      final sigHandle = SigHandle.fromBytes(sigBytes);
      try {
        final stream = Librsync.beginDelta(sigHandle);
        final streamDelta = runDeltaStream(stream, modified);
        final batchDelta = await Librsync.deltaBytes(sigBytes, modified);
        expect(streamDelta, equals(batchDelta));
      } finally {
        sigHandle.close();
      }
    });

    test('beginPatch reconstructs a modified file', () async {
      final basis = makeData(8 * 1024);
      final modified = Uint8List.fromList(basis)..[2000] = 0x99;
      final sigBytes = await Librsync.signatureBytes(basis);
      final deltaBytes = await Librsync.deltaBytes(sigBytes, modified);

      final stream = Librsync.beginPatch(basis);
      final builder = BytesBuilder(copy: false);
      final out = stream.feed(deltaBytes);
      if (out.isNotEmpty) builder.add(out);
      final tail = stream.end();
      if (tail.isNotEmpty) builder.add(tail);
      expect(builder.takeBytes(), equals(modified));
    });
  });

  group('streaming round-trip', () {
    test('SignatureStream + DeltaStream + patchBytes reconstructs modified file',
        () async {
      final basis = makeData(32 * 1024);
      final modified = Uint8List.fromList(basis)..[16000] = 0xDE;

      final sigBytes = runSignatureStream(SignatureStream(), basis);
      final sigHandle = SigHandle.fromBytes(sigBytes);
      final deltaBytes = runDeltaStream(DeltaStream(sigHandle), modified);
      sigHandle.close();

      final result = await Librsync.patchBytes(basis, deltaBytes);
      expect(result, equals(modified));
    });

    test('streaming sig + streaming delta: larger modified file reconstructs',
        () async {
      final basis = makeData(8 * 1024, 0x11);
      final modified =
          Uint8List(16 * 1024)..setAll(0, basis)..fillRange(8192, 16384, 0xCC);

      final sigBytes = runSignatureStream(SignatureStream(), basis);
      final sigHandle = SigHandle.fromBytes(sigBytes);
      final deltaBytes = runDeltaStream(DeltaStream(sigHandle), modified);
      sigHandle.close();

      final result = await Librsync.patchBytes(basis, deltaBytes);
      expect(result, equals(modified));
    });

    test('streaming sig + streaming delta: smaller modified file reconstructs',
        () async {
      final basis = makeData(16 * 1024, 0x55);
      final modified = basis.sublist(0, 8 * 1024);

      final sigBytes = runSignatureStream(SignatureStream(), basis);
      final sigHandle = SigHandle.fromBytes(sigBytes);
      final deltaBytes = runDeltaStream(DeltaStream(sigHandle), modified);
      sigHandle.close();

      final result = await Librsync.patchBytes(basis, deltaBytes);
      expect(result, equals(modified));
    });

    test('patchSync with BytesReadSeeker short-circuits _drainReadSeeker',
        () {
      // BytesReadSeeker.bytes is used directly — no drain copy.
      final basis = makeData(8 * 1024, 0x33);
      final modified = Uint8List.fromList(basis)..[1000] = 0x77;

      final sigWriter = BytesWriter();
      Librsync.signatureSync(BytesReadSeeker(basis), sigWriter);
      final sigBytes = sigWriter.takeBytes();

      final deltaWriter = BytesWriter();
      Librsync.deltaSync(
        BytesReadSeeker(sigBytes),
        BytesReadSeeker(modified),
        deltaWriter,
      );
      final deltaBytes = deltaWriter.takeBytes();

      final outWriter = BytesWriter();
      Librsync.patchSync(
        BytesReadSeeker(basis),
        BytesReadSeeker(deltaBytes),
        outWriter,
      );
      expect(outWriter.takeBytes(), equals(modified));
    });

    test('streaming APIs and batch APIs agree on the same data', () async {
      final basis = makeData(12 * 1024);
      final modified = Uint8List.fromList(basis)
        ..[3000] = 0xAB
        ..[9000] = 0xCD;

      // All-streaming path
      final streamSig = runSignatureStream(SignatureStream(), basis);
      final sigHandle = SigHandle.fromBytes(streamSig);
      final streamDelta = runDeltaStream(DeltaStream(sigHandle), modified);
      sigHandle.close();
      final streamResult = await Librsync.patchBytes(basis, streamDelta);

      // All-batch path
      final batchSig = await Librsync.signatureBytes(basis);
      final batchDelta = await Librsync.deltaBytes(batchSig, modified);
      final batchResult = await Librsync.patchBytes(basis, batchDelta);

      expect(streamResult, equals(modified));
      expect(batchResult, equals(modified));
    });
  });
}

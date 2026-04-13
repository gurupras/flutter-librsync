// ignore_for_file: avoid_print
// Benchmarks for flutter_librsync — all API layers.
//
// Run on Linux desktop:
//   flutter test integration_test/benchmark_test.dart -d linux
//
// Run on a connected Android/iOS device:
//   flutter test integration_test/benchmark_test.dart -d <device-id>
//
// Output is a tab-aligned table printed to stdout:
//   [BENCH]  <operation padded>  <reps>  <ms/op>  <MB/s>
//
// Layers covered:
//   1. Bytes API       – signatureBytes / deltaBytes / patchBytes
//   2. File API        – signatureFile  / deltaFile  / patchFile
//   3. Mixed API       – signatureFileToBytes / deltaFileToBytes
//   4. Streaming API   – SignatureStream / DeltaStream / PatchStream (low-level,
//                        run synchronously to isolate raw FFI cost)
//   5. Sync API        – signatureSync / deltaSync / patchSync
//      (ReadSeeker / Writer wrappers)

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_librsync/flutter_librsync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ── Configuration ─────────────────────────────────────────────────────────────

/// File sizes under test.
const _sizes = <String, int>{
  '64 KB': 64 * 1024,
  '1 MB':   1 * 1024 * 1024,
  '10 MB': 10 * 1024 * 1024,
  '50 MB': 50 * 1024 * 1024,
};

/// Warm-up reps (discarded).
const _warmupReps = 2;

/// Target wall-clock budget per benchmark (ms); reps are added until reached.
const _budgetMs = 3000;

/// Minimum reps regardless of budget.
const _minReps = 3;

// ── Data helpers ──────────────────────────────────────────────────────────────

Uint8List _randomBytes(int size, int seed) {
  final rng = Random(seed);
  return Uint8List.fromList(List.generate(size, (_) => rng.nextInt(256)));
}

/// Returns a copy of [base] with ~[fraction] of bytes randomly changed.
Uint8List _modify(Uint8List base, double fraction, int seed) {
  final out = Uint8List.fromList(base);
  final rng = Random(seed);
  final n = max(1, (base.length * fraction).round());
  for (var i = 0; i < n; i++) {
    out[rng.nextInt(out.length)] = rng.nextInt(256);
  }
  return out;
}

// ── Benchmark runner ──────────────────────────────────────────────────────────

const _col1 = 50;

Future<void> _bench(
  String label,
  int dataSizeBytes,
  Future<void> Function() body,
) async {
  for (var i = 0; i < _warmupReps; i++) {
    await body();
  }

  var reps = 0;
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < _budgetMs || reps < _minReps) {
    await body();
    reps++;
  }
  sw.stop();

  final msPerOp  = sw.elapsedMilliseconds / reps;
  final mbPerSec = dataSizeBytes / (msPerOp * 1000);

  print(
    '[BENCH]  ${label.padRight(_col1)}'
    '  ${reps.toString().padLeft(4)} reps'
    '  ${msPerOp.toStringAsFixed(2).padLeft(9)} ms/op'
    '  ${mbPerSec.toStringAsFixed(2).padLeft(8)} MB/s',
  );
}

// ── Temp file helpers ─────────────────────────────────────────────────────────

String _tmp(String tag) =>
    '${Directory.systemTemp.path}/librsync_bench_$tag';

void _write(String path, Uint8List data) =>
    File(path).writeAsBytesSync(data);

void _del(List<String> paths) {
  for (final p in paths) {
    try { File(p).deleteSync(); } catch (_) {}
  }
}

// ── Helpers for streaming API (no Isolate) ────────────────────────────────────

void _feedAll(SignatureStream s, Uint8List data) {
  var off = 0;
  while (off < data.length) {
    final end = (off + defaultChunkSize).clamp(0, data.length);
    s.feed(data.sublist(off, end));
    off = end;
  }
  s.end();
}

void _feedAllDelta(DeltaStream s, Uint8List data) {
  var off = 0;
  while (off < data.length) {
    final end = (off + defaultChunkSize).clamp(0, data.length);
    s.feed(data.sublist(off, end));
    off = end;
  }
  s.end();
}

void _feedAllPatch(PatchStream s, Uint8List delta) {
  var off = 0;
  while (off < delta.length) {
    final end = (off + defaultChunkSize).clamp(0, delta.length);
    s.feed(delta.sublist(off, end));
    off = end;
  }
  s.end();
}

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final sep = '─' * (_col1 + 50);
    print('');
    print('flutter_librsync benchmarks');
    print(sep);
    print(
      '${'Operation'.padRight(_col1)}'
      '       Reps        ms/op         MB/s',
    );
    print(sep);
  });

  tearDownAll(() {
    print('─' * (_col1 + 50));
    print('');
  });

  // ════════════════════════════════════════════════════════════════════════════
  // 1. BYTES API
  //    signatureBytes / deltaBytes / patchBytes
  //    Data transferred via TransferableTypedData into Isolate.run().
  // ════════════════════════════════════════════════════════════════════════════

  group('1. Bytes API', () {
    for (final e in _sizes.entries) {
      test('signatureBytes  ${e.key}', () async {
        final data = _randomBytes(e.value, 1);
        await _bench('signatureBytes  ${e.key}', e.value, () async {
          await Librsync.signatureBytes(data);
        });
      });
    }

    for (final e in _sizes.entries) {
      test('deltaBytes  ${e.key}  1% changed', () async {
        final basis = _randomBytes(e.value, 1);
        final mod   = _modify(basis, 0.01, 2);
        final sig   = await Librsync.signatureBytes(basis);
        await _bench('deltaBytes  ${e.key}  1% changed', e.value, () async {
          await Librsync.deltaBytes(sig, mod);
        });
      });
    }

    for (final e in _sizes.entries) {
      test('deltaBytes  ${e.key}  100% changed', () async {
        final basis = _randomBytes(e.value, 1);
        final mod   = _randomBytes(e.value, 99);
        final sig   = await Librsync.signatureBytes(basis);
        await _bench('deltaBytes  ${e.key}  100% changed', e.value, () async {
          await Librsync.deltaBytes(sig, mod);
        });
      });
    }

    for (final e in _sizes.entries) {
      test('patchBytes  ${e.key}', () async {
        final basis = _randomBytes(e.value, 1);
        final mod   = _modify(basis, 0.01, 2);
        final sig   = await Librsync.signatureBytes(basis);
        final delta = await Librsync.deltaBytes(sig, mod);
        await _bench('patchBytes  ${e.key}', e.value, () async {
          await Librsync.patchBytes(basis, delta);
        });
      });
    }

    for (final e in _sizes.entries) {
      test('round-trip bytes  ${e.key}', () async {
        final basis = _randomBytes(e.value, 1);
        final mod   = _modify(basis, 0.01, 2);
        await _bench('round-trip bytes  ${e.key}  1% changed', e.value, () async {
          final sig   = await Librsync.signatureBytes(basis);
          final delta = await Librsync.deltaBytes(sig, mod);
          await Librsync.patchBytes(basis, delta);
        });
      });
    }
  });

  // ════════════════════════════════════════════════════════════════════════════
  // 2. FILE API
  //    signatureFile / deltaFile / patchFile
  //    I/O performed inside Isolate.run() — includes disk read/write.
  // ════════════════════════════════════════════════════════════════════════════

  group('2. File API', () {
    for (final e in _sizes.entries) {
      test('signatureFile  ${e.key}', () async {
        final tag     = e.key.replaceAll(' ', '_');
        final inPath  = _tmp('sf_in_$tag');
        final sigPath = _tmp('sf_sig_$tag');
        _write(inPath, _randomBytes(e.value, 1));
        try {
          await _bench('signatureFile  ${e.key}', e.value, () async {
            await Librsync.signatureFile(inPath, sigPath);
          });
        } finally {
          _del([inPath, sigPath]);
        }
      });
    }

    for (final e in _sizes.entries) {
      test('deltaFile  ${e.key}  1% changed', () async {
        final tag      = e.key.replaceAll(' ', '_');
        final basis    = _randomBytes(e.value, 1);
        final mod      = _modify(basis, 0.01, 2);
        final basePath = _tmp('df_basis_$tag');
        final modPath  = _tmp('df_mod_$tag');
        final sigPath  = _tmp('df_sig_$tag');
        final delPath  = _tmp('df_del_$tag');
        _write(basePath, basis);
        _write(modPath, mod);
        await Librsync.signatureFile(basePath, sigPath);
        try {
          await _bench('deltaFile  ${e.key}  1% changed', e.value, () async {
            await Librsync.deltaFile(sigPath, modPath, delPath);
          });
        } finally {
          _del([basePath, modPath, sigPath, delPath]);
        }
      });
    }

    for (final e in _sizes.entries) {
      test('patchFile  ${e.key}', () async {
        final tag      = e.key.replaceAll(' ', '_');
        final basis    = _randomBytes(e.value, 1);
        final mod      = _modify(basis, 0.01, 2);
        final basePath = _tmp('pf_basis_$tag');
        final modPath  = _tmp('pf_mod_$tag');
        final sigPath  = _tmp('pf_sig_$tag');
        final delPath  = _tmp('pf_del_$tag');
        final outPath  = _tmp('pf_out_$tag');
        _write(basePath, basis);
        _write(modPath, mod);
        await Librsync.signatureFile(basePath, sigPath);
        await Librsync.deltaFile(sigPath, modPath, delPath);
        try {
          await _bench('patchFile  ${e.key}', e.value, () async {
            await Librsync.patchFile(basePath, delPath, outPath);
          });
        } finally {
          _del([basePath, modPath, sigPath, delPath, outPath]);
        }
      });
    }
  });

  // ════════════════════════════════════════════════════════════════════════════
  // 3. MIXED API
  //    signatureFileToBytes / deltaFileToBytes
  //    File input, bytes output — streaming inside Isolate.run().
  // ════════════════════════════════════════════════════════════════════════════

  group('3. Mixed API', () {
    for (final e in _sizes.entries) {
      test('signatureFileToBytes  ${e.key}', () async {
        final tag    = e.key.replaceAll(' ', '_');
        final inPath = _tmp('sftb_$tag');
        _write(inPath, _randomBytes(e.value, 1));
        try {
          await _bench('signatureFileToBytes  ${e.key}', e.value, () async {
            await Librsync.signatureFileToBytes(inPath);
          });
        } finally {
          _del([inPath]);
        }
      });
    }

    for (final e in _sizes.entries) {
      test('deltaFileToBytes  ${e.key}  1% changed', () async {
        final tag      = e.key.replaceAll(' ', '_');
        final basis    = _randomBytes(e.value, 1);
        final mod      = _modify(basis, 0.01, 2);
        final basePath = _tmp('dftb_basis_$tag');
        final modPath  = _tmp('dftb_mod_$tag');
        final sigPath  = _tmp('dftb_sig_$tag');
        _write(basePath, basis);
        _write(modPath, mod);
        await Librsync.signatureFile(basePath, sigPath);
        try {
          await _bench('deltaFileToBytes  ${e.key}  1% changed', e.value, () async {
            await Librsync.deltaFileToBytes(sigPath, modPath);
          });
        } finally {
          _del([basePath, modPath, sigPath]);
        }
      });
    }
  });

  // ════════════════════════════════════════════════════════════════════════════
  // 4. STREAMING API  (low-level, synchronous — no Isolate.run)
  //    Measures raw FFI throughput: chunk feeding loop with 256 KB chunks.
  //    These are the building blocks used by the file and bytes APIs.
  // ════════════════════════════════════════════════════════════════════════════

  group('4. Streaming API (sync, no isolate)', () {
    for (final e in _sizes.entries) {
      test('SignatureStream  ${e.key}', () async {
        final data = _randomBytes(e.value, 1);
        await _bench('SignatureStream  ${e.key}', e.value, () async {
          final s = Librsync.beginSignature();
          try {
            _feedAll(s, data);
          } catch (_) {
            s.close();
            rethrow;
          }
        });
      });
    }

    for (final e in _sizes.entries) {
      test('DeltaStream  ${e.key}  1% changed', () async {
        final basis = _randomBytes(e.value, 1);
        final mod   = _modify(basis, 0.01, 2);
        final sig   = SigHandle.fromBytes(await Librsync.signatureBytes(basis));
        try {
          await _bench('DeltaStream  ${e.key}  1% changed', e.value, () async {
            final s = Librsync.beginDelta(sig);
            try {
              _feedAllDelta(s, mod);
            } catch (_) {
              s.close();
              rethrow;
            }
          });
        } finally {
          sig.close();
        }
      });
    }

    for (final e in _sizes.entries) {
      test('DeltaStream  ${e.key}  100% changed', () async {
        final basis = _randomBytes(e.value, 1);
        final mod   = _randomBytes(e.value, 99);
        final sig   = SigHandle.fromBytes(await Librsync.signatureBytes(basis));
        try {
          await _bench('DeltaStream  ${e.key}  100% changed', e.value, () async {
            final s = Librsync.beginDelta(sig);
            try {
              _feedAllDelta(s, mod);
            } catch (_) {
              s.close();
              rethrow;
            }
          });
        } finally {
          sig.close();
        }
      });
    }

    for (final e in _sizes.entries) {
      test('PatchStream  ${e.key}', () async {
        final basis = _randomBytes(e.value, 1);
        final mod   = _modify(basis, 0.01, 2);
        final sig   = await Librsync.signatureBytes(basis);
        final delta = await Librsync.deltaBytes(sig, mod);
        await _bench('PatchStream  ${e.key}', e.value, () async {
          final s = Librsync.beginPatch((offset, buf) {
            final avail = basis.length - offset;
            if (avail <= 0) return 0;
            final n = buf.length < avail ? buf.length : avail;
            buf.setRange(0, n, basis, offset);
            return n;
          });
          try {
            _feedAllPatch(s, delta);
          } catch (_) {
            s.close();
            rethrow;
          }
        });
      });
    }
  });

  // ════════════════════════════════════════════════════════════════════════════
  // 5. SYNC API  (ReadSeeker / Writer wrappers)
  //    signatureSync / deltaSync / patchSync
  //    Same building blocks as streaming but via the legacy ReadSeeker/Writer
  //    interface (used by the web implementation for parity).
  // ════════════════════════════════════════════════════════════════════════════

  group('5. Sync API (ReadSeeker / Writer)', () {
    for (final e in _sizes.entries) {
      test('signatureSync  ${e.key}', () async {
        final data = _randomBytes(e.value, 1);
        await _bench('signatureSync  ${e.key}', e.value, () async {
          final out = BytesWriter();
          Librsync.signatureSync(BytesReadSeeker(data), out);
        });
      });
    }

    for (final e in _sizes.entries) {
      test('deltaSync  ${e.key}  1% changed', () async {
        final basis   = _randomBytes(e.value, 1);
        final mod     = _modify(basis, 0.01, 2);
        final sigOut  = BytesWriter();
        Librsync.signatureSync(BytesReadSeeker(basis), sigOut);
        final sigBytes = sigOut.takeBytes();
        await _bench('deltaSync  ${e.key}  1% changed', e.value, () async {
          final out = BytesWriter();
          Librsync.deltaSync(BytesReadSeeker(sigBytes), BytesReadSeeker(mod), out);
        });
      });
    }

    for (final e in _sizes.entries) {
      test('patchSync  ${e.key}', () async {
        final basis   = _randomBytes(e.value, 1);
        final mod     = _modify(basis, 0.01, 2);
        final sigOut  = BytesWriter();
        Librsync.signatureSync(BytesReadSeeker(basis), sigOut);
        final sigBytes = sigOut.takeBytes();
        final delOut  = BytesWriter();
        Librsync.deltaSync(BytesReadSeeker(sigBytes), BytesReadSeeker(mod), delOut);
        final deltaBytes = delOut.takeBytes();
        await _bench('patchSync  ${e.key}', e.value, () async {
          final out = BytesWriter();
          Librsync.patchSync(BytesReadSeeker(basis), BytesReadSeeker(deltaBytes), out);
        });
      });
    }

    for (final e in _sizes.entries) {
      test('round-trip sync  ${e.key}', () async {
        final basis = _randomBytes(e.value, 1);
        final mod   = _modify(basis, 0.01, 2);
        await _bench('round-trip sync  ${e.key}  1% changed', e.value, () async {
          final sigOut = BytesWriter();
          Librsync.signatureSync(BytesReadSeeker(basis), sigOut);
          final sigBytes = sigOut.takeBytes();

          final delOut = BytesWriter();
          Librsync.deltaSync(BytesReadSeeker(sigBytes), BytesReadSeeker(mod), delOut);
          final deltaBytes = delOut.takeBytes();

          final out = BytesWriter();
          Librsync.patchSync(BytesReadSeeker(basis), BytesReadSeeker(deltaBytes), out);
        });
      });
    }
  });
}

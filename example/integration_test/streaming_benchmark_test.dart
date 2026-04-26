// ignore_for_file: avoid_print, depend_on_referenced_packages
// Streaming throughput benchmarks for flutter_librsync.
//
// Mirrors the Go-side benchmarks in librsync-go/ffi/adapter so numbers are
// directly comparable. Sweeps file size × chunk size for the streaming Delta
// and Patch APIs (the FFI fast paths) and reports MB/s.
//
// ── Streaming model ──────────────────────────────────────────────────────────
// Real callers stream files chunk-by-chunk via something like
// `RandomAccessFile.readIntoSync(buffer)` and never hold the full file in any
// single buffer. The benchmarks below honour that constraint:
//
//   * The "corpus" for the new file / delta lives in a Dart Uint8List only as
//     a cheap stand-in for a disk source. We never marshal it as one slab to
//     the FFI layer; we copy into a chunk-sized working buffer per call.
//   * The "feed" variant: chunk-sized Uint8List per call (simulates reading
//     from disk into a Dart-managed buffer). Each call's input is then
//     calloc'd + copied + freed inside the FFI layer.
//   * The "feedPtr" variant: ONE chunk-sized C-heap buffer is allocated up
//     front and reused across every chunk (simulates reading from disk into
//     `chunkBuf.asTypedList(n)` directly — zero-copy across the FFI
//     boundary). The whole input never lives in C memory at any point.
//
// Patch basis: the library currently exposes `PatchStream.fromBytes` (basis
// fully in C memory) and `PatchStream.fromPath` (Go opens and seeks the
// file). The benchmarks below use `fromBytes` because we don't want to
// involve disk I/O in the throughput numbers; this is a one-time setup cost
// outside the timed feed loop. For a truly memory-bounded basis use
// `PatchStream.fromPath` in production.
//
// Workload: "ChangeTail" — rewrite the final 10 % of the basis with fresh
// random bytes, so the delta is roughly 10 % of input size and the patch
// has real COPY+LITERAL ops to dispatch.
//
// Throughput convention:
//   - Delta: MB/s = input bytes (size of new file) / wall time.
//   - Patch: MB/s = output bytes (reconstructed file size) / wall time.
//
// Run on Linux desktop:
//   flutter test integration_test/streaming_benchmark_test.dart -d linux

import 'dart:ffi' as ffi;
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_librsync/flutter_librsync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ── Configuration ────────────────────────────────────────────────────────────

const _sizes = <String, int>{
  '1 MB':   1 * 1024 * 1024,
  '10 MB': 10 * 1024 * 1024,
  '50 MB': 50 * 1024 * 1024,
};

const _chunkSizes = <String, int>{
  '4 KB':   4 * 1024,
  '64 KB': 64 * 1024,
  '256 KB': 256 * 1024,
  '1 MB':  1024 * 1024,
};

const _warmupReps = 1;
const _budgetMs = 2000;
const _minReps = 3;

// ── Data helpers ─────────────────────────────────────────────────────────────

Uint8List _randomBytes(int size, int seed) {
  final rng = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// basis with the final 10 % overwritten by fresh random bytes —
/// matches Go's BenchmarkDeltaChangeTail / makeCorpus.
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

// ── Benchmark runner ─────────────────────────────────────────────────────────

const _col1 = 64;

void _bench(
  String label,
  int dataSizeBytes,
  void Function() body, {
  double? extraPct,
  String extraLabel = 'delta',
}) {
  for (var i = 0; i < _warmupReps; i++) {
    body();
  }

  var reps = 0;
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < _budgetMs || reps < _minReps) {
    body();
    reps++;
  }
  sw.stop();

  final msPerOp  = sw.elapsedMilliseconds / reps;
  final mbPerSec = dataSizeBytes / (msPerOp * 1000);

  final extra = extraPct == null
      ? ''
      : '  $extraLabel=${extraPct.toStringAsFixed(2)}%';

  print(
    '[BENCH]  ${label.padRight(_col1)}'
    '  ${reps.toString().padLeft(4)} reps'
    '  ${msPerOp.toStringAsFixed(2).padLeft(9)} ms/op'
    '  ${mbPerSec.toStringAsFixed(2).padLeft(8)} MB/s'
    '$extra',
  );
}

// ── Streaming pipelines (raw FFI, no Isolate.run) ────────────────────────────
//
// All loops below feed exactly one chunk at a time and never hold more than
// `chunkSize` of input in any single buffer.

// ── feed() variants — Uint8List input, calloc+copy+free per chunk ─────────

int _runDeltaFeed(SigHandle sig, Uint8List source, int chunkSize) {
  final s = DeltaStream(sig);
  final chunkBuf = Uint8List(chunkSize);
  var produced = 0;
  try {
    var off = 0;
    while (off < source.length) {
      final n = min(chunkSize, source.length - off);
      // Simulate `RandomAccessFile.readIntoSync(chunkBuf)` from a streamed source.
      chunkBuf.setRange(0, n, source, off);
      // Sublist view so we don't pretend we read more than n bytes.
      produced += s.feed(Uint8List.sublistView(chunkBuf, 0, n)).length;
      off += n;
    }
    produced += s.end().length;
  } catch (_) {
    s.close();
    rethrow;
  }
  return produced;
}

int _runPatchFeed(Uint8List basis, Uint8List delta, int chunkSize) {
  final s = PatchStream.fromBytes(basis);
  final chunkBuf = Uint8List(chunkSize);
  var produced = 0;
  try {
    var off = 0;
    while (off < delta.length) {
      final n = min(chunkSize, delta.length - off);
      chunkBuf.setRange(0, n, delta, off);
      produced += s.feed(Uint8List.sublistView(chunkBuf, 0, n)).length;
      off += n;
    }
    produced += s.end().length;
  } catch (_) {
    s.close();
    rethrow;
  }
  return produced;
}

// ── feedInto() variants — fully zero-copy on both sides ───────────────────
//
// Two persistent C-heap buffers per session — one for input, one for output.
// `feedInto` copies bytes directly from the in-buffer into native code and
// writes produced output directly into the out-buffer (no per-call calloc,
// no per-call Uint8List allocation, no copy back to Dart-managed memory).

int _runDeltaFeedInto(
  SigHandle sig,
  Uint8List source,
  ffi.Pointer<ffi.Uint8> inPtr,
  Uint8List inView,
  ffi.Pointer<ffi.Uint8> outPtr,
  int outCap,
  ffi.Pointer<ffi.Size> bwPtr,
  ffi.Pointer<ffi.Int32> mpPtr,
  int chunkSize,
) {
  // ignore: deprecated_member_use
  final s = DeltaStream(sig);
  var produced = 0;
  try {
    var off = 0;
    while (off < source.length) {
      final n = min(chunkSize, source.length - off);
      inView.setRange(0, n, source, off);
      // ignore: deprecated_member_use
      produced += s.feedInto(inPtr, n, outPtr, outCap, bwPtr, mpPtr);
      while (mpPtr.value != 0) {
        // ignore: deprecated_member_use
        produced += s.feedInto(inPtr, 0, outPtr, outCap, bwPtr, mpPtr);
      }
      off += n;
    }
    do {
      // ignore: deprecated_member_use
      produced += s.endInto(outPtr, outCap, bwPtr, mpPtr);
    } while (mpPtr.value != 0);
  } catch (_) {
    s.close();
    rethrow;
  }
  return produced;
}

int _runPatchFeedInto(
  Uint8List basis,
  Uint8List delta,
  ffi.Pointer<ffi.Uint8> inPtr,
  Uint8List inView,
  ffi.Pointer<ffi.Uint8> outPtr,
  int outCap,
  ffi.Pointer<ffi.Size> bwPtr,
  ffi.Pointer<ffi.Int32> mpPtr,
  int chunkSize,
) {
  // ignore: deprecated_member_use
  final s = PatchStream.fromBytes(basis);
  var produced = 0;
  try {
    var off = 0;
    while (off < delta.length) {
      final n = min(chunkSize, delta.length - off);
      inView.setRange(0, n, delta, off);
      // ignore: deprecated_member_use
      produced += s.feedInto(inPtr, n, outPtr, outCap, bwPtr, mpPtr);
      while (mpPtr.value != 0) {
        // ignore: deprecated_member_use
        produced += s.feedInto(inPtr, 0, outPtr, outCap, bwPtr, mpPtr);
      }
      off += n;
    }
    do {
      // ignore: deprecated_member_use
      produced += s.endInto(outPtr, outCap, bwPtr, mpPtr);
    } while (mpPtr.value != 0);
  } catch (_) {
    s.close();
    rethrow;
  }
  return produced;
}

// ── feedPtr() variants — one persistent chunk-sized C-heap buffer ─────────
//
// Allocate a single chunk-sized buffer in C memory once, then for each chunk
// copy bytes directly into its typed-data view (this is what
// `RandomAccessFile.readIntoSync(ptr.asTypedList(n))` does in production)
// and dispatch via `feedPtr`. Zero allocations and zero copies on the FFI
// boundary per chunk.

int _runDeltaPtr(
  SigHandle sig,
  Uint8List source,
  ffi.Pointer<ffi.Uint8> chunkPtr,
  Uint8List chunkView,
  int chunkSize,
) {
  final s = DeltaStream(sig);
  var produced = 0;
  try {
    var off = 0;
    while (off < source.length) {
      final n = min(chunkSize, source.length - off);
      chunkView.setRange(0, n, source, off);
      produced += s.feedPtr(chunkPtr, n).length;
      off += n;
    }
    produced += s.end().length;
  } catch (_) {
    s.close();
    rethrow;
  }
  return produced;
}

int _runPatchPtr(
  Uint8List basis,
  Uint8List delta,
  ffi.Pointer<ffi.Uint8> chunkPtr,
  Uint8List chunkView,
  int chunkSize,
) {
  final s = PatchStream.fromBytes(basis);
  var produced = 0;
  try {
    var off = 0;
    while (off < delta.length) {
      final n = min(chunkSize, delta.length - off);
      chunkView.setRange(0, n, delta, off);
      produced += s.feedPtr(chunkPtr, n).length;
      off += n;
    }
    produced += s.end().length;
  } catch (_) {
    s.close();
    rethrow;
  }
  return produced;
}

// ── Main ─────────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final sep = '─' * (_col1 + 60);
    print('');
    print('flutter_librsync streaming benchmarks (feed vs feedPtr, chunked)');
    print(sep);
    print(
      '${'Operation'.padRight(_col1)}'
      '       Reps        ms/op         MB/s     extra',
    );
    print(sep);
  });

  tearDownAll(() {
    print('─' * (_col1 + 60));
    print('');
  });

  // ══════════════════════════════════════════════════════════════════════════
  // DeltaStream — input MB/s
  // ══════════════════════════════════════════════════════════════════════════

  group('DeltaStream', () {
    for (final size in _sizes.entries) {
      for (final chunk in _chunkSizes.entries) {
        test('Delta feed     file=${size.key}  chunk=${chunk.key}', () async {
          final basis = _randomBytes(size.value, 1);
          final modified = _changeTail(basis, 2);
          final sigBytes = await Librsync.signatureBytes(basis);
          final sig = SigHandle.fromBytes(sigBytes);
          try {
            final deltaSize = _runDeltaFeed(sig, modified, chunk.value);
            final pct = deltaSize / size.value * 100;
            _bench(
              'Delta feed     file=${size.key}  chunk=${chunk.key}',
              size.value,
              () => _runDeltaFeed(sig, modified, chunk.value),
              extraPct: pct,
            );
          } finally {
            sig.close();
          }
        });

        test('Delta feedPtr  file=${size.key}  chunk=${chunk.key}', () async {
          final basis = _randomBytes(size.value, 1);
          final modified = _changeTail(basis, 2);
          final sigBytes = await Librsync.signatureBytes(basis);
          final sig = SigHandle.fromBytes(sigBytes);
          final chunkPtr = calloc<ffi.Uint8>(chunk.value);
          final chunkView = chunkPtr.asTypedList(chunk.value);
          try {
            final deltaSize = _runDeltaPtr(
              sig, modified, chunkPtr, chunkView, chunk.value,
            );
            final pct = deltaSize / size.value * 100;
            _bench(
              'Delta feedPtr  file=${size.key}  chunk=${chunk.key}',
              size.value,
              () => _runDeltaPtr(
                sig, modified, chunkPtr, chunkView, chunk.value,
              ),
              extraPct: pct,
            );
          } finally {
            calloc.free(chunkPtr);
            sig.close();
          }
        });

        test('Delta feedInto file=${size.key}  chunk=${chunk.key}', () async {
          final basis = _randomBytes(size.value, 1);
          final modified = _changeTail(basis, 2);
          final sigBytes = await Librsync.signatureBytes(basis);
          final sig = SigHandle.fromBytes(sigBytes);
          // Output capacity sized for the typical delta burst. Delta literals
          // can flush in ≤16 MB groups so we generously oversize for the 50 MB
          // case; smaller files use proportionally smaller out buffers.
          final outCap = 1 << 20; // 1 MB
          final inPtr = calloc<ffi.Uint8>(chunk.value);
          final outPtr = calloc<ffi.Uint8>(outCap);
          final bwPtr = calloc<ffi.Size>();
          final mpPtr = calloc<ffi.Int32>();
          final inView = inPtr.asTypedList(chunk.value);
          try {
            final deltaSize = _runDeltaFeedInto(
              sig, modified, inPtr, inView, outPtr, outCap, bwPtr, mpPtr, chunk.value,
            );
            final pct = deltaSize / size.value * 100;
            _bench(
              'Delta feedInto file=${size.key}  chunk=${chunk.key}',
              size.value,
              () => _runDeltaFeedInto(
                sig, modified, inPtr, inView, outPtr, outCap, bwPtr, mpPtr, chunk.value,
              ),
              extraPct: pct,
            );
          } finally {
            calloc.free(inPtr);
            calloc.free(outPtr);
            calloc.free(bwPtr);
            calloc.free(mpPtr);
            sig.close();
          }
        });
      }
    }
  });

  // ══════════════════════════════════════════════════════════════════════════
  // PatchStream — output (reconstruction) MB/s
  // ══════════════════════════════════════════════════════════════════════════

  group('PatchStream', () {
    for (final size in _sizes.entries) {
      for (final chunk in _chunkSizes.entries) {
        test('Patch feed     file=${size.key}  chunk=${chunk.key}', () async {
          final basis = _randomBytes(size.value, 1);
          final modified = _changeTail(basis, 2);
          final sigBytes = await Librsync.signatureBytes(basis);
          final delta = await Librsync.deltaBytes(sigBytes, modified);
          final pct = delta.length / size.value * 100;

          _bench(
            'Patch feed     file=${size.key}  chunk=${chunk.key}',
            size.value,
            () {
              final produced = _runPatchFeed(basis, delta, chunk.value);
              if (produced != size.value) {
                throw StateError(
                  'patch output size mismatch: got $produced, want ${size.value}',
                );
              }
            },
            extraPct: pct,
          );
        });

        test('Patch feedPtr  file=${size.key}  chunk=${chunk.key}', () async {
          final basis = _randomBytes(size.value, 1);
          final modified = _changeTail(basis, 2);
          final sigBytes = await Librsync.signatureBytes(basis);
          final delta = await Librsync.deltaBytes(sigBytes, modified);
          final pct = delta.length / size.value * 100;
          final chunkPtr = calloc<ffi.Uint8>(chunk.value);
          final chunkView = chunkPtr.asTypedList(chunk.value);

          try {
            _bench(
              'Patch feedPtr  file=${size.key}  chunk=${chunk.key}',
              size.value,
              () {
                final produced = _runPatchPtr(
                  basis, delta, chunkPtr, chunkView, chunk.value,
                );
                if (produced != size.value) {
                  throw StateError(
                    'patch output size mismatch: got $produced, want ${size.value}',
                  );
                }
              },
              extraPct: pct,
            );
          } finally {
            calloc.free(chunkPtr);
          }
        });

        test('Patch feedInto file=${size.key}  chunk=${chunk.key}', () async {
          final basis = _randomBytes(size.value, 1);
          final modified = _changeTail(basis, 2);
          final sigBytes = await Librsync.signatureBytes(basis);
          final delta = await Librsync.deltaBytes(sigBytes, modified);
          final pct = delta.length / size.value * 100;
          // Patch can produce ~10× input per chunk in the worst case (one
          // big COPY op). 1 MB out buffer covers any chunked workload here.
          final outCap = 1 << 20;
          final inPtr = calloc<ffi.Uint8>(chunk.value);
          final outPtr = calloc<ffi.Uint8>(outCap);
          final bwPtr = calloc<ffi.Size>();
          final mpPtr = calloc<ffi.Int32>();
          final inView = inPtr.asTypedList(chunk.value);

          try {
            _bench(
              'Patch feedInto file=${size.key}  chunk=${chunk.key}',
              size.value,
              () {
                final produced = _runPatchFeedInto(
                  basis, delta, inPtr, inView, outPtr, outCap, bwPtr, mpPtr, chunk.value,
                );
                if (produced != size.value) {
                  throw StateError(
                    'patch output size mismatch: got $produced, want ${size.value}',
                  );
                }
              },
              extraPct: pct,
            );
          } finally {
            calloc.free(inPtr);
            calloc.free(outPtr);
            calloc.free(bwPtr);
            calloc.free(mpPtr);
          }
        });
      }
    }
  });
}

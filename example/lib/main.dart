import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_librsync/flutter_librsync.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const LibrsyncDemoApp());
}

class LibrsyncDemoApp extends StatelessWidget {
  const LibrsyncDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_librsync demo',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  String _status = 'Press a button to run a demo.';
  bool _running = false;

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _log(String msg) => setState(() => _status = msg);

  Future<Directory> get _tmp async => getTemporaryDirectory();

  Future<String> _writeTmp(String name, Uint8List data) async {
    final f = File('${(await _tmp).path}/$name')..createSync(recursive: true);
    f.writeAsBytesSync(data);
    return f.path;
  }

  // ── Demos ──────────────────────────────────────────────────────────────────

  Future<void> _runBytesDemo() async {
    setState(() => _running = true);
    try {
      _log('Generating 64 KiB of test data…');
      final basis = Uint8List(65536)..fillRange(0, 65536, 0x42);
      final modified = Uint8List.fromList(basis)
        ..[1024] = 0xFF
        ..[8192] = 0x00;

      _log('Computing signature…');
      final sig = await Librsync.signatureBytes(basis);

      _log('Computing delta…');
      final delta = await Librsync.deltaBytes(sig, modified);

      _log('Applying patch…');
      final reconstructed = await Librsync.patchBytes(basis, delta);

      final ok = _equal(modified, reconstructed);
      _log(
        '${ok ? "✅ PASSED" : "❌ FAILED"} – bytes round-trip\n'
        'sig ${sig.length} B  delta ${delta.length} B  out ${reconstructed.length} B',
      );
    } catch (e, st) {
      _log('❌ $e\n$st');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _runFileDemo() async {
    setState(() => _running = true);
    try {
      _log('Writing 128 KiB test files…');
      final basis = Uint8List(131072)..fillRange(0, 131072, 0xAB);
      final modified = Uint8List.fromList(basis)
        ..[4096]  = 0x01
        ..[32768] = 0x02;

      final basisPath    = await _writeTmp('basis.bin',    basis);
      final modifiedPath = await _writeTmp('modified.bin', modified);
      final sigPath      = '${(await _tmp).path}/basis.sig';
      final deltaPath    = '${(await _tmp).path}/patch.delta';
      final outPath      = '${(await _tmp).path}/reconstructed.bin';

      _log('signatureFile…');
      await Librsync.signatureFile(basisPath, sigPath);

      _log('deltaFile…');
      await Librsync.deltaFile(sigPath, modifiedPath, deltaPath);

      _log('patchFile…');
      await Librsync.patchFile(basisPath, deltaPath, outPath);

      final reconstructed = File(outPath).readAsBytesSync();
      final ok = _equal(modified, reconstructed);
      _log(
        '${ok ? "✅ PASSED" : "❌ FAILED"} – file round-trip\n'
        'sig ${File(sigPath).lengthSync()} B  '
        'delta ${File(deltaPath).lengthSync()} B',
      );
    } catch (e, st) {
      _log('❌ $e\n$st');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _runMixedDemo() async {
    setState(() => _running = true);
    try {
      _log('Running mixed demo…');
      final basis    = Uint8List(32768)..fillRange(0, 32768, 0xCC);
      final modified = Uint8List.fromList(basis)..[512] = 0xFF;

      final basisPath = await _writeTmp('mix_basis.bin', basis);

      _log('signatureFileToBytes…');
      final sig = await Librsync.signatureFileToBytes(basisPath);

      _log('deltaBytes…');
      final delta = await Librsync.deltaBytes(sig, modified);

      _log('patchBytes…');
      final out = await Librsync.patchBytes(basis, delta);

      final ok = _equal(modified, out);
      _log(
        '${ok ? "✅ PASSED" : "❌ FAILED"} – mixed round-trip\n'
        'sig ${sig.length} B  delta ${delta.length} B',
      );
    } catch (e, st) {
      _log('❌ $e\n$st');
    } finally {
      setState(() => _running = false);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_librsync demo')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: _running ? null : _runBytesDemo,
              child: const Text('Bytes: signatureBytes → deltaBytes → patchBytes'),
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: _running ? null : _runFileDemo,
              child: const Text('Files: signatureFile → deltaFile → patchFile'),
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: _running ? null : _runMixedDemo,
              child: const Text('Mixed: signatureFileToBytes + deltaBytes + patchBytes'),
            ),
            const SizedBox(height: 20),
            if (_running) const LinearProgressIndicator(),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  _status,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

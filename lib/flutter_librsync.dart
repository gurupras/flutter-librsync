/// flutter_librsync – rsync signature, delta, and patch for Flutter.
///
/// Wraps [librsync-go](https://github.com/gurupras/librsync-go) via CGO
/// (native) and WebAssembly (web).
///
/// ## Quick start – files
/// ```dart
/// import 'package:flutter_librsync/flutter_librsync.dart';
///
/// // 1. Generate signature for the basis file.
/// await Librsync.signatureFile('basis.bin', 'basis.sig');
///
/// // 2. Compute delta between signature and new file.
/// await Librsync.deltaFile('basis.sig', 'new.bin', 'changes.delta');
///
/// // 3. Apply delta to reconstruct the new file.
/// await Librsync.patchFile('basis.bin', 'changes.delta', 'patched.bin');
/// ```
///
/// ## Quick start – bytes
/// ```dart
/// final sig   = await Librsync.signatureBytes(basisBytes);
/// final delta = await Librsync.deltaBytes(sig, newBytes);
/// final out   = await Librsync.patchBytes(basisBytes, delta);
/// ```
///
/// ## Custom ReadSeeker / Writer
/// Use the `*Sync` methods inside your own isolate for custom stream types:
/// ```dart
/// await Isolate.run(() {
///   Librsync.signatureSync(myReadSeeker, myWriter);
/// });
/// ```
///
/// ## Web
/// On Flutter Web the WASM module must be bootstrapped at app start – see
/// `Librsync.ensureInitialized()` in the web-platform docs.
library;

// Conditional export: selects the native (dart:ffi) implementation on all
// native platforms and the WASM-backed implementation on Flutter Web.
export 'src/librsync_native.dart'
    if (dart.library.js_interop) 'src/librsync_web.dart';

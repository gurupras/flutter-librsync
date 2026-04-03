# flutter_librsync

Flutter FFI plugin wrapping [librsync-go](https://github.com/gurupras/librsync-go).
Provides rsync **signature**, **delta**, and **patch** operations on Android, iOS,
macOS, Linux, Windows, and Flutter Web (via WebAssembly).

The native library is written in Go (CGO) and is built automatically when you
run your Flutter app on each platform. No pre-built binaries need to be
committed to your project.

---

## Table of Contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
  - [Bytes API (simplest)](#bytes-api-simplest)
  - [File API](#file-api)
  - [Sync API (custom streams)](#sync-api-custom-streams)
- [Platform setup](#platform-setup)
  - [Android](#android)
  - [iOS](#ios)
  - [macOS](#macos)
  - [Linux](#linux)
  - [Windows](#windows)
  - [Flutter Web](#flutter-web)
- [API reference](#api-reference)

---

## How it works

librsync computes the difference between two files without having both files in
the same place at once. The workflow is:

```
basis file  ──► signature()  ──► sig bytes   (small, ~1% of basis size)
                                       │
new file ◄──────────────────────────── │
    │                                  │
    └──► delta(sig, new file) ──► delta bytes  (small when files are similar)
                                       │
basis file + delta bytes ──► patch() ──► reconstructed new file
```

1. **Signature** — compute a compact fingerprint of the basis file
2. **Delta** — compute a binary diff between the signature and the new file
3. **Patch** — apply the delta to the basis file to reconstruct the new file

---

## Prerequisites

### All platforms
- Go 1.21+ with CGO enabled (`CGO_ENABLED=1`)
- The Go toolchain must be on your `PATH`

### Android
- Android NDK; set `ANDROID_NDK_HOME` (or `NDK_HOME`) in your environment

### iOS / macOS
- macOS with Xcode and Xcode Command Line Tools installed

### Linux
- `gcc` or `clang`, `make`

### Windows
- `mingw-w64` (`x86_64-w64-mingw32-gcc` on PATH), `make` (e.g. via MSYS2)

### Flutter Web
- No extra tools — the WASM binary is pre-built via `make wasm` and bundled as
  a Flutter asset

---

## Installation

Add the plugin to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_librsync:
    path: /path/to/flutter-librsync   # or a git/pub reference
```

Then run:

```sh
flutter pub get
```

---

## Usage

Import the package:

```dart
import 'package:flutter_librsync/flutter_librsync.dart';
```

### Bytes API (simplest)

All operations run on a background isolate so the UI thread is never blocked.

```dart
import 'dart:typed_data';
import 'package:flutter_librsync/flutter_librsync.dart';

Future<void> example(Uint8List basisBytes, Uint8List newFileBytes) async {
  // 1. Compute a signature for the basis file
  final sig = await Librsync.signatureBytes(basisBytes);

  // 2. Compute a delta between the signature and the new file
  final delta = await Librsync.deltaBytes(sig, newFileBytes);

  // 3. Apply the delta to the basis to reconstruct the new file
  final reconstructed = await Librsync.patchBytes(basisBytes, delta);

  assert(reconstructed.length == newFileBytes.length);
}
```

Optional parameters on `signatureBytes` (and the other signature methods):

| Parameter  | Default          | Description                              |
|------------|------------------|------------------------------------------|
| `blockLen` | `2048`           | Block length for checksums               |
| `strongLen`| `32`             | Strong checksum length in bytes          |
| `sigType`  | `blake2SigMagic` | `blake2SigMagic` (default) or `md4SigMagic` |

### File API

Operates directly on files — does not load the whole file into memory.

```dart
import 'package:flutter_librsync/flutter_librsync.dart';

Future<void> fileExample() async {
  // Paths to files on disk
  const basisPath    = '/data/user/0/com.example/files/basis.bin';
  const newFilePath  = '/data/user/0/com.example/files/new.bin';
  const sigPath      = '/tmp/basis.sig';
  const deltaPath    = '/tmp/changes.delta';
  const outPath      = '/tmp/reconstructed.bin';

  await Librsync.signatureFile(basisPath, sigPath);
  await Librsync.deltaFile(sigPath, newFilePath, deltaPath);
  await Librsync.patchFile(basisPath, deltaPath, outPath);
}
```

Mixed convenience methods:

```dart
// Signature of a file, returned as bytes (useful to send over the network)
final sigBytes = await Librsync.signatureFileToBytes(basisPath);

// Delta from files, returned as bytes
final deltaBytes = await Librsync.deltaFileToBytes(sigPath, newFilePath);
```

### Sync API (custom streams)

For advanced use-cases where you need to provide your own I/O sources or sinks —
for example, streaming from a network socket, a database blob, or an encrypted
stream.

**Do not call sync methods from the UI isolate.** Wrap them in `Isolate.run` or
run them from an existing background isolate.

```dart
import 'dart:isolate';
import 'package:flutter_librsync/flutter_librsync.dart';

Future<Uint8List> signFromCustomSource(MySource src) {
  return Isolate.run(() {
    final input  = MyReadSeeker(src);   // your implementation
    final output = BytesWriter();
    Librsync.signatureSync(input, output);
    return output.takeBytes();
  });
}
```

#### Implementing `ReadSeeker`

```dart
class MyReadSeeker implements ReadSeeker {
  @override
  int readInto(Uint8List buffer) {
    // Fill buffer, return number of bytes read (0 = EOF)
  }

  @override
  int seek(int offset, int whence) {
    // whence: SeekOrigin.start | SeekOrigin.current | SeekOrigin.end
    // Return the new absolute position in bytes
  }

  @override
  void close() { /* release resources */ }
}
```

#### Implementing `Writer`

```dart
class MySink implements Writer {
  @override
  void write(Uint8List data) {
    // data is only valid for the duration of this call — copy if needed
  }

  @override
  void close() { /* flush and release resources */ }
}
```

Built-in implementations:

| Class            | Description                             |
|------------------|-----------------------------------------|
| `BytesReadSeeker`| Reads from an in-memory `Uint8List`     |
| `FileReadSeeker` | Reads from a file; lazy open            |
| `BytesWriter`    | Accumulates output; drain with `takeBytes()` |
| `FileWriter`     | Writes (truncates) a file; lazy open    |

---

## Platform setup

### Android

**Prerequisite:** Android NDK installed. Set the `ANDROID_NDK_HOME` environment
variable (Android Studio usually sets this automatically if you install the NDK
via the SDK Manager).

No changes needed to your app's `build.gradle`. The plugin's Gradle script
invokes `make android` automatically as part of the pre-build step, producing
`.so` files for `arm64-v8a`, `armeabi-v7a`, and `x86_64`.

```sh
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/<version>
flutter run -d <android-device>
```

To build the Android native libraries ahead of time:

```sh
make android
```

---

### iOS

**Prerequisite:** Must run on macOS with Xcode installed.

The CocoaPods podspec runs `make ios` during `pod install`. No manual steps
are needed beyond having Go and the NDK prerequisites:

```sh
cd ios && pod install   # or handled automatically by flutter run
flutter run -d <ios-device>
```

---

### macOS

**Prerequisite:** Must run on macOS with Xcode installed.

The CocoaPods podspec runs `make macos` (builds a universal arm64+amd64
`.dylib`) during `pod install`:

```sh
flutter run -d macos
```

---

### Linux

**Prerequisite:** `gcc` and `make` installed, Go 1.21+ on PATH.

The CMake build file runs `make linux` automatically when the application is
built:

```sh
flutter run -d linux
```

To build the Linux shared library ahead of time:

```sh
make linux
# Produces: prebuilt/linux/libflutter_librsync.so
```

> **Linker note (Ubuntu/Debian with LLVM-18):** Flutter's native asset build
> looks for `ld` or `ld.lld` in the same directory as `clang++`. If your
> `clang++` resolves into `/usr/lib/llvm-18/bin/` but `ld` is only in
> `/usr/bin/`, create a wrapper directory:
>
> ```sh
> mkdir -p .clang-wrapper
> printf '#!/bin/sh\nexec /usr/bin/clang++ "$@"\n' > .clang-wrapper/clang++
> chmod +x .clang-wrapper/clang++
> ln -s /usr/bin/ld .clang-wrapper/ld
> ```
>
> Then run Flutter with `PATH="$(pwd)/.clang-wrapper:$PATH" flutter run -d linux`.

---

### Windows

**Prerequisite:** `mingw-w64` installed and `x86_64-w64-mingw32-gcc` on PATH.
A `make` implementation (e.g. from MSYS2) is also required.

The CMake build file runs `make windows` automatically:

```sh
flutter run -d windows
```

To build the DLL ahead of time:

```sh
make windows
# Produces: prebuilt/windows/flutter_librsync.dll
```

---

### Flutter Web

The Web implementation runs inside a Go-compiled WebAssembly module bundled as
a Flutter asset.

#### 1. Build the WASM binary

```sh
make wasm
# Produces: web/librsync.wasm, web/wasm_exec.js
```

#### 2. Bootstrap the module in `web/index.html`

Add the following to the `<head>` section of your app's `web/index.html`,
**before** the Flutter bootstrap script:

```html
<script src="assets/packages/flutter_librsync/web/wasm_exec.js"></script>
<script>
  const go = new Go();
  WebAssembly.instantiateStreaming(
    fetch('assets/packages/flutter_librsync/web/librsync.wasm'),
    go.importObject,
  ).then(r => go.run(r.instance));
</script>
```

#### 3. Wait for initialisation

Call `ensureInitialized()` once before the first operation, typically in
`main()` or on the first screen that uses librsync:

```dart
await Librsync.ensureInitialized();
```

#### Web streaming API

On Web, in addition to the bytes API, you can feed data in chunks:

```dart
// Signature
final stream = Librsync.beginSignature();
stream.write(chunk1);
stream.write(chunk2);
final sig = stream.finish();

// Delta
final ds = Librsync.beginDelta(sig);
ds.write(newDataChunk1);
ds.write(newDataChunk2);
final delta = ds.finish();

// Patch
final ps = Librsync.beginPatch(basisBytes);
ps.write(deltaChunk1);
final result = ps.finish();
```

---

## API reference

### `Librsync` (static methods)

| Method | Platforms | Description |
|--------|-----------|-------------|
| `signatureBytes(input, ...)` | all | Signature of a `Uint8List` → `Uint8List` |
| `deltaBytes(sig, newFile)` | all | Delta between sig bytes and new file bytes |
| `patchBytes(base, delta)` | all | Apply delta to base bytes |
| `signatureFile(in, out, ...)` | native | Signature file → file |
| `deltaFile(sig, new, out)` | native | Delta file → file |
| `patchFile(base, delta, out)` | native | Patch file → file |
| `signatureFileToBytes(path, ...)` | native | Signature file → bytes |
| `deltaFileToBytes(sig, new)` | native | Delta files → bytes |
| `signatureSync(in, out, ...)` | all | Synchronous; call from a background isolate |
| `deltaSync(sig, new, out)` | all | Synchronous |
| `patchSync(base, delta, out)` | all | Synchronous |
| `ensureInitialized()` | web only | Wait for WASM module to load |
| `beginSignature(...)` | web only | Chunked streaming signature |
| `beginDelta(sig)` | web only | Chunked streaming delta |
| `beginPatch(base)` | web only | Chunked streaming patch |

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `blake2SigMagic` | `0x72730137` | BLAKE2 signature type (default) |
| `md4SigMagic` | `0x72730136` | MD4 signature type (legacy) |

### `SeekOrigin`

| Constant | Value | Description |
|----------|-------|-------------|
| `SeekOrigin.start` | `0` | From beginning of stream |
| `SeekOrigin.current` | `1` | From current position |
| `SeekOrigin.end` | `2` | From end of stream |

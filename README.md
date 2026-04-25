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
  - [Streaming sync (sender / receiver)](#streaming-sync-sender--receiver)
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

---

### Streaming sync (sender / receiver)

This is the primary API for syncing files between two devices. Delta chunks are
produced and consumed incrementally — neither the new file nor the base file is
ever fully loaded into memory. Suitable for files of any size.

**All streaming methods are synchronous and must be called from a background
isolate** — wrap your entire send or receive loop in `Isolate.run` or use an
existing worker isolate.

#### Overview

```
RECEIVER                                  SENDER
────────                                  ──────
1. generate signature of basis file
2. send signature ──────────────────────► receive signature
                                          3. generate delta chunks from new file
                    ◄────────────────────  4. stream delta chunks
5. receive delta chunks
6. apply delta to basis → new file
7. atomically replace basis with new file
```

---

#### Step 1 — Receiver: generate and send signature

The receiver generates a compact signature (~1% of file size) of their current
version of the file and sends it to the sender.

```dart
import 'dart:isolate';
import 'package:flutter_librsync/flutter_librsync.dart';

Future<Uint8List> generateSignature(String basePath) {
  return Isolate.run(() {
    final builder = BytesBuilder(copy: false);
    final stream = SignatureStream();
    final file = File(basePath).openSync();
    final buf = Uint8List(defaultChunkSize);
    try {
      while (true) {
        final n = file.readIntoSync(buf);
        if (n == 0) break;
        final out = stream.feed(buf.sublist(0, n));
        if (out.isNotEmpty) builder.add(out);
      }
      builder.add(stream.end());
    } catch (_) {
      stream.close();
      rethrow;
    } finally {
      file.closeSync();
    }
    return builder.takeBytes();
  });
}
```

Send `sigBytes` to the sender via your network transport.

**Zero-copy variant** — if your isolate manages its own C-heap buffer pool, use
`feedPtr` to skip the internal copy:

```dart
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

// allocate a reusable pool buffer once
final buf = calloc<ffi.Uint8>(defaultChunkSize);
try {
  while (true) {
    final n = file.readIntoSync(buf.asTypedList(defaultChunkSize));
    if (n == 0) break;
    final out = stream.feedPtr(buf, n);  // no copy into Go
    if (out.isNotEmpty) builder.add(out);
  }
} finally {
  calloc.free(buf);
}
```

---

#### Step 2 — Sender: stream delta chunks

The sender receives the signature, opens the new file sequentially, and streams
delta chunks to the receiver as they are produced.

```dart
import 'dart:isolate';
import 'package:flutter_librsync/flutter_librsync.dart';

// sendChunk is your network transport callback — called for each delta chunk.
Future<void> streamDelta(
  Uint8List sigBytes,
  String newFilePath,
  void Function(Uint8List chunk) sendChunk,
) {
  return Isolate.run(() {
    final sig = SigHandle.fromBytes(sigBytes);
    final stream = DeltaStream(sig);
    final file = File(newFilePath).openSync();
    final buf = Uint8List(defaultChunkSize);
    try {
      while (true) {
        final n = file.readIntoSync(buf);
        if (n == 0) break;
        final out = stream.feed(buf.sublist(0, n));
        if (out.isNotEmpty) sendChunk(out);
      }
      final tail = stream.end();
      if (tail.isNotEmpty) sendChunk(tail);
    } catch (_) {
      stream.close();
      rethrow;
    } finally {
      file.closeSync();
      sig.close();
    }
  });
}
```

The new file is read sequentially in `defaultChunkSize` (256 KB) chunks. Delta
output may be empty for many chunks — the library buffers literals internally
until a flush threshold is reached. All remaining output is flushed on `end()`.

**Zero-copy variant** — use `feedPtr` with a pool buffer (same pattern as
signature above, substituting `DeltaStream`).

> **Content URIs (Android) / security-scoped URLs (iOS):** Only the sender
> needs to read the new file, and it only needs sequential access. Open the
> content URI via your platform's file-picker or share-intent APIs to obtain a
> `Stream<List<int>>` or `RandomAccessFile`, read it chunk by chunk, and feed
> each chunk to `DeltaStream.feed`. No path is required — sequential read is
> sufficient.

---

#### Step 3 — Receiver: apply delta to basis file

The receiver applies incoming delta chunks to their local basis file to
reconstruct the new file. The basis file is accessed via `pread` — it is never
loaded into memory. Output chunks are written to a temporary file and atomically
renamed when complete.

```dart
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_librsync/flutter_librsync.dart';

// Call this in a background isolate.
// deltaChunks is an Iterable/Stream of Uint8List received from the sender.
void applyDelta(
  String basePath,
  Iterable<Uint8List> deltaChunks,
  String destinationPath,
) {
  final tmpPath = '$destinationPath.tmp';
  final tmpFile = File(tmpPath).openSync(mode: FileMode.write);
  final stream = PatchStream.fromPath(basePath);
  try {
    for (final chunk in deltaChunks) {
      final out = stream.feed(chunk);
      if (out.isNotEmpty) tmpFile.writeFromSync(out);
    }
    final tail = stream.end();
    if (tail.isNotEmpty) tmpFile.writeFromSync(tail);
    tmpFile.closeSync();
    // Atomic replace — only visible to readers once complete.
    File(tmpPath).renameSync(destinationPath);
  } catch (_) {
    stream.close();
    tmpFile.closeSync();
    try { File(tmpPath).deleteSync(); } catch (_) {}
    rethrow;
  }
}
```

`PatchStream.fromPath` opens the basis file in Go and uses `pread` (POSIX) or
overlapped I/O (Windows) for random access. The basis file is never loaded into
memory regardless of size.

The temporary file plus atomic rename ensures the destination is never left in
a partially-written state if the process is interrupted.

---

#### Complete end-to-end example

```
Device A (sender)                         Device B (receiver)
─────────────────                         ────────────────────
                    ◄── sigBytes ──────── generateSignature(basePath)
streamDelta(sigBytes, newFilePath,
  sendChunk: network.send)
  ──── delta chunks ────────────────────► applyDelta(basePath,
                                            incomingChunks,
                                            destinationPath)
```

---

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

---

### File API

Operates directly on files — does not load the whole file into memory.

```dart
import 'package:flutter_librsync/flutter_librsync.dart';

Future<void> fileExample() async {
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

---

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

### Streaming classes (native only)

| Class | Description |
|-------|-------------|
| `SignatureStream` | Streaming signature session. Feed chunks via `feed()`/`feedPtr()`, finalise with `end()`. |
| `DeltaStream` | Streaming delta session. Requires a `SigHandle`. Feed new-file chunks via `feed()`/`feedPtr()`, finalise with `end()`. |
| `PatchStream.fromPath(path)` | Patch session backed by a file on disk. Go holds the file open and uses `pread` — no memory pressure regardless of file size. |
| `PatchStream.fromBytes(base)` | Patch session backed by an in-memory buffer. Suitable for small base data. |
| `PatchStream.fromFile(raf)` | Patch session backed by an open `RandomAccessFile`. Reads the file into memory at construction. |
| `SigHandle` | Parsed signature ready for use by one or more `DeltaStream` sessions. |

#### `feedPtr` (zero-copy)

Both `SignatureStream` and `DeltaStream` expose a `feedPtr` method for callers
that manage their own C-heap buffer pool:

```dart
Uint8List feedPtr(ffi.Pointer<ffi.Uint8> ptr, int length)
```

The pointer must remain valid and unmodified until the call returns. The caller
retains ownership — the library never frees it. Use `dart:ffi` and
`package:ffi` to allocate and manage the pool.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `blake2SigMagic` | `0x72730137` | BLAKE2 signature type (default) |
| `md4SigMagic` | `0x72730136` | MD4 signature type (legacy) |
| `defaultChunkSize` | `262144` | Default read buffer size (256 KB) |

### `SeekOrigin`

| Constant | Value | Description |
|----------|-------|-------------|
| `SeekOrigin.start` | `0` | From beginning of stream |
| `SeekOrigin.current` | `1` | From current position |
| `SeekOrigin.end` | `2` | From end of stream |

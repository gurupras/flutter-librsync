# Claude Instructions

## Git commits
- Do NOT add `Co-Authored-By: Claude` (or any Claude/Anthropic attribution) to commit messages.
- Do NOT set `-c user.name` or `-c user.email` when running `git commit`. Use the repository's existing git config as-is.

---

# Project Overview

**flutter_librsync** is a Flutter FFI plugin that wraps [librsync-go](https://github.com/gurupras/librsync-go) (a Go implementation of the rsync algorithm) to provide signature, delta, and patch operations in Flutter apps.

- **Version:** 0.1.0
- **Supported platforms:** Android, iOS, macOS, Linux, Windows (via CGO-compiled shared library), and Flutter Web (via WebAssembly)
- **Dart SDK:** `^3.10.4` / Flutter `>=3.3.0`

The three rsync operations are:
1. **Signature** – fingerprint a basis file into a compact signature
2. **Delta** – diff a signature against a new file to produce a delta
3. **Patch** – apply a delta to the basis file to reconstruct the new file

---

# Architecture

## Native (non-web) path

```
lib/flutter_librsync.dart          ← conditional export entry point
lib/src/librsync_native.dart       ← public Librsync class (async + sync API)
lib/src/ffi/bindings.dart          ← dart:ffi bindings, C struct mirrors, NativeCallables
lib/src/implementations.dart       ← FileReadSeeker, BytesReadSeeker, FileWriter, BytesWriter
lib/src/interfaces.dart            ← ReadSeeker, Writer, SeekOrigin abstract interfaces
```

The native shared library (`libflutter_librsync.so` / `.dylib` / `.dll`) is a CGO build of librsync-go. It exposes three C functions:
- `librsync_signature(reader, writer, blockLen, strongLen, sigType) → *char (error)`
- `librsync_delta(sigReader, newDataReader, writer) → *char (error)`
- `librsync_patch(baseReadSeeker, deltaReader, writer) → *char (error)`
- `librsync_free_string(ptr)` – frees error strings returned by the above

The C structs (`RsReader`, `RsWriter`, `RsReadSeeker`) are allocated with `calloc`, populated with `NativeCallable.isolateLocal()` function pointers, passed to the C functions, and freed in `finally` blocks. Errors are returned as `*char` (null = success).

**Note on `patch`:** Only `patch` needs a `ReadSeeker` (seekable) for the base file. `signature` and `delta` only need a plain `Reader` (sequential).

## Web path

```
lib/src/librsync_web.dart          ← selected by dart.library.js_interop conditional export
web/librsync.wasm                  ← compiled Go WASM module
web/wasm_exec.js                   ← Go WASM runtime bootstrap script
```

The web implementation uses `dart:js_interop` to call into a `window.librsync` global object exposed by the WASM module. The host app's `web/index.html` must load both scripts and run the Go instance before calling any API. Call `await Librsync.ensureInitialized()` at app startup (polls every 50 ms, times out after 10 s by default).

The web `Librsync` class has an additional streaming API (`beginSignature`, `beginDelta`, `beginPatch`) that returns `WebSignatureStream` / `WebDeltaStream` / `WebPatchStream` objects for chunked input.

---

# Public API

All API lives in the `Librsync` abstract final class (same name, different impl per platform).

## Async methods (native only – not available on web)

| Method | Description |
|---|---|
| `signatureFile(inputPath, outputPath, {blockLen, strongLen, sigType})` | File → file |
| `deltaFile(sigPath, newFilePath, outputPath)` | File → file |
| `patchFile(basePath, deltaPath, outputPath)` | File → file |
| `signatureBytes(input, {blockLen, strongLen, sigType})` | `Uint8List → Uint8List` |
| `deltaBytes(sigBytes, newFileBytes)` | `Uint8List → Uint8List` |
| `patchBytes(baseBytes, deltaBytes)` | `Uint8List → Uint8List` |
| `signatureFileToBytes(inputPath, ...)` | File → `Uint8List` |
| `deltaFileToBytes(sigPath, newFilePath)` | Files → `Uint8List` |

All async methods internally wrap their work in `Isolate.run(...)` so the UI thread is never blocked.

## Sync methods (native + web)

| Method | Notes |
|---|---|
| `signatureSync(input, output, {blockLen, strongLen, sigType})` | Blocks; use inside your own isolate |
| `deltaSync(sigInput, newData, output)` | Blocks |
| `patchSync(base, delta, output)` | Blocks |

**Do not call sync methods from the main/UI isolate.**

## Constants

- `blake2SigMagic = 0x72730137` (default, preferred)
- `md4SigMagic = 0x72730136` (legacy)

## Exception

`LibrsyncException` – thrown when a native call returns a non-null error string.

---

# ReadSeeker / Writer interfaces

Custom implementations must be synchronous (no async I/O). When passed inside `Isolate.run(...)`, the closure is sent across the isolate boundary, so all captured state must be transferable (strings, ints, `Uint8List`).

**Built-in implementations:**

| Class | Backed by | Isolate-transferable? |
|---|---|---|
| `BytesReadSeeker` | `Uint8List` in memory | Yes – only holds bytes + int position |
| `FileReadSeeker` | File on disk (lazy open) | Yes – only holds a path `String`; file is opened on first use inside the worker isolate |
| `BytesWriter` | `BytesBuilder` in memory | Yes |
| `FileWriter` | File on disk (lazy open) | Yes – only holds a path `String` |

`SeekOrigin.start = 0`, `SeekOrigin.current = 1`, `SeekOrigin.end = 2`.

---

# Isolate compatibility

The library is fully isolate-safe (pure FFI, no platform channels):

- Async methods manage their own `Isolate.run(...)` internally.
- Sync methods are the building blocks for custom isolate usage.
- `NativeCallable.isolateLocal()` ensures FFI callbacks are bound to the worker isolate that runs the operation.
- `FileReadSeeker` and `FileWriter` open files lazily, so they can be constructed on one isolate and first used on another.

---

# Testing

**Unit tests** (pure Dart, no native library):
```
test/implementations_test.dart
```
Tests `BytesReadSeeker`, `BytesWriter`, `FileReadSeeker`, `FileWriter` in isolation.

**Integration tests** (require native library, run on a device/desktop):
```
example/integration_test/librsync_test.dart
```
Run with:
```
flutter test integration_test/librsync_test.dart -d linux
```
Covers bytes round-trips, file round-trips, and the sync API.

---

# FFI code generation

`ffigen.yaml` is present but the bindings in `lib/src/ffi/bindings.dart` are hand-written (not generated). The `ffigen.yaml` references `src/flutter_librsync.h` and outputs to `lib/flutter_librsync_bindings_generated.dart`. If the C header changes, regenerate with:
```
dart run ffigen --config ffigen.yaml
```

---

# Native build

The native library is built via CMake (`src/CMakeLists.txt`). The Flutter plugin build system invokes CMake automatically when building for Android/iOS/macOS/Linux/Windows. No manual build step is needed for normal development.

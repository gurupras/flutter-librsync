import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'interfaces.dart';

// ─── ReadSeeker implementations ───────────────────────────────────────────────

/// A [ReadSeeker] backed by a file on disk.
///
/// The file is opened lazily on first use so that a [FileReadSeeker] can be
/// constructed on one isolate and first used on another (only the [path]
/// string is serialised when the containing closure is sent to [Isolate.run]).
class FileReadSeeker implements ReadSeeker {
  /// Absolute path to the file.
  final String path;

  RandomAccessFile? _raf;

  FileReadSeeker(this.path);

  RandomAccessFile get _file {
    return _raf ??= File(path).openSync();
  }

  @override
  int readInto(Uint8List buffer) {
    return _file.readIntoSync(buffer);
  }

  @override
  int seek(int offset, int whence) {
    final int newPos;
    switch (whence) {
      case SeekOrigin.start:
        newPos = offset;
      case SeekOrigin.current:
        newPos = _file.positionSync() + offset;
      case SeekOrigin.end:
        newPos = _file.lengthSync() + offset;
      default:
        throw ArgumentError.value(whence, 'whence', 'Invalid seek origin');
    }
    if (newPos < 0) {
      throw RangeError.range(newPos, 0, null, 'offset', 'seek past beginning of file');
    }
    _file.setPositionSync(newPos);
    return newPos;
  }

  @override
  void close() {
    _raf?.closeSync();
    _raf = null;
  }
}

/// A [ReadSeeker] backed by an in-memory [Uint8List].
///
/// All fields are primitive or typed-data, so this class is fully
/// transferable across isolates.
class BytesReadSeeker implements ReadSeeker {
  /// The underlying bytes.  Exposed so that async API helpers can extract
  /// the data before sending it across an [Isolate.run] boundary.
  final Uint8List bytes;
  int _position = 0;

  /// The unread portion of [bytes] from the current position to the end.
  ///
  /// Returns [bytes] directly (no copy) when position is 0.
  Uint8List get remainingBytes =>
      _position == 0 ? bytes : bytes.sublist(_position);

  BytesReadSeeker(this.bytes);

  @override
  int readInto(Uint8List buffer) {
    final available = bytes.length - _position;
    if (available == 0) return 0; // EOF
    final n = min(buffer.length, available);
    buffer.setRange(0, n, bytes, _position);
    _position += n;
    return n;
  }

  @override
  int seek(int offset, int whence) {
    final int newPos;
    switch (whence) {
      case SeekOrigin.start:
        newPos = offset;
      case SeekOrigin.current:
        newPos = _position + offset;
      case SeekOrigin.end:
        newPos = bytes.length + offset;
      default:
        throw ArgumentError.value(whence, 'whence', 'Invalid seek origin');
    }
    if (newPos < 0) {
      throw RangeError.range(newPos, 0, null, 'offset', 'seek past beginning of file');
    }
    _position = newPos.clamp(0, bytes.length);
    return _position;
  }

  @override
  void close() {} // nothing to release
}

// ─── Writer implementations ───────────────────────────────────────────────────

/// A [Writer] that appends all bytes into an in-memory [BytesBuilder].
///
/// After the operation completes, retrieve the result with [takeBytes].
class BytesWriter implements Writer {
  final BytesBuilder _builder = BytesBuilder();

  /// Returns all accumulated bytes and resets the internal buffer.
  Uint8List takeBytes() => _builder.takeBytes();

  @override
  void write(Uint8List data) => _builder.add(data);

  @override
  void close() {}
}

/// A [Writer] that writes all bytes to a file on disk.
///
/// The file is opened (truncated) lazily on first use.
class FileWriter implements Writer {
  /// Absolute path to the output file.
  final String path;

  RandomAccessFile? _raf;

  FileWriter(this.path);

  RandomAccessFile get _file {
    return _raf ??= File(path).openSync(mode: FileMode.write);
  }

  @override
  void write(Uint8List data) => _file.writeFromSync(data);

  @override
  void close() {
    _raf?.closeSync();
    _raf = null;
  }
}

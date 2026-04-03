import 'dart:typed_data';

/// Seek origin constants matching POSIX and Go's io package.
abstract final class SeekOrigin {
  /// Seek from the beginning of the stream.
  static const int start = 0;

  /// Seek relative to the current position.
  static const int current = 1;

  /// Seek relative to the end of the stream.
  static const int end = 2;
}

/// A synchronous, seekable data source.
///
/// Implementations must be synchronous – do not use async I/O internally.
/// For file-backed sources, use [FileReadSeeker].
/// For in-memory data, use [BytesReadSeeker].
///
/// When an operation runs inside [Isolate.run] the implementation is
/// transferred to the worker isolate.  Make sure any state you capture
/// consists only of transferable values (strings, integers, typed-data).
abstract interface class ReadSeeker {
  /// Reads up to [buffer.length] bytes into [buffer].
  ///
  /// Returns the number of bytes actually read.
  /// Returns 0 to signal end-of-stream.
  int readInto(Uint8List buffer);

  /// Moves the read cursor.
  ///
  /// [offset] is interpreted relative to [whence] (a [SeekOrigin] constant).
  /// Returns the new absolute position in bytes.
  int seek(int offset, int whence);

  /// Releases any underlying resources.
  void close();
}

/// A synchronous data sink.
///
/// The [data] slice passed to [write] is only valid for the duration of the
/// call.  Copy it if you need to retain it after [write] returns.
abstract interface class Writer {
  /// Writes all bytes in [data].
  void write(Uint8List data);

  /// Flushes and releases any underlying resources.
  void close();
}

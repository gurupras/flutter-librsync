// Unit tests for ReadSeeker and Writer implementations.
// These run without any native library (pure Dart).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_librsync/flutter_librsync.dart';

void main() {
  group('BytesReadSeeker', () {
    test('reads all bytes sequentially', () {
      final data = Uint8List.fromList(List.generate(256, (i) => i));
      final rs = BytesReadSeeker(data);
      final buf = Uint8List(64);

      int total = 0;
      while (true) {
        final n = rs.readInto(buf);
        if (n == 0) break;
        for (var i = 0; i < n; i++) {
          expect(buf[i], equals(data[total + i]));
        }
        total += n;
      }
      expect(total, equals(256));
    });

    test('returns 0 at EOF', () {
      final rs = BytesReadSeeker(Uint8List(0));
      final buf = Uint8List(16);
      expect(rs.readInto(buf), equals(0));
    });

    test('seek from start', () {
      final data = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
      final rs = BytesReadSeeker(data);
      rs.seek(4, SeekOrigin.start);
      final buf = Uint8List(4);
      final n = rs.readInto(buf);
      expect(n, equals(4));
      expect(buf, equals([4, 5, 6, 7]));
    });

    test('seek from current', () {
      final data = Uint8List.fromList([10, 20, 30, 40, 50]);
      final rs = BytesReadSeeker(data);
      rs.readInto(Uint8List(2)); // advance by 2
      rs.seek(1, SeekOrigin.current); // skip 1 more
      final buf = Uint8List(1);
      rs.readInto(buf);
      expect(buf[0], equals(40));
    });

    test('seek from end', () {
      final data = Uint8List.fromList([0, 1, 2, 3, 4]);
      final rs = BytesReadSeeker(data);
      rs.seek(-2, SeekOrigin.end); // 2 bytes before end
      final buf = Uint8List(2);
      rs.readInto(buf);
      expect(buf, equals([3, 4]));
    });

    test('bytes field is accessible for isolate transfer', () {
      final data = Uint8List.fromList([1, 2, 3]);
      final rs = BytesReadSeeker(data);
      expect(rs.bytes, equals(data));
    });
  });

  group('BytesWriter', () {
    test('accumulates written data', () {
      final w = BytesWriter();
      w.write(Uint8List.fromList([1, 2, 3]));
      w.write(Uint8List.fromList([4, 5, 6]));
      expect(w.takeBytes(), equals([1, 2, 3, 4, 5, 6]));
    });

    test('takeBytes resets buffer', () {
      final w = BytesWriter();
      w.write(Uint8List.fromList([1, 2]));
      w.takeBytes(); // drain
      w.write(Uint8List.fromList([9]));
      expect(w.takeBytes(), equals([9]));
    });
  });

  group('FileReadSeeker', () {
    late File tmpFile;

    setUp(() {
      tmpFile = File('${Directory.systemTemp.path}/frs_test_${DateTime.now().microsecondsSinceEpoch}.bin');
      tmpFile.writeAsBytesSync(Uint8List.fromList(List.generate(100, (i) => i)));
    });

    tearDown(() => tmpFile.deleteSync(recursive: true));

    test('reads file sequentially', () {
      final rs = FileReadSeeker(tmpFile.path);
      final buf = Uint8List(100);
      final n = rs.readInto(buf);
      expect(n, equals(100));
      for (var i = 0; i < 100; i++) {
        expect(buf[i], equals(i));
      }
      rs.close();
    });

    test('seek and read', () {
      final rs = FileReadSeeker(tmpFile.path);
      rs.seek(50, SeekOrigin.start);
      final buf = Uint8List(10);
      rs.readInto(buf);
      expect(buf, equals(List.generate(10, (i) => 50 + i)));
      rs.close();
    });
  });

  group('FileWriter', () {
    late File tmpFile;

    setUp(() {
      tmpFile = File('${Directory.systemTemp.path}/fw_test_${DateTime.now().microsecondsSinceEpoch}.bin');
    });

    tearDown(() { if (tmpFile.existsSync()) tmpFile.deleteSync(); });

    test('writes data to file', () {
      final w = FileWriter(tmpFile.path);
      w.write(Uint8List.fromList([10, 20, 30]));
      w.write(Uint8List.fromList([40, 50]));
      w.close();
      expect(tmpFile.readAsBytesSync(), equals([10, 20, 30, 40, 50]));
    });
  });
}

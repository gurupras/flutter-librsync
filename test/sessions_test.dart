import 'package:flutter_librsync/src/sessions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RsyncBuffer', () {
    test('allocates the requested capacity', () {
      final buf = RsyncBuffer(1024);
      try {
        expect(buf.capacity, 1024);
        expect(buf.view.length, 1024);
      } finally {
        buf.dispose();
      }
    });

    test('view writes are observable through the same view', () {
      final buf = RsyncBuffer(64);
      try {
        for (var i = 0; i < 64; i++) {
          buf.view[i] = i;
        }
        for (var i = 0; i < 64; i++) {
          expect(buf.view[i], i);
        }
      } finally {
        buf.dispose();
      }
    });

    test('dispose is idempotent', () {
      final buf = RsyncBuffer(16);
      buf.dispose();
      buf.dispose(); // must not crash
    });

    test('view throws after dispose', () {
      final buf = RsyncBuffer(16);
      buf.dispose();
      expect(() => buf.view, throwsStateError);
      expect(() => buf.ptr, throwsStateError);
    });

    test('rejects non-positive capacities', () {
      expect(() => RsyncBuffer(0), throwsArgumentError);
      expect(() => RsyncBuffer(-1), throwsArgumentError);
    });
  });
}

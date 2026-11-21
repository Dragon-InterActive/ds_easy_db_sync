import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncCodec time', () {
    test('keeps microseconds, so an unchanged remote anchor compares equal',
        () {
      final at = DateTime.utc(2026, 6, 1, 12, 0, 0, 123, 456);
      final encoded = SyncCodec.encodeTime(at);

      expect(encoded, isA<int>());
      expect(SyncCodec.decodeTime(encoded), at);

      final anchor = RemoteAnchor(updatedAt: at);
      expect(
        SyncCodec.decodeAnchor(SyncCodec.encodeAnchor(anchor)),
        anchor,
      );
    });

    test('still reads the millisecond values earlier versions stored', () {
      final at = DateTime.utc(2026, 6, 1, 12, 0, 0, 123);

      expect(SyncCodec.decodeTime(at.millisecondsSinceEpoch), at);
    });

    test('reads an early-1970s microsecond value as microseconds', () {
      final at = DateTime.utc(1974);

      expect(SyncCodec.decodeTime(at.microsecondsSinceEpoch), at);
    });
  });
}

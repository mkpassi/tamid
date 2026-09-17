import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamid/data/local/database.dart';

import '../support/fakes.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(
      clock: FakeClock(DateTime(2026, 9, 16, 9)),
      ids: SequentialIdGenerator(),
      executor: NativeDatabase.memory(),
    );
  });

  tearDown(() async => db.close());

  test('opens at schema version 1', () async {
    // The migration harness, exercised from version one onwards.
    await db.deviceId();
    expect(db.schemaVersion, 1);
  });

  test('mark twice for the same date updates rather than inserting', () async {
    await db.mark(localDate: '2026-09-16', status: statusAttended);
    await db.mark(localDate: '2026-09-16', status: statusSkipped);

    final rows = await db.watchRecent().first;
    expect(rows, hasLength(1));
    expect(rows.single.status, statusSkipped);
    expect(rows.single.localDate, '2026-09-16');
  });

  test('different dates are separate rows', () async {
    await db.mark(localDate: '2026-09-15', status: statusAttended);
    await db.mark(localDate: '2026-09-16', status: statusSkipped);

    final rows = await db.watchRecent().first;
    expect(rows, hasLength(2));
    // Most recent first.
    expect(rows.first.localDate, '2026-09-16');
  });

  test('deviceId is generated once and then stable', () async {
    final first = await db.deviceId();
    final second = await db.deviceId();
    expect(first, second);
    expect(first, isNotEmpty);
  });
}

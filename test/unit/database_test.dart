import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamid/data/local/database.dart';

import '../support/fakes.dart';

AppDatabase buildDb({FakeClock? clock}) => AppDatabase(
  clock: clock ?? FakeClock(DateTime(2026, 9, 16, 9)),
  ids: SequentialIdGenerator(),
  executor: NativeDatabase.memory(),
);

void main() {
  test('mark twice for the same date updates rather than inserting', () async {
    final db = buildDb();
    addTearDown(db.close);

    await db.mark(localDate: '2026-09-16', status: statusAttended);
    await db.mark(localDate: '2026-09-16', status: statusSkipped);

    final rows = await db.watchRecent().first;
    expect(rows, hasLength(1));
    expect(rows.single.status, statusSkipped);
  });

  test('mark rejects a date after today', () async {
    final db = buildDb();
    addTearDown(db.close);

    expect(
      () => db.mark(localDate: '2026-09-17', status: statusAttended),
      throwsA(isA<InvalidAttendanceDate>()),
    );
  });

  test('mark enforces the 30-day backfill window', () async {
    final db = buildDb(); // today is 2026-09-16
    addTearDown(db.close);

    // 31 days back — outside.
    expect(
      () => db.mark(localDate: '2026-08-16', status: statusAttended),
      throwsA(isA<InvalidAttendanceDate>()),
    );

    // 29 days back — inside.
    await db.mark(localDate: '2026-08-18', status: statusAttended);
    final rows = await db.watchRecent().first;
    expect(rows.single.localDate, '2026-08-18');
  });

  test('a backfilled day stores the offset for that date, not today', () async {
    // A timezone that gains an hour on 8 March: 60 before, 120 from then on.
    // Expressed explicitly so the assertion does not depend on the host zone.
    final clock = FakeClock(
      DateTime(2026, 3, 20, 9),
      offsetRule: (moment) =>
          moment.isBefore(DateTime(2026, 3, 8, 4)) ? 60 : 120,
    );
    final db = buildDb(clock: clock);
    addTearDown(db.close);

    await db.mark(localDate: '2026-03-05', status: statusAttended);

    final rows = await db.watchRecent().first;
    expect(rows.single.tzOffsetMin, 60, reason: "today's offset is 120");
  });

  test('a cleared day can be answered again and leaves one live row', () async {
    final db = buildDb();
    addTearDown(db.close);

    await db.mark(localDate: '2026-09-16', status: statusAttended);
    await db.clearDay('2026-09-16');
    expect(await db.watchRecent().first, isEmpty);

    // The tombstoned row is exempt from the partial unique index, so this
    // must insert cleanly rather than hit a constraint violation.
    await db.mark(localDate: '2026-09-16', status: statusSkipped);

    final live = await db.watchRecent().first;
    expect(live, hasLength(1));
    expect(live.single.status, statusSkipped);
  });
}

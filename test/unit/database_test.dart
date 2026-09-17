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

    await db.mark(localDate: '2026-09-16', status: AttendanceStatus.attended);
    await db.mark(localDate: '2026-09-16', status: AttendanceStatus.skipped);

    final rows = await db.watchRecent().first;
    expect(rows, hasLength(1));
    expect(rows.single.status, AttendanceStatus.skipped);
  });

  test('mark rejects a date after today', () async {
    final db = buildDb();
    addTearDown(db.close);

    expect(
      () => db.mark(localDate: '2026-09-17', status: AttendanceStatus.attended),
      throwsA(isA<InvalidAttendanceDate>()),
    );
  });

  test('mark enforces the 30-day backfill window', () async {
    final db = buildDb(); // today is 2026-09-16
    addTearDown(db.close);

    // 31 days back — outside.
    expect(
      () => db.mark(localDate: '2026-08-16', status: AttendanceStatus.attended),
      throwsA(isA<InvalidAttendanceDate>()),
    );

    // 29 days back — inside.
    await db.mark(localDate: '2026-08-18', status: AttendanceStatus.attended);
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

    await db.mark(localDate: '2026-03-05', status: AttendanceStatus.attended);

    final rows = await db.watchRecent().first;
    expect(rows.single.tzOffsetMin, 60, reason: "today's offset is 120");
  });

  test('a cleared day can be answered again and leaves one live row', () async {
    final db = buildDb();
    addTearDown(db.close);

    await db.mark(localDate: '2026-09-16', status: AttendanceStatus.attended);
    await db.clearDay('2026-09-16');
    expect(await db.watchRecent().first, isEmpty);

    // The tombstoned row is exempt from the partial unique index, so this
    // must insert cleanly rather than hit a constraint violation.
    await db.mark(localDate: '2026-09-16', status: AttendanceStatus.skipped);

    final live = await db.watchRecent().first;
    expect(live, hasLength(1));
    expect(live.single.status, AttendanceStatus.skipped);
  });

  test('a whitespace-only note is stored as null', () async {
    final db = buildDb();
    addTearDown(db.close);

    await db.setNote(localDate: '2026-09-16', note: '   \n  ');

    final rows = await db.watchRecent().first;
    expect(rows.single.note, isNull);
    expect(rows.single.isAnswered, isFalse, reason: 'note without an answer');
  });

  test('note and status are independent of each other', () async {
    final db = buildDb();
    addTearDown(db.close);

    await db.mark(localDate: '2026-09-16', status: AttendanceStatus.attended);
    await db.setNote(localDate: '2026-09-16', note: 'shoulder felt off');
    expect((await db.watchRecent().first).single.status,
        AttendanceStatus.attended);

    // Changing the status must not wipe the note.
    await db.mark(localDate: '2026-09-16', status: AttendanceStatus.skipped);

    final row = (await db.watchRecent().first).single;
    expect(row.status, AttendanceStatus.skipped);
    expect(row.note, 'shoulder felt off');
  });

  test('clearing a day does not resurrect its note', () async {
    final db = buildDb();
    addTearDown(db.close);

    await db.mark(localDate: '2026-09-16', status: AttendanceStatus.attended);
    await db.setNote(localDate: '2026-09-16', note: 'good session');
    await db.clearDay('2026-09-16');

    // Clear means "this day has no record"; a note surviving it would surprise.
    await db.mark(localDate: '2026-09-16', status: AttendanceStatus.attended);

    final rows = await db.watchRecent().first;
    expect(rows, hasLength(1));
    expect(rows.single.note, isNull);
  });

  test('mark refuses to write unanswered', () async {
    final db = buildDb();
    addTearDown(db.close);

    expect(
      () => db.mark(
        localDate: '2026-09-16',
        status: AttendanceStatus.unanswered,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('an over-long note is rejected, not truncated', () async {
    final db = buildDb();
    addTearDown(db.close);

    expect(
      () => db.setNote(
        localDate: '2026-09-16',
        note: 'x' * (maxNoteLength + 1),
      ),
      throwsA(isA<InvalidAttendanceNote>()),
    );
  });
}

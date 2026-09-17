import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamid/data/local/database.dart';

import '../support/fakes.dart';

void main() {
  test('mark twice for the same date updates rather than inserting', () async {
    final db = AppDatabase(
      clock: FakeClock(DateTime(2026, 9, 16, 9)),
      ids: SequentialIdGenerator(),
      executor: NativeDatabase.memory(),
    );
    addTearDown(db.close);

    await db.mark(localDate: '2026-09-16', status: statusAttended);
    await db.mark(localDate: '2026-09-16', status: statusSkipped);

    final rows = await db.watchRecent().first;
    expect(rows, hasLength(1));
    expect(rows.single.status, statusSkipped);
  });
}

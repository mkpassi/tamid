import 'package:drift/drift.dart' hide isNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamid/data/local/database.dart';

import '../generated_migrations/schema.dart';
import '../generated_migrations/schema_v1.dart' as v1;
import '../support/fakes.dart';

/// The harness matters more than the single migration it currently covers:
/// drift_schemas/ is the only record of what v1 looked like, and without it no
/// future migration can be tested against real historical data.
void main() {
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('v1 -> v2 keeps existing rows and leaves note null', () async {
    final schema = await verifier.schemaAt(1);
    final oldDb = v1.DatabaseAtV1(schema.newConnection());

    await oldDb.into(oldDb.attendanceDays).insert(
      const RawValuesInsertable({
        'id': Variable('id-001'),
        'user_id': Variable('local'),
        'device_id': Variable('device-001'),
        'local_date': Variable('2026-09-16'),
        'tz_offset_min': Variable(330),
        'status': Variable('attended'),
        'marked_at': Variable(1789537939583),
        'created_at': Variable(1789537939583),
        'updated_at': Variable(1789537939583),
      }),
    );
    await oldDb.close();

    final db = AppDatabase(
      clock: FakeClock(DateTime(2026, 9, 16, 9)),
      ids: SequentialIdGenerator(),
      executor: schema.newConnection(),
    );
    addTearDown(db.close);

    await verifier.migrateAndValidate(db, 2);

    final rows = await db.watchRecent().first;
    expect(rows, hasLength(1), reason: 'the pre-existing day must survive');
    expect(rows.single.localDate, '2026-09-16');
    expect(rows.single.status, AttendanceStatus.attended);
    expect(rows.single.tzOffsetMin, 330);
    expect(rows.single.note, isNull, reason: 'new column starts empty');
  });
}

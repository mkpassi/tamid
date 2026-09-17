import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/util/clock.dart';
import '../../core/util/ids.dart';

part 'database.g.dart';

const statusAttended = 'attended';
const statusSkipped = 'skipped';

const _deviceIdKey = 'device_id';

/// One answer per local day: did today count?
///
/// [syncState] and [serverRev] are unused in this iteration. They exist so the
/// first sync-capable version needs no migration. Do not write logic against
/// them.
@TableIndex.sql(
  'CREATE UNIQUE INDEX IF NOT EXISTS attendance_user_date '
  'ON attendance_days (user_id, local_date) WHERE deleted_at IS NULL',
)
class AttendanceDays extends Table {
  TextColumn get id => text()(); // UUIDv7
  TextColumn get userId => text().withDefault(const Constant('local'))();
  TextColumn get deviceId => text()();
  TextColumn get localDate => text()(); // 'yyyy-MM-dd', 04:00 boundary
  IntColumn get tzOffsetMin => integer()();
  TextColumn get status => text()(); // 'attended' | 'skipped'
  IntColumn get markedAt => integer()(); // UTC epoch ms
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()(); // tombstone
  IntColumn get syncState => integer().withDefault(const Constant(0))();
  IntColumn get serverRev => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Key/value scratch space. Holds `device_id`, generated once on first launch,
/// so one value does not justify a shared_preferences dependency.
class AppMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [AttendanceDays, AppMeta])
class AppDatabase extends _$AppDatabase {
  AppDatabase({
    this.clock = const SystemClock(),
    this.ids = const UuidV7Generator(),
    QueryExecutor? executor,
  }) : super(executor ?? driftDatabase(name: 'tamid'));

  final Clock clock;
  final IdGenerator ids;

  @override
  int get schemaVersion => 1;

  /// The single place the tombstone filter is applied, so no read can forget.
  Expression<bool> _alive($AttendanceDaysTable t) => t.deletedAt.isNull();

  Stream<List<AttendanceDay>> watchRecent({int limit = 60}) {
    final q = select(attendanceDays)
      ..where(_alive)
      ..orderBy([(t) => OrderingTerm.desc(t.localDate)])
      ..limit(limit);
    return q.watch();
  }

  Stream<AttendanceDay?> watchDay(String localDate) {
    final q = select(attendanceDays)
      ..where((t) => _alive(t) & t.localDate.equals(localDate))
      ..limit(1);
    return q.watchSingleOrNull();
  }

  /// Upserts on (userId, localDate): re-answering a day replaces the answer
  /// rather than adding a second row. Bumps [updatedAt] on every write.
  Future<void> mark({
    required String localDate,
    required String status,
  }) async {
    final now = clock.nowUtcMillis();
    final device = await deviceId();
    await into(attendanceDays).insert(
      AttendanceDaysCompanion.insert(
        id: ids.generate(),
        deviceId: device,
        localDate: localDate,
        tzOffsetMin: clock.tzOffsetMinutes(clock.nowUtc()),
        status: status,
        markedAt: now,
        createdAt: now,
        updatedAt: now,
      ),
      onConflict: DoUpdate(
        (old) => AttendanceDaysCompanion(
          status: Value(status),
          markedAt: Value(now),
          updatedAt: Value(now),
        ),
        target: [attendanceDays.userId, attendanceDays.localDate],
        targetCondition: (t) => t.deletedAt.isNull(),
      ),
    );
  }

  /// Read-or-create. Stable for the life of the install.
  Future<String> deviceId() async {
    final existing = await (select(
      appMeta,
    )..where((t) => t.key.equals(_deviceIdKey))).getSingleOrNull();
    if (existing != null) return existing.value;

    final generated = ids.generate();
    await into(appMeta).insert(
      AppMetaData(key: _deviceIdKey, value: generated),
      mode: InsertMode.insertOrIgnore,
    );
    final stored = await (select(
      appMeta,
    )..where((t) => t.key.equals(_deviceIdKey))).getSingle();
    return stored.value;
  }
}

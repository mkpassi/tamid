import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/util/clock.dart';
import '../../core/util/ids.dart';

part 'database.g.dart';

const statusAttended = 'attended';
const statusSkipped = 'skipped';

/// How far back a day may still be answered. An honest streak means you cannot
/// retroactively fill in last quarter.
const backfillWindowDays = 30;

const _deviceIdKey = 'device_id';

final _localDatePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Thrown when a write names a date that is malformed, in the future, or older
/// than the backfill window. Deliberately one class, not a hierarchy.
final class InvalidAttendanceDate implements Exception {
  const InvalidAttendanceDate(this.message);

  final String message;

  @override
  String toString() => 'InvalidAttendanceDate: $message';
}

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

  /// The oldest date still editable, inclusive.
  String earliestEditableDate() {
    final today = clock.dateTimeForLocalDate(clock.today());
    return clock.localDateFor(
      DateTime(
        today.year,
        today.month,
        today.day - backfillWindowDays,
        dayBoundaryHour,
      ),
    );
  }

  /// Guards every write. The UI disables ineligible days, but disabled buttons
  /// are not validation — this is.
  void _validateDate(String localDate) {
    if (!_localDatePattern.hasMatch(localDate)) {
      throw InvalidAttendanceDate('"$localDate" is not yyyy-MM-dd.');
    }
    // Round-trip: DateTime(2026, 2, 31) silently rolls into March, so a date
    // that does not format back to itself was never a real date.
    if (clock.localDateFor(clock.dateTimeForLocalDate(localDate)) !=
        localDate) {
      throw InvalidAttendanceDate('"$localDate" is not a real calendar date.');
    }
    // 'yyyy-MM-dd' sorts lexicographically, so string comparison is date
    // comparison.
    final today = clock.today();
    if (localDate.compareTo(today) > 0) {
      throw InvalidAttendanceDate('"$localDate" is in the future.');
    }
    final earliest = earliestEditableDate();
    if (localDate.compareTo(earliest) < 0) {
      throw InvalidAttendanceDate(
        '"$localDate" is older than the $backfillWindowDays-day '
        'backfill window (earliest is $earliest).',
      );
    }
  }

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
    _validateDate(localDate);
    final now = clock.nowUtcMillis();
    final device = await deviceId();
    await into(attendanceDays).insert(
      AttendanceDaysCompanion.insert(
        id: ids.generate(),
        deviceId: device,
        localDate: localDate,
        // The offset in force on THAT date, not today's. Backfilling across a
        // DST or travel boundary stores the wrong offset otherwise, and it is
        // unrecoverable afterwards.
        tzOffsetMin: clock.tzOffsetMinutes(
          clock.dateTimeForLocalDate(localDate),
        ),
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

  /// Removes a day's answer by tombstone, never by DELETE.
  ///
  /// The unique index is partial (`WHERE deleted_at IS NULL`), so the cleared
  /// row stops participating and the day can be answered again cleanly.
  Future<void> clearDay(String localDate) async {
    _validateDate(localDate);
    final now = clock.nowUtcMillis();
    final q = update(attendanceDays)
      ..where((t) => _alive(t) & t.localDate.equals(localDate));
    await q.write(
      AttendanceDaysCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
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

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/util/clock.dart';
import '../../core/util/ids.dart';

part 'database.g.dart';

/// The answer to "did I train?".
///
/// [unanswered] is not a third answer — it is the absence of one, written only
/// when a note is saved on a day that has no answer yet. Never pass it to
/// [AppDatabase.mark]; ask [AttendanceDayStatus.isAnswered] instead of
/// comparing statuses at call sites.
enum AttendanceStatus {
  attended('attended'),
  skipped('skipped'),
  unanswered('unanswered');

  const AttendanceStatus(this.stored);

  /// The value persisted in SQLite. Never change these strings.
  final String stored;

  static AttendanceStatus fromStored(String value) => values.firstWhere(
    (v) => v.stored == value,
    orElse: () => throw ArgumentError.value(value, 'status', 'unknown status'),
  );
}

class _StatusConverter extends TypeConverter<AttendanceStatus, String> {
  const _StatusConverter();

  @override
  AttendanceStatus fromSql(String fromDb) => AttendanceStatus.fromStored(fromDb);

  @override
  String toSql(AttendanceStatus value) => value.stored;
}

/// The single predicate for "does this day carry an answer". Streak logic and
/// every future query go through this, never through a status comparison.
extension AttendanceDayStatus on AttendanceDay {
  bool get isAnswered => status != AttendanceStatus.unanswered;
}

/// Longest note we will store. Enforced here, not only in the text field.
const maxNoteLength = 500;

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

/// Thrown when a note exceeds [maxNoteLength]. Truncating silently would lose
/// the user's words without telling them.
final class InvalidAttendanceNote implements Exception {
  const InvalidAttendanceNote(this.message);

  final String message;

  @override
  String toString() => 'InvalidAttendanceNote: $message';
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
  TextColumn get status => text().map(const _StatusConverter())();
  TextColumn get note => text().nullable()();
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
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // `from <` rather than `from ==`: skipping a version is a real case,
      // including after a gap between installs. Never destructiveFallback —
      // that silently deletes the data this whole exercise exists to keep.
      if (from < 2) {
        await m.addColumn(attendanceDays, attendanceDays.note);
      }
    },
  );

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
    required AttendanceStatus status,
  }) async {
    if (status == AttendanceStatus.unanswered) {
      throw ArgumentError.value(
        status,
        'status',
        'unanswered is the absence of an answer, never a choice. It is written '
            'only by setNote when a day has no answer yet.',
      );
    }
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

  /// Empty and whitespace-only notes are indistinguishable from no note at
  /// all, so they normalise to null here — the one place that decision lives.
  String? _normaliseNote(String? note) {
    final trimmed = note?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    if (trimmed.length > maxNoteLength) {
      throw InvalidAttendanceNote(
        'Note is ${trimmed.length} characters; the maximum is $maxNoteLength.',
      );
    }
    return trimmed;
  }

  /// Sets or clears a day's note, independently of its status.
  ///
  /// A day with something worth saying but no answer yet is a real case — "I
  /// couldn't train, here's why" — so this creates the row with
  /// [AttendanceStatus.unanswered] when none exists. That is the only code
  /// path that ever writes that value.
  Future<void> setNote({
    required String localDate,
    required String? note,
  }) async {
    _validateDate(localDate);
    final normalised = _normaliseNote(note);
    final now = clock.nowUtcMillis();
    final device = await deviceId();
    await into(attendanceDays).insert(
      AttendanceDaysCompanion.insert(
        id: ids.generate(),
        deviceId: device,
        localDate: localDate,
        tzOffsetMin: clock.tzOffsetMinutes(
          clock.dateTimeForLocalDate(localDate),
        ),
        status: AttendanceStatus.unanswered,
        markedAt: now,
        createdAt: now,
        updatedAt: now,
        note: Value(normalised),
      ),
      // Only the note moves: an existing answer is left exactly as it was.
      onConflict: DoUpdate(
        (old) => AttendanceDaysCompanion(
          note: Value(normalised),
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

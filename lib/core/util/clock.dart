/// The only file in the project permitted to call [DateTime.now].
///
/// Everything else takes a [Clock]. This is what makes day-boundary and
/// timezone behaviour testable without waiting for midnight or moving house.
library;

/// A local day starts at 04:00, not midnight.
///
/// A session logged at 01:30 belongs to the previous day. Referenced
/// everywhere; never inlined.
const dayBoundaryHour = 4;

abstract interface class Clock {
  DateTime nowUtc();
  int nowUtcMillis();

  /// Local calendar date for a moment, applying the 04:00 day boundary.
  /// 2026-09-16T01:30 local  ->  '2026-09-15'
  String localDateFor(DateTime moment);

  /// Today's local date under the 04:00 boundary.
  String today();

  /// Minutes offset from UTC at the given moment.
  int tzOffsetMinutes(DateTime moment);
}

/// Date math shared by every [Clock], real or fake, so implementations cannot
/// drift apart on where a day begins.
mixin ClockDateMath implements Clock {
  @override
  int nowUtcMillis() => nowUtc().millisecondsSinceEpoch;

  @override
  String today() => localDateFor(nowUtc());

  @override
  String localDateFor(DateTime moment) {
    final local = moment.toLocal();
    // Wall-clock arithmetic, deliberately: subtracting a Duration would shift
    // by absolute time and land an hour out across a DST transition.
    final day = local.hour < dayBoundaryHour
        ? DateTime(local.year, local.month, local.day - 1)
        : local;
    return '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
  }

  @override
  int tzOffsetMinutes(DateTime moment) =>
      moment.toLocal().timeZoneOffset.inMinutes;
}

final class SystemClock with ClockDateMath implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

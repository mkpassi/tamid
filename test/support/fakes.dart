import 'package:tamid/core/util/clock.dart';
import 'package:tamid/core/util/ids.dart';

/// Settable clock. Test-only, deliberately not in lib/.
///
/// [offsetRule] lets a test describe a timezone whose offset changes on a
/// given date, so backfill behaviour can be asserted without depending on the
/// host machine's timezone.
final class FakeClock with ClockDateMath implements Clock {
  FakeClock(this._now, {this.offsetRule});

  DateTime _now;
  final int Function(DateTime moment)? offsetRule;

  set now(DateTime value) => _now = value;

  @override
  DateTime nowUtc() => _now.toUtc();

  @override
  int tzOffsetMinutes(DateTime moment) =>
      offsetRule?.call(moment) ?? super.tzOffsetMinutes(moment);
}

/// Produces id-001, id-002, ... so fixtures stay readable.
final class SequentialIdGenerator implements IdGenerator {
  int _next = 1;

  @override
  String generate() => 'id-${(_next++).toString().padLeft(3, '0')}';
}

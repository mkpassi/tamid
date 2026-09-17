import 'package:tamid/core/util/clock.dart';
import 'package:tamid/core/util/ids.dart';

/// Settable clock. Test-only, deliberately not in lib/.
final class FakeClock with ClockDateMath implements Clock {
  FakeClock(this._now);

  DateTime _now;

  set now(DateTime value) => _now = value;

  @override
  DateTime nowUtc() => _now.toUtc();
}

/// Produces id-001, id-002, ... so fixtures stay readable.
final class SequentialIdGenerator implements IdGenerator {
  int _next = 1;

  @override
  String generate() => 'id-${(_next++).toString().padLeft(3, '0')}';
}

import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  group('localDateFor — 04:00 day boundary', () {
    test('01:30 local belongs to the previous day', () {
      final clock = FakeClock(DateTime(2026, 9, 16, 1, 30));
      expect(clock.localDateFor(DateTime(2026, 9, 16, 1, 30)), '2026-09-15');
    });

    test('04:00 local is the first moment of the new day', () {
      final clock = FakeClock(DateTime(2026, 9, 16, 4));
      expect(clock.localDateFor(DateTime(2026, 9, 16, 4)), '2026-09-16');
      expect(
        clock.localDateFor(DateTime(2026, 9, 16, 3, 59)),
        '2026-09-15',
      );
    });

    test('rolls back across a month boundary', () {
      final clock = FakeClock(DateTime(2026, 10, 1, 2));
      expect(clock.localDateFor(DateTime(2026, 10, 1, 2)), '2026-09-30');
    });

    test('today() uses the boundary', () {
      final clock = FakeClock(DateTime(2026, 9, 16, 1, 30));
      expect(clock.today(), '2026-09-15');
    });
  });

  group('localDateFor across DST transition dates', () {
    // Wall-clock arithmetic, not Duration arithmetic: the result must depend
    // only on the local calendar fields, so a skipped or repeated hour cannot
    // move a session into the wrong day. Asserted on both 2026 US transition
    // dates; the host timezone does not need to observe DST for this to be
    // meaningful, because a Duration-based implementation would still shift
    // these values.
    test('spring forward date — 8 March 2026', () {
      final clock = FakeClock(DateTime(2026, 3, 8, 1, 30));
      expect(clock.localDateFor(DateTime(2026, 3, 8, 1, 30)), '2026-03-07');
      expect(clock.localDateFor(DateTime(2026, 3, 8, 4, 30)), '2026-03-08');
      expect(clock.localDateFor(DateTime(2026, 3, 8, 23, 59)), '2026-03-08');
    });

    test('fall back date — 1 November 2026', () {
      final clock = FakeClock(DateTime(2026, 11, 1, 1, 30));
      expect(clock.localDateFor(DateTime(2026, 11, 1, 1, 30)), '2026-10-31');
      expect(clock.localDateFor(DateTime(2026, 11, 1, 4)), '2026-11-01');
    });

    test('a UTC moment is resolved in local time, not UTC', () {
      final clock = FakeClock(DateTime.utc(2026, 9, 16, 12));
      final utcMoment = DateTime.utc(2026, 9, 16, 12);
      expect(clock.localDateFor(utcMoment), clock.localDateFor(utcMoment.toLocal()));
    });
  });
}

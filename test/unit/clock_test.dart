import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  test('01:30 local belongs to the previous day', () {
    final clock = FakeClock(DateTime(2026, 9, 16, 1, 30));
    expect(clock.localDateFor(DateTime(2026, 9, 16, 1, 30)), '2026-09-15');
  });

  test('the boundary holds across a DST transition', () {
    // Wall-clock arithmetic, not Duration arithmetic: the date must depend
    // only on local calendar fields, so a skipped or repeated hour cannot
    // move a session into the wrong day. Asserted on both 2026 US transitions.
    final springForward = FakeClock(DateTime(2026, 3, 8, 1, 30));
    expect(springForward.localDateFor(DateTime(2026, 3, 8, 1, 30)), '2026-03-07');
    expect(springForward.localDateFor(DateTime(2026, 3, 8, 4, 30)), '2026-03-08');

    final fallBack = FakeClock(DateTime(2026, 11, 1, 1, 30));
    expect(fallBack.localDateFor(DateTime(2026, 11, 1, 1, 30)), '2026-10-31');
    expect(fallBack.localDateFor(DateTime(2026, 11, 1, 4)), '2026-11-01');
  });
}

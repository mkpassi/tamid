import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/util/clock.dart';
import '../core/util/ids.dart';
import '../data/local/database.dart';

final clockProvider = Provider<Clock>((ref) => const SystemClock());
final idProvider = Provider<IdGenerator>((ref) => const UuidV7Generator());
final databaseProvider = Provider<AppDatabase>(
  (ref) => AppDatabase(
    clock: ref.watch(clockProvider),
    ids: ref.watch(idProvider),
  ),
);
final recentDaysProvider = StreamProvider<List<AttendanceDay>>(
  (ref) => ref.watch(databaseProvider).watchRecent(),
);

/// Last 7 local dates, oldest first.
List<String> _lastSevenDates(Clock clock) {
  final now = clock.nowUtc();
  return [
    for (var i = 6; i >= 0; i--)
      clock.localDateFor(now.subtract(Duration(days: i))),
  ];
}

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(recentDaysProvider);

    return Scaffold(
      body: SafeArea(
        child: days.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Something went wrong.\n$e')),
          data: (rows) => _Loaded(rows: rows),
        ),
      ),
    );
  }
}

class _Loaded extends ConsumerWidget {
  const _Loaded({required this.rows});

  final List<AttendanceDay> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clock = ref.watch(clockProvider);
    final today = clock.today();
    final byDate = {for (final r in rows) r.localDate: r};
    final todayRow = byDate[today];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
          child: Text(
            todayRow == null
                ? 'Did you train today?'
                : todayRow.status == statusAttended
                ? 'You trained today.'
                : 'You sat today out.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _AnswerButton(
                  label: 'Yes',
                  status: statusAttended,
                  selected: todayRow?.status == statusAttended,
                  localDate: today,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _AnswerButton(
                  label: 'Not today',
                  status: statusSkipped,
                  selected: todayRow?.status == statusSkipped,
                  localDate: today,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: _DotStrip(byDate: byDate, dates: _lastSevenDates(clock)),
        ),
        const Divider(height: 1),
        Expanded(child: _History(rows: rows)),
      ],
    );
  }
}

class _AnswerButton extends ConsumerWidget {
  const _AnswerButton({
    required this.label,
    required this.status,
    required this.selected,
    required this.localDate,
  });

  final String label;
  final String status;
  final bool selected;
  final String localDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The write goes to the database; the stream re-emits; the UI updates.
    // Never setState here.
    void onPressed() => ref
        .read(databaseProvider)
        .mark(localDate: localDate, status: status);

    const minimumSize = Size.fromHeight(72);
    return selected
        ? FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(minimumSize: minimumSize),
            child: Text(label),
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(minimumSize: minimumSize),
            child: Text(label),
          );
  }
}

class _DotStrip extends StatelessWidget {
  const _DotStrip({required this.byDate, required this.dates});

  final Map<String, AttendanceDay> byDate;
  final List<String> dates;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final attended = dates
        .where((d) => byDate[d]?.status == statusAttended)
        .length;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final date in dates)
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: byDate[date]?.status == statusAttended
                      ? scheme.primary
                      : Colors.transparent,
                  border: Border.all(
                    color: byDate.containsKey(date)
                        ? scheme.primary
                        : scheme.outlineVariant,
                    width: 2,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '$attended of ${dates.length}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _History extends ConsumerWidget {
  const _History({required this.rows});

  final List<AttendanceDay> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (rows.isEmpty) {
      return const Center(child: Text('No days recorded yet.'));
    }
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final row = rows[i];
        final attended = row.status == statusAttended;
        return ListTile(
          leading: Icon(attended ? Icons.check_circle : Icons.remove_circle),
          title: Text(row.localDate),
          subtitle: Text(attended ? 'Trained' : 'Sat out'),
          // Tap flips the answer. Same write path as the buttons.
          onTap: () => ref.read(databaseProvider).mark(
            localDate: row.localDate,
            status: attended ? statusSkipped : statusAttended,
          ),
        );
      },
    );
  }
}

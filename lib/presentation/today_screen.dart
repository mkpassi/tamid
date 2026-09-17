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

/// Which month the calendar shows: 0 = current, 1 = previous. The 30-day
/// window can span two months; there is nothing editable beyond that.
final monthOffsetProvider = NotifierProvider<MonthOffset, int>(MonthOffset.new);

class MonthOffset extends Notifier<int> {
  @override
  int build() => 0;

  void showPrevious() => state = 1;
  void showCurrent() => state = 0;
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

const _weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

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
                : todayRow.status == AttendanceStatus.attended
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
                  status: AttendanceStatus.attended,
                  selected: todayRow?.status == AttendanceStatus.attended,
                  localDate: today,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _AnswerButton(
                  label: 'Not today',
                  status: AttendanceStatus.skipped,
                  selected: todayRow?.status == AttendanceStatus.skipped,
                  localDate: today,
                ),
              ),
            ],
          ),
        ),
        if (todayRow?.note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Text(
              todayRow!.note!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        const SizedBox(height: 24),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            child: _Calendar(byDate: byDate),
          ),
        ),
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
  final AttendanceStatus status;
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

/// Month grid. Replaces the history list: same data, better interface.
class _Calendar extends ConsumerWidget {
  const _Calendar({required this.byDate});

  final Map<String, AttendanceDay> byDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clock = ref.watch(clockProvider);
    final offset = ref.watch(monthOffsetProvider);
    final earliest = ref.watch(databaseProvider).earliestEditableDate();

    final today = clock.today();
    final todayDt = clock.dateTimeForLocalDate(today);
    final month = DateTime(todayDt.year, todayDt.month - offset, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Monday-first grid: weekday is 1 (Mon) .. 7 (Sun).
    final leadingBlanks = month.weekday - 1;

    String dateOf(int day) => clock.localDateFor(
      DateTime(month.year, month.month, day, dayBoundaryHour),
    );

    final cells = <Widget>[
      for (var i = 0; i < leadingBlanks; i++) const SizedBox.shrink(),
      for (var day = 1; day <= daysInMonth; day++)
        _DayCell(
          day: day,
          date: dateOf(day),
          row: byDate[dateOf(day)],
          today: today,
          earliest: earliest,
        ),
    ];

    final weeks = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      final week = cells.sublist(i, (i + 7).clamp(0, cells.length));
      weeks.add(
        Row(
          children: [
            for (final cell in week) Expanded(child: cell),
            // Pad the final short week so cells keep their width.
            for (var j = week.length; j < 7; j++)
              const Expanded(child: SizedBox.shrink()),
          ],
        ),
      );
    }

    final attended = [
      for (var day = 1; day <= daysInMonth; day++) dateOf(day),
    ].where((d) => byDate[d]?.status == AttendanceStatus.attended).length;
    // Current month is judged on days elapsed; a past month on its full length.
    final denominator = offset == 0 ? todayDt.day : daysInMonth;

    return Column(
      children: [
        _MonthHeader(month: month, offset: offset),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              for (final label in _weekdayLabels)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(children: weeks),
        ),
        const SizedBox(height: 12),
        Text(
          '$attended of $denominator',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _MonthHeader extends ConsumerWidget {
  const _MonthHeader({required this.month, required this.offset});

  final DateTime month;
  final int offset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(monthOffsetProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          // One step back only: nothing beyond the window is editable.
          onPressed: offset == 0 ? notifier.showPrevious : null,
        ),
        Text(
          '${_monthNames[month.month - 1]} ${month.year}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: offset == 1 ? notifier.showCurrent : null,
        ),
      ],
    );
  }
}

class _DayCell extends ConsumerWidget {
  const _DayCell({
    required this.day,
    required this.date,
    required this.row,
    required this.today,
    required this.earliest,
  });

  final int day;
  final String date;
  final AttendanceDay? row;
  final String today;
  final String earliest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final isToday = date == today;
    final isFuture = date.compareTo(today) > 0;
    final tooOld = date.compareTo(earliest) < 0;
    final editable = !isFuture && !tooOld;

    final attended = row?.status == AttendanceStatus.attended;
    final skipped = row?.status == AttendanceStatus.skipped;

    final Color background = attended ? scheme.primary : Colors.transparent;
    final Color border = isToday
        ? scheme.primary
        : attended || skipped
        ? scheme.primary
        : editable
        ? scheme.outlineVariant
        : Colors.transparent;
    final Color text = attended
        ? scheme.onPrimary
        : editable
        ? scheme.onSurface
        : scheme.outline;

    return Padding(
      padding: const EdgeInsets.all(3),
      child: AspectRatio(
        aspectRatio: 1,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: editable
              ? () => _openDaySheet(context, ref, date: date, row: row)
              : null,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: background,
              border: Border.all(
                color: border,
                width: isToday ? 2.5 : 1.5,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  '$day',
                  style: TextStyle(
                    color: text,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    decoration: skipped ? TextDecoration.lineThrough : null,
                  ),
                ),
                // Secondary information: must not compete with attended /
                // skipped, which is what the grid exists to convey.
                if (row?.note != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: attended ? scheme.onPrimary : scheme.outline,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openDaySheet(
  BuildContext context,
  WidgetRef ref, {
  required String date,
  required AttendanceDay? row,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      // Lift the sheet above the keyboard when the note field has focus.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _DaySheet(date: date, row: row),
    ),
  );
}

class _DaySheet extends ConsumerStatefulWidget {
  const _DaySheet({required this.date, required this.row});

  final String date;
  final AttendanceDay? row;

  @override
  ConsumerState<_DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends ConsumerState<_DaySheet> {
  late final TextEditingController _note = TextEditingController(
    text: widget.row?.note ?? '',
  );

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// Saving is explicit — dismissing writes nothing, since back gestures and
  /// backdrop taps would otherwise save on cancel. Answering a status still
  /// carries any typed note along, so an answer never discards words.
  Future<void> _persistNote(AppDatabase db) async {
    if (_note.text.trim() == (widget.row?.note ?? '')) return;
    await db.setNote(localDate: widget.date, note: _note.text);
  }

  Future<void> _answer(AttendanceStatus status) async {
    final db = ref.read(databaseProvider);
    final navigator = Navigator.of(context);
    await _persistNote(db);
    await db.mark(localDate: widget.date, status: status);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(databaseProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Text(
              widget.date,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: const Text('Yes'),
            onTap: () => _answer(AttendanceStatus.attended),
          ),
          ListTile(
            leading: const Icon(Icons.remove_circle_outline),
            title: const Text('Not today'),
            onTap: () => _answer(AttendanceStatus.skipped),
          ),
          if (widget.row != null)
            ListTile(
              leading: const Icon(Icons.backspace_outlined),
              title: const Text('Clear'),
              onTap: () async {
                final navigator = Navigator.of(context);
                // Tombstone, not a delete.
                await db.clearDay(widget.date);
                navigator.pop();
              },
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: TextField(
              controller: _note,
              minLines: 2,
              maxLines: 4,
              maxLength: maxNoteLength,
              decoration: const InputDecoration(
                hintText: 'What happened?',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await _persistNote(db);
                    navigator.pop();
                  },
                  child: const Text('Save note'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

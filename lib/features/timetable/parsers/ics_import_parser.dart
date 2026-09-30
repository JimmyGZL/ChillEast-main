/// 从 `.ics` 日历文件导入课表的解析器。
///
/// 与 `IcsParser`（用于 courses.json 缺失时兜底展示）的区别：
/// - 周次**由事件真实日期换算**，而不是依赖 DESCRIPTION 里的「周次：…」文本，
///   因此别的 App 导出的 ICS 也能正确落到周次上；
/// - 支持展开 `RRULE:FREQ=WEEKLY`（COUNT / UNTIL / INTERVAL）；
/// - 同名同时间段的事件会合并周次，非连续周（4-6、9-14）不会被拆成多门课。
///
/// 周次必须相对「第一周周一」才有意义，所以解析分两步：
/// [parse] 先把文件读成事件，[toCourses] 再按用户选定的第一周周一换算。
library;

import '../models/course_model.dart';
import '../utils/date_calculator.dart';
import '../utils/week_parser.dart';

/// ICS 里的一个事件（尚未换算成周次）。
class IcsEvent {
  const IcsEvent({
    required this.name,
    required this.teacher,
    required this.classroom,
    required this.start,
    required this.end,
    this.weeklyRepeat = false,
    this.repeatCount,
    this.repeatUntil,
    this.intervalWeeks = 1,
    this.describedWeeks = const [],
  });

  final String name;
  final String teacher;
  final String classroom;

  /// DTSTART（本地时间）。
  final DateTime start;

  /// DTEND（本地时间）。
  final DateTime end;

  /// RRULE 是否以周为频率。
  final bool weeklyRepeat;

  /// RRULE COUNT。
  final int? repeatCount;

  /// RRULE UNTIL。
  final DateTime? repeatUntil;

  /// RRULE INTERVAL（默认 1 周）。
  final int intervalWeeks;

  /// DESCRIPTION 里声明的周次（本 App 导出的 ICS 会写），可为空。
  final List<int> describedWeeks;

  int get startMinutes => start.hour * 60 + start.minute;
  int get endMinutes => end.hour * 60 + end.minute;
}

/// [IcsImportParser.parse] 的结果。
class ParsedIcs {
  const ParsedIcs({
    required this.events,
    this.suggestedFirstWeekMonday,
    this.skippedEvents = 0,
    this.unsupportedRepeats = 0,
  });

  final List<IcsEvent> events;

  /// 由 DESCRIPTION 中的周次反推出的第一周周一（本 App 导出的 ICS 可精确推出）。
  final DateTime? suggestedFirstWeekMonday;

  /// 缺少 SUMMARY / DTSTART 而跳过的事件数。
  final int skippedEvents;

  /// 非「按周重复」的 RRULE 数量（只取了首次发生的时间）。
  final int unsupportedRepeats;

  bool get isEmpty => events.isEmpty;
}

class IcsImportParser {
  const IcsImportParser._();

  static final RegExp _eventBlock = RegExp(
    r'BEGIN:VEVENT\s*([\s\S]*?)\s*END:VEVENT',
    multiLine: true,
    dotAll: true,
  );

  static final RegExp _property =
      RegExp(r'^([A-Za-z0-9\-]+)(;[^:]*)?:(.*)$');

  static final RegExp _describedWeeks = RegExp(r'第\s*([\d,\-，、\s]+)\s*周');

  /// 单门课最多展开的周数，防止异常 ICS 造出上千条。
  static const int _maxOccurrences = 30;

  /// 解析 ICS 文本。
  static ParsedIcs parse(String content) {
    final events = <IcsEvent>[];
    var skipped = 0;
    var unsupported = 0;

    for (final block in _eventBlock.allMatches(_unfold(content))) {
      final fields = _readFields(block.group(1) ?? '');

      final name = (fields['SUMMARY'] ?? '').trim();
      final start = _parseDateTime(fields['DTSTART']);
      if (name.isEmpty || start == null) {
        skipped++;
        continue;
      }

      final end = _parseDateTime(fields['DTEND']) ??
          start.add(const Duration(minutes: 45));

      final repeat = _parseRRule(fields['RRULE']);
      if (!repeat.weekly && repeat.hasRepeat) unsupported++;

      final weeks = _parseDescribedWeeks(fields['DESCRIPTION']);

      events.add(IcsEvent(
        name: name,
        teacher: _extractLabel(fields['DESCRIPTION'], '教师'),
        classroom: (fields['LOCATION'] ?? '').trim(),
        start: start,
        end: end,
        weeklyRepeat: repeat.weekly,
        repeatCount: repeat.count,
        repeatUntil: repeat.until,
        intervalWeeks: repeat.interval,
        describedWeeks: weeks,
      ));
    }

    return ParsedIcs(
      events: events,
      suggestedFirstWeekMonday: _suggestFirstWeekMonday(events),
      skippedEvents: skipped,
      unsupportedRepeats: unsupported,
    );
  }

  /// 按给定的第一周周一，把事件换算成课程列表。
  ///
  /// 同名 / 同教师 / 同教室 / 同星期 / 同节次的事件会合并周次。
  static List<CourseModel> toCourses(
    List<IcsEvent> events,
    DateTime firstWeekMonday,
  ) {
    final monday = _normalizeMonday(firstWeekMonday);
    final grouped = <String, _CourseAccumulator>{};

    for (final event in events) {
      final firstWeek = _weekIndexOf(event.start, monday);
      if (firstWeek < 1) continue; // 落在开学前，无法用周次表达

      final occurrences = _occurrenceCount(event, monday, firstWeek);
      final weeks = <int>{};
      for (var i = 0; i < occurrences; i++) {
        final week = firstWeek + i * event.intervalWeeks;
        if (week > _maxOccurrences) break;
        weeks.add(week);
      }
      if (weeks.isEmpty) continue;

      final periods = _periodsForTime(event.start, event.end);
      final dayOfWeek = event.start.weekday;
      final key = '${event.name}|${event.teacher}|${event.classroom}|'
          '$dayOfWeek|${periods.$1}|${periods.$2}';

      final accumulator = grouped.putIfAbsent(
        key,
        () => _CourseAccumulator(
          name: event.name,
          teacher: event.teacher,
          classroom: event.classroom,
          dayOfWeek: dayOfWeek,
          startPeriod: periods.$1,
          endPeriod: periods.$2,
        ),
      );
      accumulator.weeks.addAll(weeks);
    }

    final seenIds = <String>{};
    final courses = <CourseModel>[];
    for (final accumulator in grouped.values) {
      final weeks = accumulator.weeks.toList()..sort();
      final periods = '${accumulator.startPeriod.toString().padLeft(2, '0')}-'
          '${accumulator.endPeriod.toString().padLeft(2, '0')}';

      // 生成稳定且唯一的 id
      final base = 'ics-${accumulator.dayOfWeek}-$periods-${accumulator.name}';
      var id = base;
      var suffix = 1;
      while (!seenIds.add(id)) {
        suffix++;
        id = '$base#$suffix';
      }

      courses.add(CourseModel(
        id: id,
        name: accumulator.name,
        teacher: accumulator.teacher,
        classroom: accumulator.classroom,
        weeks: WeekParser.formatWeeksForCourse(weeks),
        periods: periods,
        dayOfWeek: accumulator.dayOfWeek,
        startPeriod: accumulator.startPeriod,
        endPeriod: accumulator.endPeriod,
      ));
    }

    courses.sort((a, b) {
      final byDay = a.dayOfWeek.compareTo(b.dayOfWeek);
      if (byDay != 0) return byDay;
      return a.startPeriod.compareTo(b.startPeriod);
    });
    return courses;
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /// 展开 ICS 的折行（长行以换行 + 空格/制表符续行）。
  static String _unfold(String content) =>
      content.replaceAll(RegExp(r'\r?\n[ \t]'), '');

  /// 读取一个 VEVENT 块内的属性；DESCRIPTION 这类值本身含裸换行，
  /// 因此非属性行会追加到上一个属性的值里。
  static Map<String, String> _readFields(String block) {
    final fields = <String, String>{};
    String? current;

    for (final rawLine in block.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith('BEGIN:') || line.startsWith('END:')) {
        current = null;
        continue;
      }

      final match = _property.firstMatch(line);
      if (match != null) {
        current = match.group(1)!.toUpperCase();
        final value = match.group(3) ?? '';
        fields[current] = fields.containsKey(current)
            ? '${fields[current]}\n$value'
            : value;
      } else if (current != null) {
        // 裸换行的续行（本 App 生成的 DESCRIPTION 就是这种）
        fields[current] = '${fields[current]}\n$line';
      }
    }
    return fields;
  }

  /// 解析 `YYYYMMDDTHHmmSS` / 带 Z 的 UTC / `YYYYMMDD`。
  static DateTime? _parseDateTime(String? value) {
    if (value == null || value.isEmpty) return null;
    final text = value.trim();
    final isUtc = text.endsWith('Z');
    final body = isUtc ? text.substring(0, text.length - 1) : text;

    final match = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?)?$')
        .firstMatch(body);
    if (match == null) return null;

    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.tryParse(match.group(4) ?? '') ?? 0;
    final minute = int.tryParse(match.group(5) ?? '') ?? 0;
    final second = int.tryParse(match.group(6) ?? '') ?? 0;

    // 带 Z 的是绝对时刻，必须先按 UTC 构造再转本地时区；
    // 不带 Z 的是浮动时间，直接按本地时间理解。
    return isUtc
        ? DateTime.utc(year, month, day, hour, minute, second).toLocal()
        : DateTime(year, month, day, hour, minute, second);
  }

  static _RepeatRule _parseRRule(String? value) {
    if (value == null || value.trim().isEmpty) return const _RepeatRule.none();

    var weekly = false;
    var hasRepeat = false;
    int? count;
    DateTime? until;
    var interval = 1;

    for (final part in value.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final key = part.substring(0, separator).toUpperCase();
      final raw = part.substring(separator + 1).trim();

      switch (key) {
        case 'FREQ':
          hasRepeat = true;
          weekly = raw.toUpperCase() == 'WEEKLY';
          break;
        case 'COUNT':
          count = int.tryParse(raw);
          break;
        case 'INTERVAL':
          interval = int.tryParse(raw) ?? 1;
          break;
        case 'UNTIL':
          until = _parseDateTime(raw);
          break;
        default:
          break;
      }
    }

    if (interval < 1) interval = 1;
    if (count != null && count < 1) count = null;
    return _RepeatRule(
      weekly: weekly,
      hasRepeat: hasRepeat,
      count: count,
      until: until,
      interval: interval,
    );
  }

  /// 从 DESCRIPTION 里取「周次：第4-6周」这类声明。
  static List<int> _parseDescribedWeeks(String? description) {
    if (description == null || description.isEmpty) return const [];
    final match = _describedWeeks.firstMatch(description);
    if (match == null) return const [];

    final cleaned = match
        .group(1)!
        .replaceAll('，', ',')
        .replaceAll('、', ',')
        .replaceAll(RegExp(r'\s+'), '');
    return WeekParser.parseWeeks(cleaned);
  }

  /// 从 DESCRIPTION 里取「教师：张三」这类带标签的值。
  static String _extractLabel(String? description, String label) {
    if (description == null || description.isEmpty) return '';
    final match =
        RegExp('$label\\s*[:：]\\s*(.+)').firstMatch(description);
    return match?.group(1)?.trim() ?? '';
  }

  /// 用 DESCRIPTION 里的周次反推第一周周一（取票数最多的候选）。
  static DateTime? _suggestFirstWeekMonday(List<IcsEvent> events) {
    final votes = <String, int>{};
    final candidates = <String, DateTime>{};

    for (final event in events) {
      if (event.describedWeeks.isEmpty) continue;
      final firstWeek = event.describedWeeks.reduce((a, b) => a < b ? a : b);
      if (firstWeek < 1) continue;

      final monday = _normalizeMonday(event.start)
          .subtract(Duration(days: (firstWeek - 1) * 7));
      final key = monday.toIso8601String();
      votes.update(key, (value) => value + 1, ifAbsent: () => 1);
      candidates[key] = monday;
    }

    if (votes.isEmpty) return null;
    final best = votes.entries.reduce((a, b) => b.value > a.value ? b : a);
    return candidates[best.key];
  }

  static int _occurrenceCount(IcsEvent event, DateTime monday, int firstWeek) {
    if (!event.weeklyRepeat) return 1;
    if (event.repeatCount != null) {
      return event.repeatCount!.clamp(1, _maxOccurrences);
    }
    if (event.repeatUntil != null) {
      final lastWeek = _weekIndexOf(event.repeatUntil!, monday);
      if (lastWeek < firstWeek) return 1;
      return ((lastWeek - firstWeek) ~/ event.intervalWeeks) + 1;
    }
    return 1;
  }

  /// 该日期属于第几周（相对第一周周一）。
  static int _weekIndexOf(DateTime date, DateTime monday) {
    final day = DateTime(date.year, date.month, date.day);
    final difference = day.difference(monday).inDays;
    return (difference / 7).floor() + 1;
  }

  /// 把事件的起止时间对齐到作息表的节次区间（取整体误差最小的一对）。
  ///
  /// 用 [DateCalculator] 做唯一来源，避免再抄一份作息表。
  static (int, int) _periodsForTime(DateTime start, DateTime end) {
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;

    var bestStart = 1;
    var bestEnd = 1;
    var bestScore = 1 << 30;

    for (var first = 1; first <= 12; first++) {
      final firstTime = DateCalculator.getSectionTime(first)['start']!;
      final firstMinutes = firstTime.hour * 60 + firstTime.minute;

      for (var last = first; last <= 12; last++) {
        final lastTime = DateCalculator.getSectionTime(last)['end']!;
        final lastMinutes = lastTime.hour * 60 + lastTime.minute;

        final score =
            (firstMinutes - startMinutes).abs() + (lastMinutes - endMinutes).abs();
        if (score < bestScore) {
          bestScore = score;
          bestStart = first;
          bestEnd = last;
        }
      }
    }
    return (bestStart, bestEnd);
  }

  static DateTime _normalizeMonday(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    return day.subtract(Duration(days: day.weekday - DateTime.monday));
  }
}

class _RepeatRule {
  const _RepeatRule({
    required this.weekly,
    required this.hasRepeat,
    this.count,
    this.until,
    this.interval = 1,
  });

  const _RepeatRule.none()
      : weekly = false,
        hasRepeat = false,
        count = null,
        until = null,
        interval = 1;

  final bool weekly;
  final bool hasRepeat;
  final int? count;
  final DateTime? until;
  final int interval;
}

class _CourseAccumulator {
  _CourseAccumulator({
    required this.name,
    required this.teacher,
    required this.classroom,
    required this.dayOfWeek,
    required this.startPeriod,
    required this.endPeriod,
  });

  final String name;
  final String teacher;
  final String classroom;
  final int dayOfWeek;
  final int startPeriod;
  final int endPeriod;
  final Set<int> weeks = <int>{};
}

import 'package:ChillEast/features/timetable/models/course_model.dart';
import 'package:ChillEast/features/timetable/utils/date_calculator.dart';
import 'package:ChillEast/features/timetable/utils/ics_generator.dart';
import 'package:ChillEast/features/timetable/utils/ics_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 作息表约束（来自校方口径）：
/// - 每小节 45 分钟；
/// - 同一大节内，两小节之间小课间 10 分钟；
/// - 因此每个大节（2 小节）= 45 + 10 + 45 = 100 分钟。
///
/// 这张表被周视图时间轴、ICS 导出、上课提醒三处共用，改坏了要立刻发现。
int _minutes(TimeOfDay time) => time.hour * 60 + time.minute;

int _parseClock(String text) {
  final parts = text.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

void main() {
  const bigSectionCount = 6;
  const sectionCount = bigSectionCount * 2;

  test('每个小节都是 45 分钟', () {
    for (var section = 1; section <= sectionCount; section++) {
      final time = DateCalculator.getSectionTime(section);
      final length = _minutes(time['end']!) - _minutes(time['start']!);
      expect(length, 45, reason: '第 $section 小节应为 45 分钟，实际 $length 分钟');
    }
  });

  test('同一大节内两小节之间的小课间是 10 分钟', () {
    for (var big = 1; big <= bigSectionCount; big++) {
      final first = DateCalculator.getSectionTime(big * 2 - 1);
      final second = DateCalculator.getSectionTime(big * 2);
      final gap = _minutes(second['start']!) - _minutes(first['end']!);
      expect(gap, 10, reason: '第 $big 大节的小课间应为 10 分钟，实际 $gap 分钟');
    }
  });

  test('每个大节合计 100 分钟', () {
    for (var big = 1; big <= bigSectionCount; big++) {
      final range = DateCalculator.getBigSectionTimeRange(big);
      final parts = range.split('-');
      expect(parts, hasLength(2), reason: '第 $big 大节的时间范围格式应为 HH:mm-HH:mm');
      final length = _parseClock(parts[1]) - _parseClock(parts[0]);
      expect(length, 100, reason: '第 $big 大节应为 100 分钟，实际 $length 分钟');
    }
  });

  test('大节时间范围与小节时间表一致（两处硬编码不能失配）', () {
    for (var big = 1; big <= bigSectionCount; big++) {
      final range = DateCalculator.getBigSectionTimeRange(big);
      final first = DateCalculator.getSectionTime(big * 2 - 1);
      final last = DateCalculator.getSectionTime(big * 2);

      final expectedStart = '${first['start']!.hour.toString().padLeft(2, '0')}:'
          '${first['start']!.minute.toString().padLeft(2, '0')}';
      final expectedEnd = '${last['end']!.hour.toString().padLeft(2, '0')}:'
          '${last['end']!.minute.toString().padLeft(2, '0')}';

      expect(range, '$expectedStart-$expectedEnd',
          reason: '第 $big 大节：getBigSectionTimeRange 与 getSectionTime 不一致');
    }
  });

  test('大节按时间顺序排列且互不重叠', () {
    var previousEnd = -1;
    for (var big = 1; big <= bigSectionCount; big++) {
      final parts = DateCalculator.getBigSectionTimeRange(big).split('-');
      final start = _parseClock(parts[0]);
      final end = _parseClock(parts[1]);
      expect(end, greaterThan(start), reason: '第 $big 大节结束时间应晚于开始时间');
      expect(start, greaterThan(previousEnd),
          reason: '第 $big 大节与上一大节重叠或顺序颠倒');
      previousEnd = end;
    }
  });

  test('ICS 生成→解析的节次映射与统一作息表一致', () {
    // IcsParser 内部还复制了一份小节时间表（用于把 ICS 时间反推回节次），
    // 这里用往返测试锁住它，防止与 DateCalculator 失配。
    final monday = DateTime(2026, 8, 31);
    for (var section = 1; section <= sectionCount; section++) {
      final course = CourseModel(
        id: 'p$section',
        name: '往返测试$section',
        teacher: '老师',
        classroom: '教室',
        weeks: '1(周)',
        periods: '$section-$section',
        dayOfWeek: 3,
        startPeriod: section,
        endPeriod: section,
      );

      final ics = IcsGenerator.generate([course], monday);
      final parsed = IcsParser.parse(ics);

      expect(parsed, hasLength(1), reason: '第 $section 小节的 ICS 往返应得到 1 条课程');
      expect(parsed.single.startPeriod, section,
          reason: '第 $section 小节起始节次往返不一致');
      expect(parsed.single.endPeriod, section,
          reason: '第 $section 小节结束节次往返不一致');
      expect(parsed.single.dayOfWeek, 3, reason: '星期在 ICS 往返后应保持为周三');
    }
  });
}

import 'package:ChillEast/features/timetable/models/course_model.dart';
import 'package:ChillEast/features/timetable/parsers/ics_import_parser.dart';
import 'package:ChillEast/features/timetable/utils/ics_generator.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-08-31 是周一，作为第一周周一。
final _monday = DateTime(2026, 8, 31);

const _original = [
  // 连续周
  CourseModel(
    id: 'a',
    name: '示例课A',
    teacher: '示例教师甲 示例教师乙',
    classroom: '示例楼201',
    weeks: '1-16(周)',
    periods: '01-02',
    dayOfWeek: 1,
    startPeriod: 1,
    endPeriod: 2,
  ),
  // 非连续周：生成时会被拆成两个 VEVENT，导入后必须合并回一门课
  CourseModel(
    id: 'b',
    name: '示例课B',
    teacher: '示例教师丙',
    classroom: '示例楼201',
    weeks: '4-6,9-14(周)',
    periods: '03-04',
    dayOfWeek: 3,
    startPeriod: 3,
    endPeriod: 4,
  ),
  // 单周
  CourseModel(
    id: 'c',
    name: '示例课C',
    teacher: '示例教师丁',
    classroom: '示例楼202',
    weeks: '5(周)',
    periods: '07-08',
    dayOfWeek: 5,
    startPeriod: 7,
    endPeriod: 8,
  ),
  // 四节课连上（含晚上 11-12 节）
  CourseModel(
    id: 'd',
    name: '示例课D',
    teacher: '示例教师戊',
    classroom: '示例楼203',
    weeks: '4-6(周)',
    periods: '09-12',
    dayOfWeek: 6,
    startPeriod: 9,
    endPeriod: 12,
  ),
];

/// 只比较导入关心、且能无损往返的字段。
Set<String> _fingerprints(List<CourseModel> courses) => courses
    .map((c) => '${c.name}|${c.teacher}|${c.classroom}|${c.weeks}|'
        '${c.dayOfWeek}|${c.startPeriod}|${c.endPeriod}')
    .toSet();

const _simpleIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//test//CN
BEGIN:VEVENT
UID:1
DTSTART:20260921T080000
DTEND:20260921T094000
SUMMARY:高等数学
LOCATION:一教101
END:VEVENT
BEGIN:VEVENT
UID:2
DTSTART:20260928T080000
DTEND:20260928T094000
SUMMARY:高等数学
LOCATION:一教101
END:VEVENT
END:VCALENDAR
''';

void main() {
  group('IcsImportParser 往返：本 App 导出的 ICS 能无损导入', () {
    test('生成 → 导入应还原出完全相同的课程', () {
      final ics = IcsGenerator.generate(_original, _monday);
      final parsed = IcsImportParser.parse(ics);

      expect(parsed.skippedEvents, 0);
      expect(parsed.unsupportedRepeats, 0);

      final restored = IcsImportParser.toCourses(parsed.events, _monday);
      expect(_fingerprints(restored), _fingerprints(_original));
    });

    test('非连续周不会被拆成多门课', () {
      final ics = IcsGenerator.generate(_original, _monday);
      final parsed = IcsImportParser.parse(ics);
      final restored = IcsImportParser.toCourses(parsed.events, _monday);

      expect(restored, hasLength(_original.length));

      final combined = restored.firstWhere((c) => c.name == '示例课B');
      expect(combined.weeks, '4-6,9-14(周)');
    });

    test('能从 DESCRIPTION 反推出第一周周一', () {
      final ics = IcsGenerator.generate(_original, _monday);
      final parsed = IcsImportParser.parse(ics);

      expect(parsed.suggestedFirstWeekMonday, _monday);
    });
  });

  group('IcsImportParser 处理其它来源的 ICS', () {
    test('多个独立 VEVENT（无 DESCRIPTION）会按同名同时间合并周次', () {
      final parsed = IcsImportParser.parse(_simpleIcs);
      expect(parsed.events, hasLength(2));
      expect(parsed.suggestedFirstWeekMonday, isNull);

      final courses = IcsImportParser.toCourses(parsed.events, _monday);
      expect(courses, hasLength(1));
      expect(courses.single.name, '高等数学');
      expect(courses.single.classroom, '一教101');
      expect(courses.single.weeks, '4-5(周)');
      expect(courses.single.dayOfWeek, 1);
      expect(courses.single.startPeriod, 1);
      expect(courses.single.endPeriod, 2);
    });

    test('RRULE INTERVAL=2 展开成隔周', () {
      final parsed = IcsImportParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260921T080000
DTEND:20260921T094000
SUMMARY:双周课
RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4
END:VEVENT
END:VCALENDAR
''');
      final courses = IcsImportParser.toCourses(parsed.events, _monday);
      expect(courses.single.weeks, '4,6,8,10(周)');
    });

    test('RRULE UNTIL 按结束日期收敛', () {
      final parsed = IcsImportParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260921T080000
DTEND:20260921T094000
SUMMARY:限期课
RRULE:FREQ=WEEKLY;UNTIL=20261012T000000Z
END:VEVENT
END:VCALENDAR
''');
      final courses = IcsImportParser.toCourses(parsed.events, _monday);
      expect(courses.single.weeks, '4-7(周)');
    });

    test('折行的长属性会被展开', () {
      final parsed = IcsImportParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260921T080000
DTEND:20260921T094000
SUMMARY:很长很长的课程名称
 续行部分
LOCATION:一教101
END:VEVENT
END:VCALENDAR
''');
      expect(parsed.events.single.name, '很长很长的课程名称续行部分');
    });

    test('带 Z 的 UTC 时间会转成本地时间', () {
      final parsed = IcsImportParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260921T000000Z
DTEND:20260921T014000Z
SUMMARY:UTC 课
END:VEVENT
END:VCALENDAR
''');
      // 断言与 UTC 的对应关系，而不是写死小时数，避免依赖跑测试的机器时区
      final event = parsed.events.single;
      expect(event.start, DateTime.utc(2026, 9, 21, 0, 0).toLocal());
      expect(event.end, DateTime.utc(2026, 9, 21, 1, 40).toLocal());
      // 且仍是当天、周一
      expect(event.start.weekday, 1);
    });

    test('缺少 DTEND 时按 45 分钟默认', () {
      final parsed = IcsImportParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260921T080000
SUMMARY:无结束时间
END:VEVENT
END:VCALENDAR
''');
      final event = parsed.events.single;
      expect(event.end.difference(event.start).inMinutes, 45);
      // 仍然能对齐到第 1 小节（45 分钟 08:00-08:45）
      final courses = IcsImportParser.toCourses(parsed.events, _monday);
      expect(courses.single.startPeriod, 1);
      expect(courses.single.endPeriod, 1);
    });
  });

  group('IcsImportParser 边界情况', () {
    test('开学之前的事件会被跳过', () {
      final parsed = IcsImportParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260824T080000
DTEND:20260824T094000
SUMMARY:开学前的课
END:VEVENT
END:VCALENDAR
''');
      expect(parsed.events, hasLength(1));
      expect(IcsImportParser.toCourses(parsed.events, _monday), isEmpty);
    });

    test('缺少 SUMMARY 或 DTSTART 的事件计入 skippedEvents', () {
      final parsed = IcsImportParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260921T080000
END:VEVENT
BEGIN:VEVENT
SUMMARY:没有开始时间
END:VEVENT
END:VCALENDAR
''');
      expect(parsed.events, isEmpty);
      expect(parsed.skippedEvents, 2);
    });

    test('非文本内容不会抛异常，只返回空结果', () {
      final parsed = IcsImportParser.parse('这不是日历文件');
      expect(parsed.events, isEmpty);
      expect(IcsImportParser.toCourses(parsed.events, _monday), isEmpty);
    });

    test('非 WEEKLY 的 RRULE 只取首次发生并计数', () {
      final parsed = IcsImportParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260921T080000
DTEND:20260921T094000
SUMMARY:按月重复
RRULE:FREQ=MONTHLY;COUNT=6
END:VEVENT
END:VCALENDAR
''');
      expect(parsed.unsupportedRepeats, 1);
      final courses = IcsImportParser.toCourses(parsed.events, _monday);
      expect(courses.single.weeks, '4(周)');
    });

    test('课程 id 唯一', () {
      final parsed = IcsImportParser.parse(_simpleIcs);
      final courses = IcsImportParser.toCourses(parsed.events, _monday);
      expect(courses.map((c) => c.id).toSet(), hasLength(courses.length));
    });
  });
}

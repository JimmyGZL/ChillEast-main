import 'dart:convert';
import 'dart:io' as io;

import 'package:ChillEast/features/timetable/models/course_model.dart';
import 'package:ChillEast/features/timetable/models/timetable_rule_model.dart';
import 'package:ChillEast/features/timetable/parsers/ics_import_parser.dart';
import 'package:ChillEast/features/timetable/services/timetable_import_service.dart';
import 'package:ChillEast/features/timetable/services/timetable_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 真实教务导出的 .xls 样例。
final Uint8List _fixtureBytes =
    io.File('test/fixtures/timetable_sample.xls').readAsBytesSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory tempDir;
  late TimetableStorage storage;
  final service = TimetableImportService();

  setUpAll(() async {
    tempDir = await io.Directory.systemTemp.createTemp('timetable-import-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = TimetableStorage();
    await storage.deleteTimetable();
    await storage.deleteMetadata();
    await storage.deleteCourseList();
    await storage.deleteRawCourseList();
    await storage.deleteRules();
  });

  group('TimetableImportService.parseBytes', () {
    test('解析真实 .xls：19 门课 + 学期 + 默认地点', () {
      final parsed = service.parseBytes(_fixtureBytes);
      expect(parsed.courses, hasLength(19));
      expect(parsed.semester, '2026-2027-1');
      expect(parsed.defaultClassroom, '示例楼');
    });

    test('.xlsx（ZIP 容器）给出「不支持」而不是「格式错误」', () {
      final zip = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]);
      expect(
        () => service.parseBytes(zip),
        throwsA(isA<TimetableImportException>().having(
          (error) => error.failure,
          'failure',
          TimetableImportFailure.xlsxUnsupported,
        )),
      );
    });

    test('普通文件判定为 unsupportedFormat', () {
      final junk = Uint8List.fromList(List<int>.filled(1024, 0x7A));
      expect(
        () => service.parseBytes(junk),
        throwsA(isA<TimetableImportException>().having(
          (error) => error.failure,
          'failure',
          TimetableImportFailure.unsupportedFormat,
        )),
      );
    });

    test('过短的输入不会崩溃，按 unsupportedFormat 处理', () {
      expect(
        () => service.parseBytes(Uint8List.fromList([0xD0, 0xCF])),
        throwsA(isA<TimetableImportException>()),
      );
    });
  });

  group('TimetableImportService 的 .ics 支持', () {
    const ics = '''
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20260831T080000
DTEND:20260831T094000
SUMMARY:高等数学
LOCATION:一教101
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT
END:VCALENDAR
''';

    test('按文件头识别 .ics（不依赖扩展名）', () {
      expect(
        TimetableImportService.looksLikeIcs(
          Uint8List.fromList(utf8.encode(ics)),
        ),
        isTrue,
      );
      // 前面有 BOM / 空行也能认出来
      expect(
        TimetableImportService.looksLikeIcs(
          Uint8List.fromList(utf8.encode('\uFEFF\n$ics')),
        ),
        isTrue,
      );
      expect(
        TimetableImportService.looksLikeIcs(_fixtureBytes),
        isFalse,
      );
      expect(
        TimetableImportService.looksLikeIcs(Uint8List(0)),
        isFalse,
      );
    });

    test('parseIcsBytes 解析出事件与建议的第一周周一', () {
      final parsed =
          service.parseIcsBytes(Uint8List.fromList(utf8.encode(ics)));
      expect(parsed.events, hasLength(1));
      expect(parsed.events.single.name, '高等数学');
      expect(parsed.events.single.repeatCount, 3);
    });

    test('没有可导入事件时抛出 noCourses', () {
      final empty = Uint8List.fromList(
        utf8.encode('BEGIN:VCALENDAR\nEND:VCALENDAR\n'),
      );
      expect(
        () => service.parseIcsBytes(empty),
        throwsA(isA<TimetableImportException>().having(
          (error) => error.failure,
          'failure',
          TimetableImportFailure.noCourses,
        )),
      );
    });

    test('persistCourses 把 ICS 课程写入本地课表', () async {
      final parsed =
          service.parseIcsBytes(Uint8List.fromList(utf8.encode(ics)));
      final courses = await service.persistCourses(
        courses: IcsImportParser.toCourses(
          parsed.events,
          DateTime(2026, 8, 31),
        ),
        semester: '2026-2027-1',
        firstWeekMonday: DateTime(2026, 8, 31),
      );

      expect(courses, hasLength(1));
      expect(courses.single.weeks, '1-3(周)');
      expect(await storage.hasLocalTimetable(), isTrue);
      expect(await storage.readRawCourseList(), hasLength(1));

      final generated = await storage.readTimetable();
      expect(generated, contains('SUMMARY:高等数学'));
    });

    test('真实 .xls → 导出 ICS → 用 ICS 再导入，课程完全一致', () async {
      final firstWeekMonday = DateTime(2026, 8, 31);

      // 1. 导入真实 .xls
      final fromXls = service.parseBytes(_fixtureBytes);
      expect(fromXls.courses, hasLength(19));

      // 2. 落盘并拿到生成的 ICS
      final persisted = await service.persistCourses(
        courses: fromXls.courses,
        semester: '2026-2027-1',
        firstWeekMonday: firstWeekMonday,
      );
      final exported = await storage.readTimetable();
      expect(exported, isNotNull);

      // 3. 把导出的 ICS 当成外部文件再导入一次
      final fromIcs =
          service.parseIcsBytes(Uint8List.fromList(utf8.encode(exported!)));
      final restored = IcsImportParser.toCourses(
        fromIcs.events,
        firstWeekMonday,
      );

      String fingerprint(List<CourseModel> list) => (list
              .map((c) => '${c.name}|${c.teacher}|${c.classroom}|${c.weeks}|'
                  '${c.dayOfWeek}|${c.startPeriod}|${c.endPeriod}')
              .toList()
            ..sort())
          .join('\n');

      expect(fingerprint(restored), fingerprint(persisted));
      expect(restored, hasLength(persisted.length));
    });
  });

  group('TimetableImportService.persist', () {
    test('写入 raw 基准 / courses.json / ICS / 元数据', () async {
      final parsed = service.parseBytes(_fixtureBytes);
      final courses = await service.persist(
        parsed: parsed,
        semester: '2026-2027-1',
        // 故意传周四：应被归一到该周周一 2026-08-31
        firstWeekMonday: DateTime(2026, 9, 3),
      );

      expect(courses, hasLength(19));
      expect(await storage.hasLocalTimetable(), isTrue);
      expect(await storage.hasRawCourseList(), isTrue);
      expect(await storage.readRawCourseList(), hasLength(19));
      expect(await storage.readCourseList(), hasLength(19));

      final ics = await storage.readTimetable();
      expect(ics, contains('BEGIN:VCALENDAR'));
      expect(ics, contains('SUMMARY:课程A'));
      // 第 4 周周一 = 2026-08-31 + 21 天 = 2026-09-21，第 1-2 节 08:00 开始
      expect(ics, contains('DTSTART:20260921T080000'));

      final metadata = await storage.readMetadata();
      expect(metadata, isNotNull);
      expect(metadata!['semester'], '2026-2027-1');
      expect(
        DateTime.parse(metadata['firstWeekMonday'] as String),
        DateTime(2026, 8, 31),
      );
    });

    test('导入后用户已有的调课/停课规则仍然生效', () async {
      await storage.saveRules([
        TimetableRule.createSuspension(
          startWeek: 4,
          endWeek: 4,
          courseName: '课程A',
        ),
      ]);

      final parsed = service.parseBytes(_fixtureBytes);
      final courses = await service.persist(
        parsed: parsed,
        semester: '2026-2027-1',
        firstWeekMonday: DateTime(2026, 8, 31),
      );

      // 第 4 周被停掉，原来的 4-6,9-14 变成 5-6,9-14
      final engineering = courses.firstWhere(
        (course) =>
            course.name == '课程A' &&
            course.dayOfWeek == 1 &&
            course.startPeriod == 1,
      );
      expect(engineering.weeks, '5-6,9-14(周)');
    });

    test('重复导入同一文件结果稳定（不会叠加课程）', () async {
      final parsed = service.parseBytes(_fixtureBytes);
      await service.persist(
        parsed: parsed,
        semester: '2026-2027-1',
        firstWeekMonday: DateTime(2026, 8, 31),
      );
      final second = await service.persist(
        parsed: parsed,
        semester: '2026-2027-1',
        firstWeekMonday: DateTime(2026, 8, 31),
      );
      expect(second, hasLength(19));
      expect(await storage.readRawCourseList(), hasLength(19));
    });
  });
}

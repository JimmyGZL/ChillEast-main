import 'dart:io';
import 'dart:typed_data';

import 'package:ChillEast/features/timetable/models/course_model.dart';
import 'package:ChillEast/features/timetable/parsers/sheet_grid.dart';
import 'package:ChillEast/features/timetable/parsers/timetable_sheet_parser.dart';
import 'package:ChillEast/features/timetable/parsers/xls_biff_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实教务导出的 .xls 样例（OLE2 + BIFF8，单工作表，含合并单元格）。
File get _fixture => File('test/fixtures/timetable_sample.xls');

void main() {
  group('XlsBiffReader 读取 .xls', () {
    late List<SheetGrid> sheets;

    setUpAll(() {
      sheets = XlsBiffReader.read(_fixture.readAsBytesSync());
    });

    test('读出一张工作表且行列数正确', () {
      expect(sheets, hasLength(1));
      expect(sheets.single.name, '甲班');
      expect(sheets.single.rowCount, 14);
      expect(sheets.single.columnCount, 13);
    });

    test('共享字符串(SST)中的中文正确解码', () {
      final sheet = sheets.single;
      expect(sheet.at(0, 1), startsWith('示例大学'));
      expect(sheet.at(0, 1), contains('2026-2027学年第一学期课表'));
      expect(sheet.at(1, 1), '上课地点：示例楼');
      expect(sheet.at(2, 1), '时间');
    });

    test('表格结构与合并区域正确', () {
      final sheet = sheets.single;
      // 星期表头
      expect(sheet.at(2, 2), '星期一');
      expect(sheet.at(2, 4), '星期二');
      expect(sheet.at(2, 6), '星期三');
      expect(sheet.at(2, 8), '星期四');
      expect(sheet.at(2, 10), '星期五');
      // 第一大节
      expect(sheet.at(3, 1), '第一大节\n8:00-9:40');
      // 「第五大节」占用两行
      expect(sheet.at(10, 1), '第五大节\n19:30-21:10');
      expect(sheet.at(11, 1), isNull);

      expect(sheet.merges, hasLength(9));
      expect(
        sheet.merges,
        contains(const CellRange(
            rowFirst: 10, rowLast: 11, colFirst: 1, colLast: 1)),
      );
      expect(
        sheet.merges,
        contains(const CellRange(
            rowFirst: 2, rowLast: 2, colFirst: 2, colLast: 3)),
      );
    });

    test('课程单元格的多行文本与全角标点完整保留', () {
      final cell = sheets.single.at(3, 3);
      expect(cell, isNotNull);
      final lines = cell!.split('\n');
      expect(lines[0], '课程A');
      expect(lines[1], '教师甲 教师乙 教师丙 教师丁');
      expect(lines[2], '（4-6，9-14周）');
      expect(lines[3], '地点：示例楼101');
      expect(lines[4], '总学时：72');
    });

    test('非 .xls 内容抛出 XlsFormatException', () {
      expect(
        () => XlsBiffReader.read(
          Uint8List.fromList(List<int>.filled(2048, 0x41)),
        ),
        throwsA(isA<XlsFormatException>()),
      );
    });
  });

  group('TimetableSheetParser 解析 .xls 课表', () {
    late ParsedTimetable parsed;

    setUpAll(() {
      final sheet = XlsBiffReader.read(_fixture.readAsBytesSync()).single;
      parsed = TimetableSheetParser.parse(sheet);
    });

    test('解析出全部 19 门课', () {
      expect(parsed.courses, hasLength(19));
      expect(parsed.skippedCells, 0);
    });

    test('标题、学期与默认地点', () {
      expect(parsed.title, contains('示例大学'));
      expect(parsed.title, contains('2026-2027学年第一学期课表'));
      expect(parsed.semester, '2026-2027-1');
      expect(parsed.defaultClassroom, '示例楼');
    });

    test('星期与节次换算正确', () {
      // 周一第 1-2 节：课程A
      final mondayFirst = _find(parsed.courses, '课程A', 1, 1);
      expect(mondayFirst, isNotNull);
      expect(mondayFirst!.startPeriod, 1);
      expect(mondayFirst.endPeriod, 2);
      expect(mondayFirst.periods, '01-02');

      // 周四第 9-10 节：课程G强化班（第五大节）
      final english = _find(parsed.courses, '课程G强化班', 4, 9);
      expect(english, isNotNull);
      expect(english!.startPeriod, 9);
      expect(english.endPeriod, 10);

      // 周五第 3-4 节：课程C
      final design = _find(parsed.courses, '课程C', 5, 3);
      expect(design, isNotNull);
      expect(design!.startPeriod, 3);
      expect(design.endPeriod, 4);
    });

    test('周次解析兼容全角/半角逗号', () {
      final engineering = _find(parsed.courses, '课程A', 1, 1)!;
      expect(engineering.weeks, '4-6,9-14(周)');

      final design = _find(parsed.courses, '课程C', 5, 1)!;
      expect(design.weeks, '9-16(周)');

      // 单元格里是全角逗号「4-5，10周」，另一个是半角「4-5,10周」
      final practiceMonday = _find(parsed.courses, '课程F-课堂教学', 2, 7)!;
      final practiceWednesday = _find(parsed.courses, '课程F-课堂教学', 3, 7)!;
      expect(practiceMonday.weeks, '4-5,10(周)');
      expect(practiceWednesday.weeks, '4-5,10(周)');
    });

    test('教师与教室解析正确', () {
      final engineering = _find(parsed.courses, '课程A', 1, 1)!;
      expect(engineering.teacher, '教师甲 教师乙 教师丙 教师丁');
      expect(engineering.classroom, '示例楼101');

      // 单教师
      final ethics = _find(parsed.courses, '课程E', 2, 5)!;
      expect(ethics.teacher, '教师卯');

      // 没有「地点」行时回退到表格声明的统一上课地点
      final english = _find(parsed.courses, '课程G强化班', 4, 9)!;
      expect(english.teacher, 'Alpha / Beta / Gamma');
      expect(english.classroom, '示例楼');
    });

    test('课程 id 唯一', () {
      final ids = parsed.courses.map((course) => course.id).toSet();
      expect(ids, hasLength(parsed.courses.length));
    });
  });

  group('TimetableSheetParser 边界情况', () {
    test('没有星期表头时抛出 noDayHeader', () {
      final sheet = SheetGrid(
        name: 'sheet',
        cells: [
          ['随便', '写点'],
          ['东西', null],
        ],
      );
      expect(
        () => TimetableSheetParser.parse(sheet),
        throwsA(isA<TimetableSheetException>().having(
          (e) => e.error,
          'error',
          TimetableSheetError.noDayHeader,
        )),
      );
    });

    test('有表头但没课时抛出 noCourses', () {
      final sheet = SheetGrid(
        name: 'sheet',
        cells: [
          ['时间', '星期一', null, '星期二', null, '星期三'],
          ['第一大节', null, null, null, null, null],
        ],
      );
      expect(
        () => TimetableSheetParser.parse(sheet),
        throwsA(isA<TimetableSheetException>().having(
          (e) => e.error,
          'error',
          TimetableSheetError.noCourses,
        )),
      );
    });

    test('无法识别周次的单元格计入 skippedCells 而不是静默丢弃', () {
      final sheet = SheetGrid(
        name: 'sheet',
        cells: [
          ['时间', '星期一', null, '星期二', null, '星期三'],
          [
            '第一大节\n8:00-9:40',
            null,
            '高等数学\n张三\n（1-16周）\n地点：一教101',
            null,
            '缺周次的坏数据\n李四',
            null,
          ],
        ],
      );
      final parsed = TimetableSheetParser.parse(sheet);
      expect(parsed.courses, hasLength(1));
      expect(parsed.courses.single.name, '高等数学');
      expect(parsed.courses.single.teacher, '张三');
      expect(parsed.courses.single.classroom, '一教101');
      expect(parsed.courses.single.dayOfWeek, 1);
      expect(parsed.skippedCells, 1);
    });

    test('支持单周/双周，且没有「第X大节」时按时间兜底', () {
      final sheet = SheetGrid(
        name: 'sheet',
        cells: [
          ['时间', '星期一', '星期二', '星期三'],
          [
            '第一大节\n8:00-9:40',
            '单周课\n老师\n（1-6单周）',
            '双周课\n老师\n（1-6双周）',
            '普通课\n老师\n（1-2周）',
          ],
          // 该行只有时间没有「第X大节」，21:10 应按作息表映射到第 6 大节
          ['21:10-23:00', null, null, '夜间课\n老师\n（1-2周）'],
        ],
      );
      final parsed = TimetableSheetParser.parse(sheet);

      final odd = parsed.courses.firstWhere((c) => c.name == '单周课');
      expect(odd.weeks, '1,3,5(周)');
      final even = parsed.courses.firstWhere((c) => c.name == '双周课');
      expect(even.weeks, '2,4,6(周)');

      expect(parsed.courses.firstWhere((c) => c.name == '普通课').startPeriod, 1);
      final night = parsed.courses.firstWhere((c) => c.name == '夜间课');
      expect(night.startPeriod, 11);
      expect(night.endPeriod, 12);
    });

    test('「教师：xxx」标签行也能取到教师', () {
      final sheet = SheetGrid(
        name: 'sheet',
        cells: [
          ['时间', '星期一', null, '星期二', null, '星期三'],
          [
            '第一大节\n8:00-9:40',
            null,
            '线性代数\n教师：王五\n（1-8周）',
            null,
            null,
            null,
          ],
        ],
      );
      final parsed = TimetableSheetParser.parse(sheet);
      expect(parsed.courses.single.teacher, '王五');
      expect(parsed.courses.single.name, '线性代数');
    });
  });
}

/// 按 名称 + 星期 + 起始节次 查找课程。
CourseModel? _find(
  List<CourseModel> courses,
  String name,
  int dayOfWeek,
  int startPeriod,
) {
  for (final course in courses) {
    if (course.name == name &&
        course.dayOfWeek == dayOfWeek &&
        course.startPeriod == startPeriod) {
      return course;
    }
  }
  return null;
}

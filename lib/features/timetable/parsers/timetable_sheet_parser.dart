/// 把「课表样式的表格网格」解析成 [CourseModel] 列表。
///
/// 解析是**结构化**的，不依赖固定的行列坐标：
/// 1. 找表头行（含「星期一…星期日」），按表头把列切成每一天；
/// 2. 表头下方的每一行，从左侧时间列读出「第X大节 / 8:00-9:40」，
///    换算成节次区间；
/// 3. 某一天所在列范围内的非空单元格即一门课，单元格内用换行分栏：
///    课程名 / 教师 / （周次） / 地点：xxx / 学时：xx。
///
/// 这样同一格式换班级、换学期、增删课程都不需要改代码。
library;

import '../models/course_model.dart';
import '../utils/week_parser.dart';
import 'sheet_grid.dart';

/// 解析失败的原因，便于 UI 做本地化提示。
enum TimetableSheetError {
  /// 表格里找不到「星期X」表头。
  noDayHeader,

  /// 找到了表头，但一门课都没解析出来。
  noCourses,
}

class TimetableSheetException implements Exception {
  const TimetableSheetException(this.error, {this.detail});

  final TimetableSheetError error;
  final String? detail;

  @override
  String toString() => 'TimetableSheetException($error, $detail)';
}

/// 解析结果。
class ParsedTimetable {
  const ParsedTimetable({
    required this.courses,
    this.title,
    this.semester,
    this.defaultClassroom,
    this.skippedCells = 0,
  });

  final List<CourseModel> courses;

  /// 表格顶部的标题，例如「湖南农业大学…2026-2027学年第一学期课表」。
  final String? title;

  /// 从标题里推断出的学期，格式与 App 既有约定一致（如 `2026-2027-1`）。
  final String? semester;

  /// 表格里声明的统一上课地点，单元格没写地点时作为兜底。
  final String? defaultClassroom;

  /// 因为没有可识别的周次而被跳过的单元格数量。
  final int skippedCells;

  bool get isEmpty => courses.isEmpty;
}

/// 课表网格解析器。
class TimetableSheetParser {
  const TimetableSheetParser._();

  /// 星期表头：星期一 / 周一 / 星期天 …
  static final RegExp _dayHeader = RegExp(r'^周([一二三四五六日天])$|^星期([一二三四五六日天])$');

  /// 「第X大节」中的中文数字。
  static const Map<String, int> _chineseNumbers = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };

  static final RegExp _bigSection = RegExp(r'第\s*([一二三四五六七八九十\d]{1,3})\s*大节');
  static final RegExp _periodRange = RegExp(r'第?\s*(\d{1,2})\s*[-~－—]\s*(\d{1,2})\s*节');
  static final RegExp _periodSingle = RegExp(r'第\s*(\d{1,2})\s*节');
  static final RegExp _clock = RegExp(r'(\d{1,2})\s*[:：]\s*(\d{2})');
  static final RegExp _weeksLine = RegExp(r'^[（(【\[]?[^（）()【】\[\]]*周[）)】\]]?$');
  static final RegExp _locationLine = RegExp(r'^(上课)?(地点|教室|上课地点)\s*[:：]\s*(.+)$');
  static final RegExp _teacherLine = RegExp(r'^(任课教师|授课教师|教师)\s*[:：]\s*(.+)$');
  static final RegExp _ignoredLine = RegExp(r'^(总?学时|学分|课程代码|课程性质|备注)\s*[:：]');

  static const int _maxColumns = 256;
  static const int _maxRows = 4096;

  /// 解析一张工作表。
  static ParsedTimetable parse(SheetGrid sheet) {
    if (sheet.isEmpty) {
      throw const TimetableSheetException(TimetableSheetError.noCourses);
    }

    final header = _findHeaderRow(sheet);
    if (header == null) {
      throw const TimetableSheetException(TimetableSheetError.noDayHeader);
    }

    final days = _buildDayColumns(sheet, header.row);
    if (days.isEmpty) {
      throw const TimetableSheetException(TimetableSheetError.noDayHeader);
    }

    final sections = _findSections(sheet, header.row, days.first.startColumn);
    if (sections.isEmpty) {
      throw const TimetableSheetException(
        TimetableSheetError.noCourses,
        detail: '未找到大节/时间行',
      );
    }

    final rowSection = _mapRowsToSections(sheet, sections);
    final meta = _readMetadata(sheet, header.row);

    final courses = <CourseModel>[];
    var skipped = 0;
    final seenIds = <String>{};

    for (var row = header.row + 1; row < sheet.rowCount; row++) {
      final section = rowSection[row];
      if (section == null) continue;

      for (final day in days) {
        for (var column = day.startColumn;
            column <= day.endColumn && column < sheet.columnCount;
            column++) {
          final text = sheet.at(row, column);
          if (text == null) continue;

          // 只处理「区域主格」，避免合并单元格被重复读取
          final owner = sheet.ownerRangeAt(row, column);
          if (owner != null && (owner.rowFirst != row || owner.colFirst != column)) {
            continue;
          }

          final content = _parseCourseCell(text, meta.defaultClassroom);
          if (content == null) {
            skipped++;
            continue;
          }

          // 单元格纵向合并时，节次区间要覆盖所有被合并的大节
          var startPeriod = section.startPeriod;
          var endPeriod = section.endPeriod;
          if (owner != null && owner.spansRows) {
            final lastSection = rowSection[owner.rowLast];
            if (lastSection != null) endPeriod = lastSection.endPeriod;
          }

          final id = _buildId(
            seenIds,
            sheet.name,
            day.dayOfWeek,
            startPeriod,
            endPeriod,
            content.name,
          );

          courses.add(CourseModel(
            id: id,
            name: content.name,
            teacher: content.teacher,
            classroom: content.classroom,
            weeks: content.weeks,
            periods: '${startPeriod.toString().padLeft(2, '0')}-'
                '${endPeriod.toString().padLeft(2, '0')}',
            dayOfWeek: day.dayOfWeek,
            startPeriod: startPeriod,
            endPeriod: endPeriod,
          ));
          break; // 同一天同一大节只取第一个非空单元格
        }
      }
    }

    if (courses.isEmpty) {
      throw const TimetableSheetException(TimetableSheetError.noCourses);
    }

    return ParsedTimetable(
      courses: courses,
      title: meta.title,
      semester: meta.semester,
      defaultClassroom: meta.defaultClassroom,
      skippedCells: skipped,
    );
  }

  // -------------------------------------------------------------------------
  // 表头与列切分
  // -------------------------------------------------------------------------

  static _HeaderRow? _findHeaderRow(SheetGrid sheet) {
    _HeaderRow? best;
    final rowLimit = sheet.rowCount < _maxRows ? sheet.rowCount : _maxRows;
    for (var row = 0; row < rowLimit; row++) {
      final matches = <int, int>{};
      for (var column = 0;
          column < sheet.columnCount && column < _maxColumns;
          column++) {
        final text = sheet.at(row, column);
        if (text == null) continue;
        final day = dayOfWeekFromLabel(text);
        if (day != null) matches[column] = day;
      }
      if (matches.length >= 3 &&
          (best == null || matches.length > best.matches.length)) {
        best = _HeaderRow(row, matches);
      }
    }
    return best;
  }

  /// 把「星期一」这类文本转成 1-7，无法识别返回 null。
  static int? dayOfWeekFromLabel(String text) {
    final match = _dayHeader.firstMatch(text.replaceAll(RegExp(r'\s+'), ''));
    if (match == null) return null;
    final character = match.group(1) ?? match.group(2);
    if (character == null) return null;
    if (character == '日' || character == '天') return 7;
    return _chineseNumbers[character];
  }

  /// 按表头把列切成每一天。每天的列范围从自己的表头列开始，
  /// 到下一个表头列的前一列结束（这样即使节假日占用了多列也能覆盖）。
  static List<_DayColumn> _buildDayColumns(SheetGrid sheet, int headerRow) {
    final headers = <int, int>{};
    for (var column = 0;
        column < sheet.columnCount && column < _maxColumns;
        column++) {
      final text = sheet.at(headerRow, column);
      if (text == null) continue;
      final day = dayOfWeekFromLabel(text);
      if (day != null) headers[column] = day;
    }
    if (headers.isEmpty) return const [];

    final columns = headers.keys.toList()..sort();
    final result = <_DayColumn>[];
    for (var i = 0; i < columns.length; i++) {
      final column = columns[i];
      final owner = sheet.ownerRangeAt(headerRow, column);
      var start = owner != null ? owner.colFirst : column;
      if (start > column) start = column;
      final end = i + 1 < columns.length ? columns[i + 1] - 1 : sheet.columnCount - 1;
      result.add(_DayColumn(
        dayOfWeek: headers[column]!,
        startColumn: start,
        endColumn: end < start ? start : end,
      ));
    }
    result.sort((a, b) => a.dayOfWeek.compareTo(b.dayOfWeek));
    return result;
  }

  // -------------------------------------------------------------------------
  // 大节 / 节次
  // -------------------------------------------------------------------------

  /// 在左侧时间列里找出所有大节行，并换算成节次区间。
  static List<_Section> _findSections(
    SheetGrid sheet,
    int headerRow,
    int firstDayColumn,
  ) {
    final sections = <_Section>[];
    final rowLimit = sheet.rowCount < _maxRows ? sheet.rowCount : _maxRows;
    final columnLimit = firstDayColumn < _maxColumns ? firstDayColumn : _maxColumns;

    for (var row = headerRow + 1; row < rowLimit; row++) {
      for (var column = 0; column < columnLimit; column++) {
        final text = sheet.at(row, column);
        if (text == null) continue;
        final periods = _periodsFromLabel(text);
        if (periods == null) continue;
        sections.add(_Section(
          row: row,
          startPeriod: periods.$1,
          endPeriod: periods.$2,
        ));
        break;
      }
    }
    return sections;
  }

  /// 从「第一大节 8:00-9:40」这类标签里解析出节次区间。
  static (int, int)? _periodsFromLabel(String text) {
    final bigMatch = _bigSection.firstMatch(text);
    if (bigMatch != null) {
      final ordinal = _intFromChinese(bigMatch.group(1));
      if (ordinal != null && ordinal >= 1 && ordinal <= 12) {
        return (ordinal * 2 - 1, ordinal * 2);
      }
    }

    final rangeMatch = _periodRange.firstMatch(text);
    if (rangeMatch != null) {
      final start = int.tryParse(rangeMatch.group(1)!);
      final end = int.tryParse(rangeMatch.group(2)!);
      if (start != null && end != null && start >= 1 && end >= start) {
        return (start, end);
      }
    }

    final singleMatch = _periodSingle.firstMatch(text);
    if (singleMatch != null) {
      final period = int.tryParse(singleMatch.group(1)!);
      if (period != null && period >= 1) return (period, period);
    }

    // 退而求其次：按开始时间匹配 App 既有的作息表
    final clock = _clock.firstMatch(text);
    if (clock != null) {
      final hour = int.tryParse(clock.group(1)!);
      final minute = int.tryParse(clock.group(2)!);
      if (hour != null && minute != null) {
        final bigSection = _bigSectionFromClock(hour * 60 + minute);
        if (bigSection != null) {
          return (bigSection * 2 - 1, bigSection * 2);
        }
      }
    }
    return null;
  }

  /// 用 App 的作息表把「开始时间」映射到大节序号（容忍 ±20 分钟误差）。
  static int? _bigSectionFromClock(int minutes) {
    const starts = <int, int>{
      1: 8 * 60,
      2: 10 * 60 + 5,
      3: 14 * 60 + 30,
      4: 16 * 60 + 35,
      5: 19 * 60 + 30,
      6: 21 * 60 + 20,
    };
    int? best;
    var bestDistance = 21;
    starts.forEach((section, startMinutes) {
      final distance = (startMinutes - minutes).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = section;
      }
    });
    return best;
  }

  /// 把「行 → 大节」铺满整张表，便于处理跨行合并的课程。
  static Map<int, _Section> _mapRowsToSections(
    SheetGrid sheet,
    List<_Section> sections,
  ) {
    final map = <int, _Section>{};
    for (var i = 0; i < sections.length; i++) {
      final section = sections[i];
      var endRow = i + 1 < sections.length
          ? sections[i + 1].row - 1
          : sheet.rowCount - 1;
      if (endRow < section.row) endRow = section.row;

      // 大节标签自身如果纵向合并（如「第五大节」占两行），按合并范围收敛
      final owner = sheet.ownerRangeAt(section.row, _timeColumnOf(sheet, section.row));
      if (owner != null && owner.rowLast > section.row && owner.rowLast < endRow) {
        endRow = owner.rowLast;
      }

      for (var row = section.row; row <= endRow; row++) {
        map[row] = section;
      }
    }
    return map;
  }

  /// 找到某一行里大节标签所在的列（用于读取该单元格的合并范围）。
  static int _timeColumnOf(SheetGrid sheet, int row) {
    for (var column = 0;
        column < sheet.columnCount && column < _maxColumns;
        column++) {
      final text = sheet.at(row, column);
      if (text != null && _periodsFromLabel(text) != null) return column;
    }
    return 0;
  }

  // -------------------------------------------------------------------------
  // 单元格内容
  // -------------------------------------------------------------------------

  /// 解析一门课的单元格文本；无法识别（如没有周次）时返回 null。
  static _CourseContent? _parseCourseCell(
    String raw,
    String? defaultClassroom,
  ) {
    final lines = raw
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;

    // 备注、学时之类单独成行的信息不计入课程结构
    final content = <String>[];
    String? classroom;
    String? labeledTeacher;
    for (final line in lines) {
      final location = _locationLine.firstMatch(line);
      if (location != null) {
        final value = location.group(3)!.trim();
        if (value.isNotEmpty) classroom ??= value;
        continue;
      }
      final teacher = _teacherLine.firstMatch(line);
      if (teacher != null) {
        final value = teacher.group(2)!.trim();
        if (value.isNotEmpty) labeledTeacher ??= value;
        continue;
      }
      if (_ignoredLine.hasMatch(line)) continue;
      content.add(line);
    }
    if (content.isEmpty) return null;

    // 周次行：「（4-6，9-14周）」是这一格式里最稳定的锚点
    var weeksIndex = -1;
    for (var i = 0; i < content.length; i++) {
      if (_isWeeksLine(content[i])) {
        weeksIndex = i;
        break;
      }
    }
    if (weeksIndex <= 0) return null;

    final weeks = _parseWeeks(content[weeksIndex]);
    if (weeks.isEmpty) return null;

    final nameLines = content.sublist(0, weeksIndex);
    String name;
    String teacher;
    if (nameLines.length == 1) {
      // 只有一行：没有教师信息（可能写在「教师：xxx」标签行里）
      name = nameLines.first;
      teacher = labeledTeacher ?? '';
    } else {
      // 紧挨着周次行的那一行是教师；再往上是课程名（可能被换行拆开）
      teacher = labeledTeacher ?? nameLines.last;
      name = nameLines.sublist(0, nameLines.length - 1).join();
    }
    name = _compactSpaces(name);
    if (name.isEmpty) return null;

    return _CourseContent(
      name: name,
      teacher: _compactSpaces(teacher),
      weeks: WeekParser.formatWeeksForCourse(weeks),
      classroom: _compactSpaces(classroom ?? defaultClassroom ?? ''),
    );
  }

  static bool _isWeeksLine(String line) {
    if (!line.contains('周')) return false;
    return _weeksLine.hasMatch(line);
  }

  /// 解析周次表达式，兼容全角/半角括号与逗号，以及「单周 / 双周」。
  static List<int> _parseWeeks(String raw) {
    var text = raw;
    bool? oddOnly;
    if (text.contains('单周')) {
      oddOnly = true;
      text = text.replaceAll('单周', '');
    } else if (text.contains('双周')) {
      oddOnly = false;
      text = text.replaceAll('双周', '');
    }

    text = text
        .replaceAll(RegExp(r'[（(【\[]'), '')
        .replaceAll(RegExp(r'[）)】\]]'), '')
        .replaceAll('第', '')
        .replaceAll('周', '')
        .replaceAll('，', ',')
        .replaceAll('、', ',')
        .replaceAll('至', '-')
        .replaceAll(RegExp(r'\s+'), '');

    var weeks = WeekParser.parseWeeks(text);
    if (oddOnly == true) {
      weeks = weeks.where((week) => week.isOdd).toList();
    } else if (oddOnly == false) {
      weeks = weeks.where((week) => week.isEven).toList();
    }
    return weeks;
  }

  static String _compactSpaces(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  // -------------------------------------------------------------------------
  // 标题 / 学期 / 默认地点
  // -------------------------------------------------------------------------

  static _SheetMeta _readMetadata(SheetGrid sheet, int headerRow) {
    String? title;
    String? defaultClassroom;

    for (var row = 0; row < headerRow && row < sheet.rowCount; row++) {
      for (var column = 0;
          column < sheet.columnCount && column < _maxColumns;
          column++) {
        final text = sheet.at(row, column);
        if (text == null) continue;
        final location = _locationLine.firstMatch(text);
        if (location != null) {
          defaultClassroom ??= location.group(3)!.trim();
          continue;
        }
        if (title == null && text.contains('课表')) {
          title = _compactSpaces(text.replaceAll(RegExp(r'[\r\n]+'), ' '));
        }
      }
    }

    if (defaultClassroom != null && defaultClassroom.isEmpty) {
      defaultClassroom = null;
    }

    return _SheetMeta(
      title: title,
      semester: _semesterFromTitle(title),
      defaultClassroom: defaultClassroom,
    );
  }

  /// 从标题里推断学期，例如「2026-2027学年第一学期」→ `2026-2027-1`。
  static String? _semesterFromTitle(String? title) {
    if (title == null) return null;
    final match = RegExp(r'(\d{4})\s*[-—~～]\s*(\d{4})\s*学年\s*第\s*([一二])\s*学期')
        .firstMatch(title);
    if (match == null) return null;
    final term = match.group(3) == '一' ? 1 : 2;
    return '${match.group(1)}-${match.group(2)}-$term';
  }

  /// 生成稳定且唯一的课程 id。
  static String _buildId(
    Set<String> seen,
    String sheetName,
    int dayOfWeek,
    int startPeriod,
    int endPeriod,
    String name,
  ) {
    final base = '$sheetName-$dayOfWeek-$startPeriod-$endPeriod-$name';
    var candidate = base;
    var suffix = 1;
    while (!seen.add(candidate)) {
      suffix++;
      candidate = '$base#$suffix';
    }
    return candidate;
  }

  static int? _intFromChinese(String? text) {
    if (text == null || text.isEmpty) return null;
    final direct = int.tryParse(text);
    if (direct != null) return direct;
    if (text.length == 1) return _chineseNumbers[text];
    // 十一 / 十二 这类两位数
    if (text.startsWith('十')) {
      final rest = text.substring(1);
      final unit = rest.isEmpty ? 0 : _chineseNumbers[rest];
      if (unit == null) return null;
      return 10 + unit;
    }
    return null;
  }
}

class _HeaderRow {
  const _HeaderRow(this.row, this.matches);

  final int row;
  final Map<int, int> matches;
}

class _DayColumn {
  const _DayColumn({
    required this.dayOfWeek,
    required this.startColumn,
    required this.endColumn,
  });

  final int dayOfWeek;
  final int startColumn;
  final int endColumn;
}

class _Section {
  const _Section({
    required this.row,
    required this.startPeriod,
    required this.endPeriod,
  });

  final int row;
  final int startPeriod;
  final int endPeriod;
}

class _CourseContent {
  const _CourseContent({
    required this.name,
    required this.teacher,
    required this.weeks,
    required this.classroom,
  });

  final String name;
  final String teacher;
  final String weeks;
  final String classroom;
}

class _SheetMeta {
  const _SheetMeta({
    required this.title,
    required this.semester,
    required this.defaultClassroom,
  });

  final String? title;
  final String? semester;
  final String? defaultClassroom;
}

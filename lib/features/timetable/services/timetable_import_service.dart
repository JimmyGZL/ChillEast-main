import 'dart:convert';
import 'dart:typed_data';

import '../models/course_model.dart';
import '../parsers/ics_import_parser.dart';
import '../parsers/sheet_grid.dart';
import '../parsers/timetable_sheet_parser.dart';
import '../parsers/xls_biff_reader.dart';
import 'timetable_rule_service.dart';
import 'timetable_storage.dart';

/// 导入外部课表文件时的失败原因，供 UI 做本地化提示。
enum TimetableImportFailure {
  /// 既不是 Excel 97-2003（.xls），也不是日历（.ics）。
  unsupportedFormat,

  /// 是 .xlsx（ZIP 容器），当前不支持。
  xlsxUnsupported,

  /// 能打开，但表格里没有「星期X」表头，不像课表。
  notATimetable,

  /// 格式能识别，但一门课都没解析出来。
  noCourses,
}

class TimetableImportException implements Exception {
  const TimetableImportException(this.failure, {this.detail});

  final TimetableImportFailure failure;
  final String? detail;

  @override
  String toString() => 'TimetableImportException($failure, $detail)';
}

/// 把外部课表文件（.xls 表格 / .ics 日历）解析并写入本地课表。
///
/// 写入遵循与教务同步一致的数据不变式：
/// - 导入结果作为新的 `raw_courses.json` 基准；
/// - 之后再应用用户已有的调课/停课规则，重新生成 `courses.json` 与 ICS。
class TimetableImportService {
  TimetableImportService({
    TimetableStorage? storage,
    TimetableRuleService? ruleService,
  })  : _storage = storage ?? TimetableStorage(),
        _ruleService = ruleService ?? TimetableRuleService(storage: storage);

  final TimetableStorage _storage;
  final TimetableRuleService _ruleService;

  /// OLE2 复合文档签名（Excel 97-2003 的容器格式）。
  static const List<int> _ole2Signature = [
    0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1,
  ];

  /// 判断是否为 iCalendar 文本（按文件头内容判断，不依赖扩展名）。
  static bool looksLikeIcs(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final length = bytes.length < 1024 ? bytes.length : 1024;
    final head =
        String.fromCharCodes(bytes, 0, length).toUpperCase();
    return head.contains('BEGIN:VCALENDAR');
  }

  /// 解析 `.ics`（只解析，不写盘）。
  ///
  /// 周次需要「第一周周一」才能换算，因此这里只返回事件，
  /// 由调用方选定日期后用 [IcsImportParser.toCourses] 得到课程。
  ParsedIcs parseIcsBytes(Uint8List bytes) {
    final content = _decodeText(bytes);
    final parsed = IcsImportParser.parse(content);
    if (parsed.events.isEmpty) {
      throw const TimetableImportException(TimetableImportFailure.noCourses);
    }
    return parsed;
  }

  /// 解析 `.xls`（只解析，不写盘）。多张工作表时取第一张能解析出课程的。
  ParsedTimetable parseBytes(Uint8List bytes) {
    if (_looksLikeZip(bytes)) {
      throw const TimetableImportException(
        TimetableImportFailure.xlsxUnsupported,
      );
    }
    if (!_looksLikeOle2(bytes)) {
      throw const TimetableImportException(
        TimetableImportFailure.unsupportedFormat,
      );
    }

    final List<SheetGrid> sheets;
    try {
      sheets = XlsBiffReader.read(bytes);
    } on XlsFormatException catch (error) {
      throw TimetableImportException(
        TimetableImportFailure.unsupportedFormat,
        detail: error.message,
      );
    }

    TimetableSheetError? firstError;
    for (final sheet in sheets) {
      try {
        final parsed = TimetableSheetParser.parse(sheet);
        if (parsed.courses.isNotEmpty) return parsed;
      } on TimetableSheetException catch (error) {
        firstError ??= error.error;
      }
    }

    throw TimetableImportException(
      firstError == TimetableSheetError.noDayHeader
          ? TimetableImportFailure.notATimetable
          : TimetableImportFailure.noCourses,
    );
  }

  /// 落盘：写 raw 基准与元数据，再应用已有规则重新生成 courses.json / ICS。
  ///
  /// 返回应用规则后最终的课程列表。
  Future<List<CourseModel>> persist({
    required ParsedTimetable parsed,
    required String semester,
    required DateTime firstWeekMonday,
  }) =>
      persistCourses(
        courses: parsed.courses,
        semester: semester,
        firstWeekMonday: firstWeekMonday,
      );

  /// 同 [persist]，但直接接收课程列表（.ics 导入用）。
  Future<List<CourseModel>> persistCourses({
    required List<CourseModel> courses,
    required String semester,
    required DateTime firstWeekMonday,
  }) async {
    // 统一归一到周一，避免用户选到周中导致整学期平移
    final monday = DateTime(
      firstWeekMonday.year,
      firstWeekMonday.month,
      firstWeekMonday.day,
    ).subtract(Duration(days: firstWeekMonday.weekday - DateTime.monday));

    await _storage.saveRawCourseList(courses);
    await _storage.saveMetadata(semester: semester, firstWeekMonday: monday);
    return _ruleService.applyRulesAndRegenerate();
  }

  /// ICS 多为 UTF-8；个别导出工具用 GBK，用宽松解码兜底避免整文件失败。
  static String _decodeText(Uint8List bytes) {
    try {
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  static bool _looksLikeOle2(Uint8List bytes) {
    if (bytes.length < _ole2Signature.length) return false;
    for (var i = 0; i < _ole2Signature.length; i++) {
      if (bytes[i] != _ole2Signature[i]) return false;
    }
    return true;
  }

  /// ZIP 头（`PK`）：.xlsx / .xlsm 都是 ZIP 容器。
  static bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;
}

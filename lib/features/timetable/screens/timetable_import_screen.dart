import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/date_format_utils.dart';
import '../../../core/utils/l10n_extension.dart';
import '../../profile/providers/settings_provider.dart';
import '../models/course_model.dart';
import '../parsers/ics_import_parser.dart';
import '../parsers/timetable_sheet_parser.dart';
import '../services/timetable_import_service.dart';
import '../services/timetable_storage.dart';
import '../utils/timetable_form_utils.dart';

/// 从本地课表文件（教务导出的 .xls 表格 / .ics 日历）导入课表。
///
/// 导入成功后 `Navigator.pop(true)`，由课表页负责刷新。
class TimetableImportScreen extends ConsumerStatefulWidget {
  const TimetableImportScreen({super.key});

  @override
  ConsumerState<TimetableImportScreen> createState() =>
      _TimetableImportScreenState();
}

class _TimetableImportScreenState extends ConsumerState<TimetableImportScreen> {
  final TimetableImportService _service = TimetableImportService();
  final TimetableStorage _storage = TimetableStorage();

  late final List<String> _semesters = generateSemesters();

  String? _fileName;
  bool _parsing = false;
  bool _importing = false;

  /// .xls 的解析结果。
  ParsedTimetable? _parsed;

  /// .ics 的解析结果（周次要等用户选定第一周周一才能换算）。
  ParsedIcs? _ics;

  TimetableImportException? _failure;

  String? _selectedSemester;
  DateTime? _selectedDate;
  int _existingRuleCount = 0;

  bool get _busy => _parsing || _importing;

  /// 当前可导入的课程列表。ICS 随第一周周一变化而重算。
  List<CourseModel> get _previewCourses {
    final parsed = _parsed;
    if (parsed != null) return parsed.courses;

    final ics = _ics;
    if (ics != null && _selectedDate != null) {
      return IcsImportParser.toCourses(ics.events, _selectedDate!);
    }
    return const [];
  }

  /// ICS 已选文件但还没选第一周周一。
  bool get _icsWaitingForDate =>
      _ics != null && _selectedDate == null && _ics!.events.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_semesters.isNotEmpty) _selectedSemester = _semesters.first;
  }

  // ---------------------------------------------------------------------------
  // 选文件 → 解析
  // ---------------------------------------------------------------------------

  Future<void> _pickFile() async {
    if (_busy) return;
    setState(() {
      _failure = null;
    });

    FilePickerResult? picked;
    try {
      // 用 any 而不是限定扩展名：部分机型把 .xls 上报成 octet-stream，
      // 限定扩展名会导致文件根本选不中；格式合法性改用文件头判断。
      picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
    } catch (error) {
      if (mounted) _showError(context.l10n.importFailed(error.toString()));
      return;
    }
    if (picked == null || picked.files.isEmpty) return; // 用户取消

    final file = picked.files.single;
    final bytes = await _readBytes(file);
    if (!mounted) return;
    if (bytes == null) {
      _showError(context.l10n.importFileReadFailed);
      return;
    }

    setState(() {
      _parsing = true;
      _fileName = file.name;
      _parsed = null;
      _ics = null;
    });

    try {
      if (TimetableImportService.looksLikeIcs(bytes)) {
        final ics = _service.parseIcsBytes(bytes);
        final ruleCount = await _readRuleCount();
        if (!mounted) return;
        setState(() {
          _ics = ics;
          _existingRuleCount = ruleCount;
          // ICS 的周次必须靠第一周周一换算，能反推就先替用户填上
          _selectedDate ??= ics.suggestedFirstWeekMonday;
        });
      } else {
        final parsed = _service.parseBytes(bytes);
        final ruleCount = await _readRuleCount();
        if (!mounted) return;
        setState(() {
          _parsed = parsed;
          _existingRuleCount = ruleCount;
          final semester = parsed.semester;
          if (semester != null && _semesters.contains(semester)) {
            _selectedSemester = semester;
          }
        });
      }
    } on TimetableImportException catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = error;
      });
    } finally {
      if (mounted) {
        setState(() {
          _parsing = false;
        });
      }
    }
  }

  Future<int> _readRuleCount() async {
    try {
      return (await _storage.readRules()).length;
    } catch (_) {
      return 0; // 规则读不到不影响导入
    }
  }

  /// 优先用 FilePicker 直接给到的字节，拿不到再按路径读。
  Future<Uint8List?> _readBytes(PlatformFile file) async {
    if (file.bytes != null) return file.bytes;
    final path = file.path;
    if (path == null) return null;
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  String _failureMessage(TimetableImportException failure) {
    final l10n = context.l10n;
    switch (failure.failure) {
      case TimetableImportFailure.unsupportedFormat:
        return l10n.importErrorUnsupportedFormat;
      case TimetableImportFailure.xlsxUnsupported:
        return l10n.importErrorXlsx;
      case TimetableImportFailure.notATimetable:
        return l10n.importErrorNotATimetable;
      case TimetableImportFailure.noCourses:
        return l10n.importErrorNoCourses;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 写入
  // ---------------------------------------------------------------------------

  bool get _canImport =>
      _previewCourses.isNotEmpty &&
      _selectedSemester != null &&
      _selectedDate != null &&
      !_busy;

  Future<void> _confirm() async {
    final courses = _previewCourses;
    if (courses.isEmpty || _selectedSemester == null || _selectedDate == null) {
      return;
    }
    setState(() {
      _importing = true;
    });
    final l10n = context.l10n;

    try {
      await _service.persistCourses(
        courses: courses,
        semester: _selectedSemester!,
        firstWeekMonday: _selectedDate!,
      );
      // 课表变了，重排上课提醒
      await ref.read(settingsProvider.notifier).rescheduleNotifications();

      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.timetableImportSuccess),
          backgroundColor: const Color(0xFF09C489),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      _showError(l10n.importFailed(error.toString()));
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final isDark = theme.brightness == Brightness.dark;
    final hasFile = _parsed != null || _ics != null;
    final courses = _previewCourses;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: theme.scaffoldBackgroundColor,
          elevation: 0,
          surfaceTintColor: theme.scaffoldBackgroundColor,
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: Icon(
              Icons.close,
              color: _busy
                  ? (isDark ? Colors.grey[800] : Colors.grey[300])
                  : (isDark ? Colors.white70 : const Color(0xFF5F6368)),
            ),
            onPressed: _busy ? null : () => Navigator.pop(context),
          ),
          title: Text(
            l10n.importTimetableTitle,
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF202124),
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 8),
            Text(
              l10n.importTimetableHint,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : const Color(0xFF9E9E9E),
              ),
            ),
            const SizedBox(height: 16),
            _buildFilePicker(theme, isDark),
            if (_failure != null) ...[
              const SizedBox(height: 20),
              _buildFailure(theme, _failure!),
            ],
            if (hasFile) ...[
              const SizedBox(height: 24),
              _buildSummary(theme, isDark, courses),
              const SizedBox(height: 24),
              _buildSemesterField(theme),
              const SizedBox(height: 20),
              _buildDateField(theme),
              if (_icsWaitingForDate) ...[
                const SizedBox(height: 12),
                _buildIcsDateHint(theme, isDark),
              ],
              const SizedBox(height: 28),
              Text(
                l10n.importPreviewTitle,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF202124),
                ),
              ),
              const SizedBox(height: 10),
              if (courses.isEmpty && _icsWaitingForDate)
                Text(
                  l10n.importPreviewNeedsDate,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : const Color(0xFF9E9E9E),
                  ),
                )
              else
                ..._buildPreview(theme, isDark, courses),
              const SizedBox(height: 24),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_importing)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.primaryColor,
                      ),
                    ),
                  ),
                ElevatedButton.icon(
                  onPressed: _canImport ? _confirm : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        theme.primaryColor.withOpacity(0.12),
                    disabledForegroundColor:
                        theme.primaryColor.withOpacity(0.38),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    minimumSize: const Size(88, 36),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text(
                    l10n.importButton,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
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

  Widget _buildFilePicker(ThemeData theme, bool isDark) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _pickFile,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            side: BorderSide(
              color: isDark ? Colors.white24 : const Color(0xFFDADCE0),
            ),
            foregroundColor: theme.primaryColor,
          ),
          icon: _parsing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.upload_file_outlined, size: 20),
          label: Text(
            _parsing ? l10n.importParsing : l10n.importPickFile,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
        ),
        if (_fileName != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 16,
                color: isDark ? Colors.white38 : const Color(0xFF9E9E9E),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _fileName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : const Color(0xFF5F6368),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildFailure(ThemeData theme, TimetableImportException failure) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: Colors.red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _failureMessage(failure),
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(
    ThemeData theme,
    bool isDark,
    List<CourseModel> courses,
  ) {
    final l10n = context.l10n;
    final parsed = _parsed;
    final ics = _ics;

    final lines = <String>[
      if (courses.isNotEmpty) l10n.importCourseCount(courses.length),
      if (parsed != null && parsed.skippedCells > 0)
        l10n.importSkippedCount(parsed.skippedCells),
      if (ics != null && ics.skippedEvents > 0)
        l10n.importSkippedEvents(ics.skippedEvents),
      if (ics != null && ics.unsupportedRepeats > 0)
        l10n.importUnsupportedRepeats(ics.unsupportedRepeats),
      if (_existingRuleCount > 0) l10n.importRulesNotice(_existingRuleCount),
      l10n.importOverwriteNotice,
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.05) : const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (parsed?.title != null) ...[
            Text(
              parsed!.title!,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF202124),
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '· ',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : const Color(0xFF9E9E9E),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF5F6368),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: isDark ? Colors.white70 : const Color(0xFF5F6368),
        fontWeight: FontWeight.w400,
        fontSize: 14,
      ),
      floatingLabelStyle: TextStyle(
        color: theme.primaryColor,
        fontWeight: FontWeight.bold,
        fontSize: 16,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.auto,
      prefixIcon: Icon(icon, size: 20),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(
          color: isDark ? Colors.white24 : const Color(0xFFDADCE0),
          width: 1,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(
          color: isDark ? Colors.white24 : const Color(0xFFDADCE0),
          width: 1,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: theme.primaryColor, width: 2),
      ),
      filled: true,
      fillColor: isDark ? Colors.white.withOpacity(0.05) : Colors.white,
    );
  }

  Widget _buildSemesterField(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return DropdownButtonFormField<String>(
      value: _selectedSemester,
      decoration: _inputDecoration(
        context.l10n.academicSemester,
        Icons.calendar_today_outlined,
      ),
      isExpanded: true,
      icon: Icon(
        Icons.arrow_drop_down,
        color: isDark ? Colors.white70 : const Color(0xFF5F6368),
      ),
      dropdownColor: theme.cardColor,
      borderRadius: BorderRadius.circular(6),
      items: _semesters
          .map((semester) => DropdownMenuItem(
                value: semester,
                child: Text(semester, style: const TextStyle(fontSize: 15)),
              ))
          .toList(),
      onChanged: _busy
          ? null
          : (value) {
              setState(() {
                _selectedSemester = value;
              });
            },
    );
  }

  Widget _buildDateField(ThemeData theme) {
    return InkWell(
      onTap: _busy ? null : _selectDate,
      borderRadius: BorderRadius.circular(6),
      child: IgnorePointer(
        child: TextFormField(
          controller: TextEditingController(
            text: _selectedDate != null
                ? formatYMMMd(
                    _selectedDate!,
                    Localizations.localeOf(context).toString(),
                  )
                : '',
          ),
          decoration: _inputDecoration(
            context.l10n.firstWeekMonday,
            Icons.date_range_outlined,
          ).copyWith(
            hintText: context.l10n.selectDateHint,
            suffixIcon: const Icon(Icons.edit_calendar_outlined, size: 18),
          ),
          readOnly: true,
        ),
      ),
    );
  }

  Future<void> _selectDate() async {
    final picked = await pickFirstWeekMonday(context, initial: _selectedDate);
    if (picked != null && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  /// ICS 必须靠第一周周一才能把日历日期换算成周次。
  Widget _buildIcsDateHint(ThemeData theme, bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 16,
          color: theme.primaryColor,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            context.l10n.importIcsNeedFirstWeekMonday,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: isDark ? Colors.white60 : const Color(0xFF5F6368),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildPreview(
    ThemeData theme,
    bool isDark,
    List<CourseModel> courses,
  ) {
    final l10n = context.l10n;
    final weekdayNames = [
      l10n.weekdayMon,
      l10n.weekdayTue,
      l10n.weekdayWed,
      l10n.weekdayThu,
      l10n.weekdayFri,
      l10n.weekdaySat,
      l10n.weekdaySun,
    ];

    final byDay = <int, List<CourseModel>>{};
    for (final course in courses) {
      (byDay[course.dayOfWeek] ??= <CourseModel>[]).add(course);
    }
    final days = byDay.keys.toList()..sort();

    final widgets = <Widget>[];
    for (final day in days) {
      final dayCourses = byDay[day]!
        ..sort((a, b) => a.startPeriod.compareTo(b.startPeriod));
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Text(
          day >= 1 && day <= 7 ? weekdayNames[day - 1] : '$day',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: theme.primaryColor,
          ),
        ),
      ));
      for (final course in dayCourses) {
        widgets.add(_buildPreviewRow(theme, isDark, course));
      }
    }
    return widgets;
  }

  Widget _buildPreviewRow(ThemeData theme, bool isDark, CourseModel course) {
    final details = <String>[
      if (course.teacher.isNotEmpty) course.teacher,
      if (course.classroom.isNotEmpty) course.classroom,
      course.weeks,
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.05) : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFECEDEF),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              context.l10n.periodsRange(course.startPeriod, course.endPeriod),
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : const Color(0xFF9E9E9E),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  course.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF202124),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    color: isDark ? Colors.white54 : const Color(0xFF9E9E9E),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

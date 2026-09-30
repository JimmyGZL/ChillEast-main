import 'package:ChillEast/features/timetable/models/course_model.dart';
import 'package:ChillEast/features/timetable/utils/date_calculator.dart';
import 'package:ChillEast/features/timetable/widgets/weekly_calendar_view.dart';
import 'package:ChillEast/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _course = CourseModel(
  id: 'c1',
  name: '高等数学',
  teacher: '张老师',
  classroom: '十教南101',
  weeks: '1-16(周)',
  periods: '01-02',
  dayOfWeek: 1,
  startPeriod: 1,
  endPeriod: 2,
);

void main() {
  Future<void> pumpView(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WeeklyCalendarView(
            courses: const [_course],
            firstWeekMonday: DateTime(2026, 8, 31),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('左侧时间轴同时显示上课与下课时间，且与统一作息表一致', (tester) async {
    await pumpView(tester);

    for (var big = 1; big <= 6; big++) {
      final parts = DateCalculator.getBigSectionTimeRange(big).split('-');
      expect(parts, hasLength(2));

      expect(
        find.text(parts[0]),
        findsAtLeastNWidgets(1),
        reason: '第 $big 大节缺少上课时间 ${parts[0]}',
      );
      expect(
        find.text(parts[1]),
        findsAtLeastNWidgets(1),
        reason: '第 $big 大节缺少下课时间 ${parts[1]}',
      );
    }
  });

  testWidgets('单页至少有 12 个时间标签（6 大节 × 上下课）', (tester) async {
    await pumpView(tester);

    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .where((value) => RegExp(r'^\d{2}:\d{2}$').hasMatch(value))
        .toList();

    // PageView 可能预建相邻页，所以用下界
    expect(labels.length, greaterThanOrEqualTo(12));
  });
}

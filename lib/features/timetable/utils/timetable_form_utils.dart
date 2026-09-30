import 'package:flutter/material.dart';

import '../../../core/utils/l10n_extension.dart';

/// 生成可供选择的学年学期列表，最近的排在最前。
///
/// - 1-6 月：最新学期是 `(x-1)-x-2`（当前学年第二学期）
/// - 7-12 月：最新学期是 `x-(x+1)-1`（新学年第一学期）
List<String> generateSemesters({DateTime? now}) {
  final today = now ?? DateTime.now();
  final year = today.year;
  final list = <String>[];

  if (today.month <= 6) {
    final startYear = year - 1;
    for (var i = 0; i < 5; i++) {
      final value = startYear - i;
      list.add('$value-${value + 1}-2');
      list.add('$value-${value + 1}-1');
    }
  } else {
    final startYear = year;
    for (var i = 0; i < 5; i++) {
      final value = startYear - i;
      list.add('$value-${value + 1}-1');
      list.add('${value - 1}-$value-2');
    }
  }
  return list;
}

/// 取某天所在周的周一（只保留年月日）。
DateTime mondayOfWeek(DateTime date) {
  final daysFromMonday = date.weekday - DateTime.monday;
  final monday = date.subtract(Duration(days: daysFromMonday));
  return DateTime(monday.year, monday.month, monday.day);
}

/// 弹出日期选择器选择「第一周周一」，返回归一化到周一的结果；取消返回 null。
Future<DateTime?> pickFirstWeekMonday(
  BuildContext context, {
  DateTime? initial,
}) async {
  final now = DateTime.now();
  final picked = await showDatePicker(
    context: context,
    initialDate: initial ?? now,
    firstDate: DateTime(now.year - 1),
    lastDate: DateTime(now.year + 1),
    helpText: context.l10n.selectFirstWeekMondayHelp,
    builder: (context, child) {
      return Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).brightness == Brightness.dark
              ? const ColorScheme.dark(
                  primary: Colors.orange,
                  onPrimary: Colors.black,
                  surface: Color(0xFF1E1E1E),
                )
              : ColorScheme.light(
                  primary: Theme.of(context).primaryColor,
                  onPrimary: Colors.white,
                  surface: Colors.white,
                  onSurface: const Color(0xFF202124),
                ),
        ),
        child: child!,
      );
    },
  );
  if (picked == null) return null;
  return mondayOfWeek(picked);
}

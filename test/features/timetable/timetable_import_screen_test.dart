import 'package:ChillEast/features/timetable/screens/timetable_import_screen.dart';
import 'package:ChillEast/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester, {Locale locale = const Locale('zh')}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TimetableImportScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('导入页初始状态：可以选文件，导入按钮禁用', (tester) async {
    await pumpScreen(tester);

    expect(find.text('导入课表'), findsOneWidget);
    expect(find.text('选择课表文件'), findsOneWidget);

    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '导入'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('导入页在英文语言下也能正常渲染', (tester) async {
    await pumpScreen(tester, locale: const Locale('en'));

    expect(find.text('Import timetable'), findsOneWidget);
    expect(find.text('Choose timetable file'), findsOneWidget);
  });
}

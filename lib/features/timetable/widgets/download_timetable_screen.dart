import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/state/auth_state.dart';
import '../../../../core/utils/date_format_utils.dart';
import '../../../../core/utils/l10n_extension.dart';
import '../../auth/screens/login_screen.dart';
import '../services/timetable_service.dart';
import '../utils/timetable_form_utils.dart';
import '../../profile/providers/settings_provider.dart';

/// 导入课表页面
class DownloadTimetableScreen extends ConsumerStatefulWidget {
  const DownloadTimetableScreen({super.key});

  @override
  ConsumerState<DownloadTimetableScreen> createState() => _DownloadTimetableScreenState();
}

class _DownloadTimetableScreenState extends ConsumerState<DownloadTimetableScreen> {
  final TimetableService _timetableService = TimetableService();
  
  String? _selectedSemester;
  DateTime? _selectedDate;
  bool _isLoading = false;
  String _syncStatus = '';
  
  late final List<String> _semesters;

  @override
  void initState() {
    super.initState();
    _semesters = generateSemesters();
    if (_semesters.isNotEmpty) {
      _selectedSemester = _semesters.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    // 标准 MD2 输入框装饰样式
    InputDecoration md2InputDecoration(String label, IconData icon) => InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : const Color(0xFF5F6368), 
        fontWeight: FontWeight.w400, 
        fontSize: 14
      ),
      floatingLabelStyle: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.bold, fontSize: 16),
      floatingLabelBehavior: FloatingLabelBehavior.auto,
      prefixIcon: Icon(icon, size: 20),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(
          color: Theme.of(context).brightness == Brightness.dark ? Colors.white24 : const Color(0xFFDADCE0), 
          width: 1
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(
          color: Theme.of(context).brightness == Brightness.dark ? Colors.white24 : const Color(0xFFDADCE0), 
          width: 1
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: theme.primaryColor, width: 2),
      ),
      filled: true,
      fillColor: Theme.of(context).brightness == Brightness.dark ? Colors.white.withOpacity(0.05) : Colors.white,
    );

    return PopScope(
      canPop: !_isLoading, // 加载中时禁用手势/物理返回
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          elevation: 0,
          surfaceTintColor: Theme.of(context).scaffoldBackgroundColor,
          automaticallyImplyLeading: false, // 禁用默认返回
          leading: IconButton(
            icon: Icon(
              Icons.close, 
              color: _isLoading 
                  ? (Theme.of(context).brightness == Brightness.dark ? Colors.grey[800] : Colors.grey[300]) 
                  : (Theme.of(context).brightness == Brightness.dark ? Colors.white70 : const Color(0xFF5F6368))
            ),
            onPressed: _isLoading ? null : () => Navigator.pop(context),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              
              // 学年学期选择
              DropdownButtonFormField<String>(
                value: _selectedSemester,
                decoration: md2InputDecoration(context.l10n.academicSemester, Icons.calendar_today_outlined),
                isExpanded: true,
                icon: Icon(
                  Icons.arrow_drop_down, 
                  color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : const Color(0xFF5F6368)
                ),
                dropdownColor: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(6),
                items: _semesters.map((semester) {
                  return DropdownMenuItem(
                    value: semester,
                    child: Text(semester, style: const TextStyle(fontSize: 15)),
                  );
                }).toList(),
                onChanged: _isLoading ? null : (value) {
                  setState(() {
                    _selectedSemester = value;
                  });
                },
              ),
              
              const SizedBox(height: 28),
              
              // 第一周周一日期选择
              InkWell(
                onTap: _isLoading ? null : _selectDate,
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
                    decoration: md2InputDecoration(context.l10n.firstWeekMonday, Icons.date_range_outlined).copyWith(
                      hintText: context.l10n.selectDateHint,
                      suffixIcon: const Icon(Icons.edit_calendar_outlined, size: 18),
                    ),
                    readOnly: true,
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_isLoading)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _syncStatus,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.primaryColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                    ),
                  ),
                ElevatedButton.icon(
                  onPressed: (_canConfirm() && !_isLoading) ? _confirm : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: theme.primaryColor.withOpacity(0.12),
                    disabledForegroundColor: theme.primaryColor.withOpacity(0.38),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    minimumSize: const Size(88, 36),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(
                    context.l10n.importButton,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _canConfirm() => _selectedSemester != null && _selectedDate != null;
  
  Future<void> _selectDate() async {
    final picked = await pickFirstWeekMonday(context, initial: _selectedDate);
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _confirm() async {
    if (_selectedSemester == null || _selectedDate == null) return;
    
    final authState = ref.read(authStateProvider);
    if (authState.status != AuthStatus.authenticated) {
      await Navigator.push(context, LoginScreen.route());
      
      final newAuthState = ref.read(authStateProvider);
      if (newAuthState.status != AuthStatus.authenticated) return;
    }
    
    setState(() { _isLoading = true; });
    final l10n = context.l10n;
    
    try {
      await _timetableService.downloadAndSaveTimetable(
        semester: _selectedSemester!,
        firstWeekMonday: _selectedDate!,
        onProgress: (status) {
          if (mounted) {
            setState(() { _syncStatus = status; });
          }
        },
      );
      
      // ✨ 导入成功后，重新安排上课提醒通知
      await ref.read(settingsProvider.notifier).rescheduleNotifications();
      
      if (mounted) {
        // 先返回 true 给上一级页面，通知导入成功
        Navigator.of(context).pop(true);
        
        // 在全局提示成功
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.timetableImportSuccess), 
            backgroundColor: const Color(0xFF09C489),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.importFailed(e.toString())), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() { _isLoading = false; });
    }
  }
}

/// 从表格文件（.xls / .xlsx）读出的通用单元格网格。
///
/// 行、列下标均从 0 开始，与 Excel 的 A1 表示法一致（A1 → 行 0 列 0）。
/// 读取器只负责「把表格变成网格 + 合并区域」，课表语义由
/// `TimetableSheetParser` 负责，两者解耦以便单独测试。
class CellRange {
  const CellRange({
    required this.rowFirst,
    required this.rowLast,
    required this.colFirst,
    required this.colLast,
  });

  final int rowFirst;
  final int rowLast;
  final int colFirst;
  final int colLast;

  int get rowSpan => rowLast - rowFirst + 1;
  int get colSpan => colLast - colFirst + 1;

  bool get isSingleCell => rowSpan == 1 && colSpan == 1;
  bool get spansRows => rowSpan > 1;
  bool get spansColumns => colSpan > 1;

  bool contains(int row, int col) =>
      row >= rowFirst && row <= rowLast && col >= colFirst && col <= colLast;

  bool containsRow(int row) => row >= rowFirst && row <= rowLast;

  @override
  bool operator ==(Object other) =>
      other is CellRange &&
      other.rowFirst == rowFirst &&
      other.rowLast == rowLast &&
      other.colFirst == colFirst &&
      other.colLast == colLast;

  @override
  int get hashCode => Object.hash(rowFirst, rowLast, colFirst, colLast);

  @override
  String toString() => 'CellRange(r$rowFirst-$rowLast, c$colFirst-$colLast)';
}

/// 一张工作表的只读视图。
class SheetGrid {
  SheetGrid({
    required this.name,
    required List<List<String?>> cells,
    List<CellRange> merges = const [],
  })  : cells = List<List<String?>>.unmodifiable(
          cells.map((row) => List<String?>.unmodifiable(row)),
        ),
        merges = List<CellRange>.unmodifiable(merges);

  /// 工作表名（例如「1班」）。
  final String name;

  /// 行优先的单元格原始文本；null 表示空单元格。
  final List<List<String?>> cells;

  /// 合并区域，按读取顺序排列。
  final List<CellRange> merges;

  int get rowCount => cells.length;

  int get columnCount =>
      cells.fold<int>(0, (max, row) => row.length > max ? row.length : max);

  bool get isEmpty => cells.isEmpty;

  /// 原始文本（未 trim），越界返回 null。
  String? rawAt(int row, int col) {
    if (row < 0 || col < 0 || row >= cells.length) return null;
    final line = cells[row];
    if (col >= line.length) return null;
    return line[col];
  }

  /// 归一化文本：null / 纯空白都返回 null，其余 trim 后返回。
  String? at(int row, int col) {
    final value = rawAt(row, col);
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 该行所有非空单元格的列号，按列升序。
  List<int> nonEmptyColumns(int row) {
    if (row < 0 || row >= cells.length) return const [];
    final line = cells[row];
    final result = <int>[];
    for (var col = 0; col < line.length; col++) {
      final value = line[col];
      if (value != null && value.trim().isNotEmpty) result.add(col);
    }
    return result;
  }

  /// 覆盖 (row, col) 的合并区域；没有合并时返回 null。
  CellRange? mergedRangeAt(int row, int col) {
    for (final range in merges) {
      if (range.contains(row, col)) return range;
    }
    return null;
  }

  /// 覆盖 (row, col) 的合并区域，且 (row, col) 必须是该区域的左上角，
  /// 否则返回 null。用于判断「这块内容是不是区域主格」。
  CellRange? ownerRangeAt(int row, int col) {
    final range = mergedRangeAt(row, col);
    if (range == null) return null;
    return (range.rowFirst == row && range.colFirst == col) ? range : null;
  }
}

/// 纯 Dart 的 Excel 97-2003（OLE2 + BIFF8）`.xls` 只读解析器。
///
/// 不依赖任何第三方包，只用于把课表文件读成 [SheetGrid]。
/// 支持：SST 共享字符串（含跨 CONTINUE 分片）、LABELSST / LABEL /
/// RK / MULRK / NUMBER / FORMULA+STRING、MERGEDCELLS。
/// 不支持：BIFF5 及更早版本、加密文件、多字节码页的非 Unicode 字符串。
library;

import 'dart:typed_data';

import 'sheet_grid.dart';

/// `.xls` 解析失败时抛出，调用方可直接用于提示用户。
class XlsFormatException implements Exception {
  const XlsFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// BIFF 记录类型。
class _Biff {
  static const int eof = 0x000A;
  static const int formula = 0x0006;
  static const int string = 0x0207;
  static const int dimensions = 0x0200;
  static const int blank = 0x0201;
  static const int number = 0x0203;
  static const int label = 0x0204;
  static const int mulRk = 0x00BD;
  static const int mulBlank = 0x00BE;
  static const int rk = 0x027E;
  static const int labelSst = 0x00FD;
  static const int sst = 0x00FC;
  static const int continueRecord = 0x003C;
  static const int boundSheet = 0x0085;
  static const int mergedCells = 0x00E5;
  static const int bof = 0x0809;

  /// BOF 的子流类型。
  static const int dtGlobals = 0x0005;
  static const int dtWorksheet = 0x0010;
}

/// 读取 `.xls` 字节流，返回其中所有工作表网格。
///
/// 失败时抛出 [XlsFormatException]。
class XlsBiffReader {
  const XlsBiffReader._();

  static List<SheetGrid> read(Uint8List bytes) {
    if (bytes.length < 512) {
      throw const XlsFormatException('文件过小，不是有效的 Excel 文件');
    }
    final stream = _CompoundFile(bytes).workbookStream();
    return _BiffWorkbookParser(stream).parse();
  }
}

// ---------------------------------------------------------------------------
// OLE2 / 复合文档（CFB）
// ---------------------------------------------------------------------------

const int _endOfChain = 0xFFFFFFFE;
const int _freeSector = 0xFFFFFFFF;

/// 目录项（128 字节）。
class _DirEntry {
  _DirEntry({
    required this.name,
    required this.objectType,
    required this.startSector,
    required this.streamSize,
  });

  static const int typeStream = 2;
  static const int typeRoot = 5;

  final String name;
  final int objectType;
  final int startSector;
  final int streamSize;

  bool get isStream => objectType == typeStream;
  bool get isRoot => objectType == typeRoot;
}

/// 只实现读取所需的 OLE2 复合文档子集：FAT / MiniFAT / 目录 / 流。
class _CompoundFile {
  _CompoundFile(this._data);

  final Uint8List _data;
  late final ByteData _view = ByteData.sublistView(_data);

  late final int _sectorSize;
  late final int _miniSectorSize;
  late final int _miniStreamCutoff;
  late final List<int> _fat;
  late final List<int> _miniFat;
  late final List<_DirEntry> _entries;
  late final Uint8List _miniStream;

  bool _parsed = false;

  static const List<int> _signature = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

  /// 取出 `Workbook`（或旧名 `Book`）流。
  Uint8List workbookStream() {
    _parse();
    for (final entry in _entries) {
      if (entry.isStream &&
          (entry.name == 'Workbook' || entry.name == 'Book')) {
        return _readStream(entry);
      }
    }
    final names = _entries
        .where((entry) => entry.name.isNotEmpty)
        .map((entry) => '${entry.name}(type=${entry.objectType})')
        .join(', ');
    throw XlsFormatException('未找到 Workbook 数据流，文件可能已损坏。目录项：$names');
  }

  void _parse() {
    if (_parsed) return;
    _parsed = true;

    for (var i = 0; i < _signature.length; i++) {
      if (_data[i] != _signature[i]) {
        throw const XlsFormatException(
            '不是 Excel 97-2003（.xls）文件，请另存为 .xls 后再试');
      }
    }

    final sectorShift = _view.getUint16(30, Endian.little);
    final miniSectorShift = _view.getUint16(32, Endian.little);
    _sectorSize = 1 << sectorShift;
    _miniSectorSize = 1 << miniSectorShift;
    if (_sectorSize < 128 || _sectorSize > 65536) {
      throw const XlsFormatException('Excel 文件扇区大小异常，无法解析');
    }

    final fatSectorCount = _view.getUint32(44, Endian.little);
    final firstDirSector = _view.getUint32(48, Endian.little);
    _miniStreamCutoff = _view.getUint32(56, Endian.little);
    final firstMiniFatSector = _view.getUint32(60, Endian.little);
    final miniFatSectorCount = _view.getUint32(64, Endian.little);
    final firstDifatSector = _view.getUint32(68, Endian.little);

    _fat = _readFat(fatSectorCount, firstDifatSector);
    _entries = _readDirectory(firstDirSector);

    // 小流（< 4096 字节）统一放在 Root Entry 的 mini stream 里，
    // 由 MiniFAT 索引。
    _miniFat = <int>[];
    var sectors = _chain(firstMiniFatSector, _fat);
    if (sectors.length > miniFatSectorCount) {
      sectors = sectors.sublist(0, miniFatSectorCount);
    }
    for (final sector in sectors) {
      final offset = _sectorOffset(sector);
      if (offset + _sectorSize > _data.length) break;
      for (var i = 0; i < _sectorSize ~/ 4; i++) {
        _miniFat.add(_view.getUint32(offset + i * 4, Endian.little));
      }
    }

    Uint8List miniStream = Uint8List(0);
    for (final entry in _entries) {
      if (entry.isRoot) {
        miniStream = _readChainAsBytes(entry.startSector, entry.streamSize, _fat);
        break;
      }
    }
    _miniStream = miniStream;
  }

  List<int> _readFat(int fatSectorCount, int firstDifatSector) {
    final fatSectors = <int>[];

    // 头部内联 109 个 FAT 扇区号
    for (var i = 0; i < 109; i++) {
      final sector = _view.getUint32(76 + i * 4, Endian.little);
      if (sector == _freeSector || sector == _endOfChain) continue;
      fatSectors.add(sector);
    }

    // 超出 109 个时顺着 DIFAT 扇区链继续收集
    final perSector = _sectorSize ~/ 4;
    var next = firstDifatSector;
    var guard = 0;
    while (next != _endOfChain &&
        next != _freeSector &&
        next < _sectorCount &&
        guard++ < 1 << 20) {
      final offset = _sectorOffset(next);
      for (var i = 0; i < perSector - 1; i++) {
        final sector = _view.getUint32(offset + i * 4, Endian.little);
        if (sector == _freeSector || sector == _endOfChain) continue;
        fatSectors.add(sector);
      }
      next = _view.getUint32(offset + (perSector - 1) * 4, Endian.little);
    }

    if (fatSectorCount > 0 && fatSectors.length > fatSectorCount) {
      fatSectors.removeRange(fatSectorCount, fatSectors.length);
    }

    final fat = <int>[];
    for (final sector in fatSectors) {
      final offset = _sectorOffset(sector);
      if (offset + _sectorSize > _data.length) break;
      for (var i = 0; i < _sectorSize ~/ 4; i++) {
        fat.add(_view.getUint32(offset + i * 4, Endian.little));
      }
    }
    if (fat.isEmpty) {
      throw const XlsFormatException('Excel 文件分配表为空，文件可能已损坏');
    }
    return fat;
  }

  List<_DirEntry> _readDirectory(int firstDirSector) {
    final bytes = _readChainAsBytes(firstDirSector, 0, _fat);
    final entries = <_DirEntry>[];
    for (var offset = 0; offset + 128 <= bytes.length; offset += 128) {
      final nameLength = _uint16(bytes, offset + 64);
      if (nameLength < 2 || nameLength > 64) continue;
      final units = <int>[];
      // nameLength 是字节数且包含结尾的 UTF-16 NUL，因此实际字符只有
      // nameLength / 2 - 1 个；多读一个会把 '\u0000' 拼进名字里。
      for (var i = 0; i < nameLength - 2; i += 2) {
        units.add(_uint16(bytes, offset + i));
      }
      entries.add(_DirEntry(
        name: String.fromCharCodes(units).replaceAll('\u0000', ''),
        objectType: bytes[offset + 66],
        startSector: _uint32(bytes, offset + 116),
        streamSize: _uint32(bytes, offset + 120) +
            _uint32(bytes, offset + 124) * 0x100000000,
      ));
    }
    if (entries.isEmpty) {
      throw const XlsFormatException('Excel 文件目录为空，文件可能已损坏');
    }
    return entries;
  }

  Uint8List _readStream(_DirEntry entry) {
    if (entry.streamSize < _miniStreamCutoff) {
      final bytes = _readChainAsBytes(
        entry.startSector,
        entry.streamSize,
        _miniFat,
        mini: true,
      );
      return bytes;
    }
    return _readChainAsBytes(entry.startSector, entry.streamSize, _fat);
  }

  Uint8List _readChainAsBytes(
    int startSector,
    int size,
    List<int> allocation, {
    bool mini = false,
  }) {
    final unit = mini ? _miniSectorSize : _sectorSize;
    final source = mini ? _miniStream : _data;
    final builder = BytesBuilder(copy: false);
    for (final sector in _chain(startSector, allocation, mini: mini)) {
      final offset = mini ? sector * unit : _sectorOffset(sector);
      if (offset < 0 || offset + unit > source.length) break;
      builder.add(Uint8List.sublistView(source, offset, offset + unit));
    }
    final bytes = builder.toBytes();
    if (size > 0 && bytes.length > size) {
      return Uint8List.sublistView(bytes, 0, size);
    }
    return bytes;
  }

  int _sectorOffset(int sector) => (sector + 1) * _sectorSize;

  int get _sectorCount =>
      _data.length > _sectorSize ? (_data.length - _sectorSize) ~/ _sectorSize + 1 : 0;

  /// 顺着分配表展开扇区链，自带环检测与越界保护。
  List<int> _chain(int start, List<int> allocation, {bool mini = false}) {
    final result = <int>[];
    final seen = <int>{};
    final limit = mini ? 1 << 24 : allocation.length;
    var current = start;
    while (current != _endOfChain &&
        current != _freeSector &&
        current >= 0 &&
        current < allocation.length &&
        result.length < limit) {
      if (!seen.add(current)) break;
      result.add(current);
      current = allocation[current];
    }
    return result;
  }
}

int _uint16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _uint32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

// ---------------------------------------------------------------------------
// BIFF8 记录解析
// ---------------------------------------------------------------------------

class _Record {
  const _Record(this.type, this.offset, this.data);

  final int type;

  /// 记录在流中的起始偏移（含 4 字节头），用于 BOUNDSHEET 定位。
  final int offset;
  final Uint8List data;
}

class _BoundSheet {
  const _BoundSheet({required this.name, required this.streamPosition});

  final String name;

  /// 该工作表 BOF 记录在 Workbook 流中的偏移。
  final int streamPosition;
}

/// 正在构建的一张工作表。
class _SheetBuilder {
  final Map<int, Map<int, String>> cells = {};
  final List<CellRange> merges = [];
  int maxRow = -1;
  int maxColumn = -1;

  void set(int row, int column, String value) {
    if (value.isEmpty) return;
    (cells[row] ??= <int, String>{})[column] = value;
    if (row > maxRow) maxRow = row;
    if (column > maxColumn) maxColumn = column;
  }

  void addMerge(CellRange range) {
    merges.add(range);
    if (range.rowLast > maxRow) maxRow = range.rowLast;
    if (range.colLast > maxColumn) maxColumn = range.colLast;
  }

  SheetGrid build(String name) {
    if (maxRow < 0 || maxColumn < 0) {
      return SheetGrid(name: name, cells: const [], merges: merges);
    }
    // 结果只按实际内容分配，绝不按 DIMENSIONS 声明的范围分配，
    // 否则遇到「声明 16384 列」的文件会直接吃爆内存。
    final rows = List<List<String?>>.generate(
      maxRow + 1,
      (_) => List<String?>.filled(maxColumn + 1, null),
      growable: false,
    );
    cells.forEach((row, line) {
      line.forEach((column, value) {
        rows[row][column] = value;
      });
    });
    return SheetGrid(name: name, cells: rows, merges: merges);
  }
}

class _BiffWorkbookParser {
  _BiffWorkbookParser(this._stream);

  final Uint8List _stream;

  final List<String> _sharedStrings = [];
  final List<_BoundSheet> _boundSheets = [];

  /// 按 BOF 偏移索引的工作表构建器。
  final Map<int, _SheetBuilder> _sheets = {};

  /// 工作表 BOF 的出现顺序，用于无法匹配 BOUNDSHEET 时兜底。
  final List<int> _sheetOrder = [];

  List<SheetGrid> parse() {
    final records = _readRecords();
    _SheetBuilder? current;

    for (var i = 0; i < records.length; i++) {
      final record = records[i];

      if (record.type == _Biff.bof) {
        final subStream = record.data.length >= 4
            ? _uint16(record.data, 2)
            : _Biff.dtGlobals;
        if (subStream == _Biff.dtWorksheet) {
          final builder = _SheetBuilder();
          _sheets[record.offset] = builder;
          _sheetOrder.add(record.offset);
          current = builder;
        } else {
          current = null;
        }
        continue;
      }

      if (record.type == _Biff.eof) {
        current = null;
        continue;
      }

      if (current == null) {
        // 全局子流
        if (record.type == _Biff.sst) {
          // SST 的字符数据可能被后续 CONTINUE 记录切分，必须合并后统一解码
          final segments = <Uint8List>[record.data];
          var j = i + 1;
          while (j < records.length &&
              records[j].type == _Biff.continueRecord) {
            segments.add(records[j].data);
            j++;
          }
          i = j - 1;
          _sharedStrings
            ..clear()
            ..addAll(_SstDecoder(segments).decode());
        } else if (record.type == _Biff.boundSheet) {
          _boundSheets.add(_parseBoundSheet(record.data));
        }
        continue;
      }

      _readCellRecord(record, current);
    }

    return _buildSheets();
  }

  List<SheetGrid> _buildSheets() {
    final grids = <SheetGrid>[];
    for (var index = 0; index < _sheetOrder.length; index++) {
      final offset = _sheetOrder[index];
      final builder = _sheets[offset]!;
      grids.add(builder.build(_nameFor(offset, index)));
    }
    return grids;
  }

  String _nameFor(int sheetOffset, int index) {
    for (final sheet in _boundSheets) {
      if (sheet.streamPosition == sheetOffset) {
        return sheet.name.isEmpty ? 'Sheet${index + 1}' : sheet.name;
      }
    }
    // BOUNDSHEET 的 lbPlyPos 对不上（少见）时退回按顺序配对
    if (index < _boundSheets.length) {
      final fallback = _boundSheets[index].name;
      if (fallback.isNotEmpty) return fallback;
    }
    return 'Sheet${index + 1}';
  }

  void _readCellRecord(_Record record, _SheetBuilder sheet) {
    final data = record.data;
    switch (record.type) {
      case _Biff.labelSst:
        if (data.length < 10) return;
        final index = _uint32(data, 6);
        if (index < _sharedStrings.length) {
          sheet.set(_uint16(data, 0), _uint16(data, 2), _sharedStrings[index]);
        }
        return;

      case _Biff.label:
        if (data.length < 9) return;
        sheet.set(
          _uint16(data, 0),
          _uint16(data, 2),
          _readInlineString(data, 6),
        );
        return;

      case _Biff.rk:
        if (data.length < 10) return;
        sheet.set(
          _uint16(data, 0),
          _uint16(data, 2),
          _decodeRk(_uint32(data, 6)),
        );
        return;

      case _Biff.number:
        if (data.length < 14) return;
        sheet.set(
          _uint16(data, 0),
          _uint16(data, 2),
          _formatNumber(_float64(data, 6)),
        );
        return;

      case _Biff.mulRk:
        if (data.length < 12) return;
        final row = _uint16(data, 0);
        final firstColumn = _uint16(data, 2);
        // 末尾 2 字节是 colLast，其余为 (ixfe u16, rk u32) 序列
        final count = (data.length - 6) ~/ 6;
        for (var i = 0; i < count; i++) {
          final base = 4 + i * 6;
          sheet.set(
            row,
            firstColumn + i,
            _decodeRk(_uint32(data, base + 2)),
          );
        }
        return;

      case _Biff.formula:
        if (data.length < 14) return;
        final row = _uint16(data, 0);
        final column = _uint16(data, 2);
        // 8 字节结果：末两字节为 0xFFFF 时表示字符串/布尔/错误等特殊值
        if (data[12] == 0xFF && data[13] == 0xFF) {
          switch (data[6]) {
            case 0x00:
              // 字符串结果位于紧随其后的 STRING 记录，先记下目标单元格
              _awaitingStringCell = (row: row, column: column);
              break;
            case 0x01:
              sheet.set(row, column, data[8] != 0 ? 'TRUE' : 'FALSE');
              break;
            default:
              break; // 错误值等无需展示
          }
        } else {
          sheet.set(row, column, _formatNumber(_float64(data, 6)));
        }
        return;

      case _Biff.string:
        final pending = _awaitingStringCell;
        _awaitingStringCell = null;
        if (pending != null) {
          sheet.set(pending.row, pending.column, _readInlineString(data, 0));
        }
        return;

      case _Biff.mergedCells:
        if (data.length < 2) return;
        final count = _uint16(data, 0);
        for (var i = 0; i < count; i++) {
          final base = 2 + i * 8;
          if (base + 8 > data.length) break;
          final rowFirst = _uint16(data, base);
          final rowLast = _uint16(data, base + 2);
          final colFirst = _uint16(data, base + 4);
          final colLast = _uint16(data, base + 6);
          sheet.addMerge(CellRange(
            rowFirst: rowFirst,
            rowLast: rowLast < rowFirst ? rowFirst : rowLast,
            colFirst: colFirst,
            colLast: colLast < colFirst ? colFirst : colLast,
          ));
        }
        return;

      case _Biff.blank:
      case _Biff.mulBlank:
      case _Biff.dimensions:
        return;

      default:
        return;
    }
  }

  /// FORMULA 的字符串结果位于紧随其后的 STRING 记录中，这里记下待填充的单元格。
  ({int row, int column})? _awaitingStringCell;

  List<_Record> _readRecords() {
    final records = <_Record>[];
    var offset = 0;
    while (offset + 4 <= _stream.length) {
      final type = _uint16(_stream, offset);
      final length = _uint16(_stream, offset + 2);
      final dataStart = offset + 4;
      if (dataStart + length > _stream.length) break;
      records.add(_Record(
        type,
        offset,
        Uint8List.sublistView(_stream, dataStart, dataStart + length),
      ));
      offset = dataStart + length;
    }
    if (records.isEmpty) {
      throw const XlsFormatException('Excel 文件内容为空，未能读取到任何数据');
    }
    return records;
  }

  _BoundSheet _parseBoundSheet(Uint8List data) {
    if (data.length < 8) return const _BoundSheet(name: '', streamPosition: -1);
    final position = _uint32(data, 0);
    final nameLength = data[6];
    final flags = data[7];
    final highByte = (flags & 0x01) != 0;
    final units = <int>[];
    var cursor = 8;
    for (var i = 0; i < nameLength; i++) {
      if (highByte) {
        if (cursor + 1 >= data.length) break;
        units.add(_uint16(data, cursor));
        cursor += 2;
      } else {
        if (cursor >= data.length) break;
        units.add(data[cursor]);
        cursor += 1;
      }
    }
    return _BoundSheet(
      name: String.fromCharCodes(units),
      streamPosition: position,
    );
  }

  /// 解析 XLUnicodeString（LABEL / STRING 记录内联字符串）。
  String _readInlineString(Uint8List data, int offset) {
    if (offset + 3 > data.length) return '';
    final length = _uint16(data, offset);
    final flags = data[offset + 2];
    final highByte = (flags & 0x01) != 0;
    final units = <int>[];
    var cursor = offset + 3;
    for (var i = 0; i < length; i++) {
      if (highByte) {
        if (cursor + 1 >= data.length) break;
        units.add(_uint16(data, cursor));
        cursor += 2;
      } else {
        if (cursor >= data.length) break;
        units.add(data[cursor]);
        cursor += 1;
      }
    }
    return String.fromCharCodes(units);
  }
}

double _float64(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getFloat64(offset, Endian.little);

/// 解码 RK 数值：bit1 表示 30 位整数，bit0 表示需要除以 100。
String _decodeRk(int rk) {
  final isInteger = (rk & 0x02) != 0;
  final divideBy100 = (rk & 0x01) != 0;
  double value;
  if (isInteger) {
    var raw = rk >> 2;
    if ((raw & 0x20000000) != 0) raw -= 0x40000000; // 符号扩展 30 位
    value = raw.toDouble();
  } else {
    // 高 30 位是 IEEE754 双精度的高位，低 34 位为 0
    final buffer = ByteData(8);
    buffer.setUint32(0, rk & 0xFFFFFFFC, Endian.little);
    buffer.setUint32(4, 0, Endian.little);
    value = buffer.getFloat64(0, Endian.little);
  }
  if (divideBy100) value = value / 100;
  return _formatNumber(value);
}

String _formatNumber(double value) {
  if (!value.isFinite) return value.toString();
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toString();
}

// ---------------------------------------------------------------------------
// SST 共享字符串表
// ---------------------------------------------------------------------------

/// 解码 SST 记录。
///
/// SST 的字符串数据可能被 CONTINUE 记录从中间切开：切在「字符数组」中间时，
/// 新记录的第 1 个字节是该串剩余部分的压缩标志；切在富文本格式串或
/// ExtRst 中间时不带标志字节。这里按 MS-XLS 的规则逐段游标读取。
class _SstDecoder {
  _SstDecoder(this._segments);

  final List<Uint8List> _segments;

  int _segment = 0;
  int _position = 0;

  List<String> decode() {
    final result = <String>[];
    if (_segments.isEmpty) return result;
    try {
      _readUint32(); // cstTotal
      final uniqueCount = _readUint32();
      for (var i = 0; i < uniqueCount; i++) {
        if (_exhausted) break;
        result.add(_readString());
      }
    } on _SstUnderflow {
      // 数据不完整时保留已解析出的部分，避免整表失败
    }
    return result;
  }

  bool get _exhausted =>
      _segment >= _segments.length || _position >= _segments[_segment].length;

  int _nextByte() {
    while (_segment < _segments.length &&
        _position >= _segments[_segment].length) {
      _segment++;
      _position = 0;
    }
    if (_segment >= _segments.length) throw const _SstUnderflow();
    return _segments[_segment][_position++];
  }

  int _readUint8() => _nextByte();

  int _readUint16() {
    final low = _nextByte();
    final high = _nextByte();
    return low | (high << 8);
  }

  int _readUint32() {
    final a = _nextByte();
    final b = _nextByte();
    final c = _nextByte();
    final d = _nextByte();
    return a | (b << 8) | (c << 16) | (d << 24);
  }

  String _readString() {
    final charCount = _readUint16();
    final flags = _readUint8();
    var highByte = (flags & 0x01) != 0;
    final hasExtension = (flags & 0x04) != 0;
    final hasRichRuns = (flags & 0x08) != 0;

    final richRunCount = hasRichRuns ? _readUint16() : 0;
    final extensionSize = hasExtension ? _readUint32() : 0;

    final units = <int>[];
    var remaining = charCount;

    while (remaining > 0) {
      if (_position >= _segments[_segment].length) {
        if (_segment + 1 >= _segments.length) break;
        _segment++;
        _position = 0;
        // 跨 CONTINUE 时，首字节是剩余字符的压缩标志
        highByte = (_segments[_segment][_position++] & 0x01) != 0;
      }
      final segment = _segments[_segment];
      final charSize = highByte ? 2 : 1;
      var take = (segment.length - _position) ~/ charSize;
      if (take <= 0) {
        // 段内剩余字节不足以构成一个字符（异常数据），跳到下一段
        _position = segment.length;
        continue;
      }
      if (take > remaining) take = remaining;

      if (highByte) {
        for (var i = 0; i < take; i++) {
          units.add(segment[_position] | (segment[_position + 1] << 8));
          _position += 2;
        }
      } else {
        for (var i = 0; i < take; i++) {
          units.add(segment[_position++]);
        }
      }
      remaining -= take;
    }

    _skip(richRunCount * 4);
    _skip(extensionSize);

    return String.fromCharCodes(units);
  }

  /// 跳过富文本格式串 / ExtRst；跨段时按规范不消费标志字节。
  void _skip(int byteCount) {
    var remaining = byteCount;
    while (remaining > 0 && _segment < _segments.length) {
      final available = _segments[_segment].length - _position;
      if (available <= 0) {
        _segment++;
        _position = 0;
        continue;
      }
      final take = available < remaining ? available : remaining;
      _position += take;
      remaining -= take;
    }
  }
}

class _SstUnderflow implements Exception {
  const _SstUnderflow();
}

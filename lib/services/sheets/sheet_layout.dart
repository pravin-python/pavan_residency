import '../csv_service.dart';

/// The worksheet is not usable as a recipient list.
class SheetFormatException implements Exception {
  const SheetFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where things are in a worksheet: found from its values, never assumed.
class SheetLayout {
  SheetLayout({
    required this.headerAt,
    required this.header,
    required this.emailCol,
    required this.statusCol,
    required this.extraStatusCols,
    required this.width,
  });

  /// 0-based table index of the header row (sheet row = headerAt + 1).
  final int headerAt;
  final List<String> header;

  /// First column that holds recipient emails (0-based).
  final int emailCol;

  /// The existing status column, or null when it has to be created.
  final int? statusCol;

  /// Further columns carrying the same title: never written to, only
  /// reported.
  final List<int> extraStatusCols;

  /// Columns in use, counting data below the header as well. A new status
  /// column goes here, so it can never land on a column that holds data.
  final int width;

  int get headerRow => headerAt + 1;

  /// Whether a header cell is the status column called [statusHeader].
  /// 'Email_Sent', 'email sent' and 'EMAIL SENT' are all the same column.
  static bool matchesStatus(String cell, String statusHeader) {
    final want = CsvService.normHeader(statusHeader);
    if (want.isEmpty) {
      return cell.trim().toLowerCase() == statusHeader.trim().toLowerCase();
    }
    return CsvService.normHeader(cell) == want;
  }

  /// Throws [SheetFormatException] when there is no header row or no email
  /// column.
  static SheetLayout detect(List<List<dynamic>> table, String statusHeader) {
    final at = CsvService.findHeaderRow(table);
    if (at < 0) {
      throw const SheetFormatException(
          'No header row found in this worksheet. The first rows must '
          'contain column titles such as name, email, amount.');
    }
    final header = [for (final c in table[at]) '$c'.trim()];

    int? email;
    final statusCols = <int>[];
    for (var c = 0; c < header.length; c++) {
      if (email == null && CsvService.columnKey(header[c]) == 'email') {
        email = c;
      }
      if (header[c].isNotEmpty && matchesStatus(header[c], statusHeader)) {
        statusCols.add(c);
      }
    }
    if (email == null) {
      throw const SheetFormatException(
          'No email column found. Add a header named email (or email id, '
          'email address).');
    }

    var width = 0;
    for (final row in table) {
      for (var c = row.length - 1; c >= width; c--) {
        if ('${row[c]}'.trim().isNotEmpty) {
          width = c + 1;
          break;
        }
      }
    }
    return SheetLayout(
      headerAt: at,
      header: header,
      emailCol: email,
      statusCol: statusCols.isEmpty ? null : statusCols.first,
      extraStatusCols: statusCols.skip(1).toList(),
      width: width,
    );
  }
}

import '../../models/receipt_data.dart';
import '../csv_service.dart';
import '../sent_log.dart';
import 'sheet_layout.dart';

/// Recipients read from one worksheet.
class SheetLoad {
  SheetLoad({
    required this.layout,
    required this.rows,
    required this.warnings,
  });

  final SheetLayout layout;

  /// Every recipient row (valid or not) in sheet order. Blank rows and
  /// template rows are not listed.
  final List<ReceiptData> rows;
  final List<String> warnings;
}

class SheetRecipientReader {
  /// Turns worksheet [table] (row i = sheet row i + 1) into recipients with
  /// the same rules as the CSV import ([CsvService]).
  ///
  /// Each row remembers its worksheet row ([ReceiptData.sourceRow]) the
  /// real row, not the position in a filtered list. A status already in the
  /// sheet is shown: TRUE = sent (skipped, like "sent before"), FALSE or
  /// blank = ready to send.
  static SheetLoad read(List<List<String>> table,
      {String statusHeader = 'email_sent'}) {
    final layout = SheetLayout.detect(table, statusHeader);
    final parsed = CsvService.parseTable(table)!; // header exists: see above

    final warnings = <String>[];
    if (layout.extraStatusCols.isNotEmpty) {
      warnings.add('More than one column is titled "$statusHeader"; only the '
          'first one is used.');
    }

    String cell(int row, int? col) {
      if (col == null || col >= table[row].length) return '';
      return table[row][col].trim();
    }

    final rows = parsed.receipts;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final t = parsed.sourceRows[i];
      r
        ..sourceRow = t + 1
        ..sourceEmailCell = cell(t, layout.emailCol)
        ..sheetStatus = cell(t, layout.statusCol);
      if (r.status == SendStatus.ready &&
          r.sheetStatus.toUpperCase() == 'TRUE') {
        r
          ..status = SendStatus.sent
          ..sentBefore = true;
      }
    }

    _flagDuplicates(rows);
    return SheetLoad(layout: layout, rows: rows, warnings: warnings);
  }

  /// The same receipt twice (same flat, payer and payment details) would
  /// email the resident twice: the later row is marked invalid. Two rows that
  /// merely share an email address (one person, two flats) are fine.
  static void _flagDuplicates(List<ReceiptData> rows) {
    final firstRow = <String, int>{};
    for (final r in rows) {
      if (r.status == SendStatus.invalid) continue;
      final key = SentLog.keyOf(r);
      final first = firstRow[key];
      if (first == null) {
        firstRow[key] = r.sourceRow ?? 0;
      } else {
        r
          ..status = SendStatus.invalid
          ..error = 'duplicate of row $first';
      }
    }
  }
}

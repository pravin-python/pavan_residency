import 'dart:async';

import '../../models/receipt_data.dart';
import 'sheet_layout.dart';
import 'sheets_api.dart';

/// One status to save: the recipient and what to write.
class StatusUpdate {
  StatusUpdate(this.receipt, this.sent);
  final ReceiptData receipt;

  /// true -> TRUE (delivered), false -> FALSE (certainly not delivered).
  final bool sent;
}

/// Result of saving one [StatusUpdate].
class StatusOutcome {
  const StatusOutcome(this.update, {this.error});
  final StatusUpdate update;

  /// null = saved. Otherwise a message that is safe to show.
  final String? error;
  bool get saved => error == null;
}

/// Writes the email-sent status into ONE worksheet.
///
/// Only two kinds of cells are ever written: the status column's header (once,
/// when it does not exist) and status cells of recipient rows. Nothing else
/// in the worksheet is touched, and nothing is ever appended as a row.
class SheetStatusWriter {
  SheetStatusWriter({
    required this.api,
    required this.spreadsheetId,
    required this.worksheetId,
    required this.worksheetTitle,
    required this.statusHeader,
  });

  final SheetsApi api;
  final String spreadsheetId;
  final int worksheetId;
  final String statusHeader;

  /// Kept current by [ensureStatusColumn] (the tab may have been renamed).
  String worksheetTitle;

  int? _statusCol;
  int? _emailCol;

  int? get statusColumn => _statusCol;

  /// Makes sure the worksheet has the status column and remembers where the
  /// header, email column and status column are.
  ///
  /// The sheet is read again here, so a column added by an earlier run (or
  /// by hand) is found and reused: the header is never duplicated. A new
  /// header goes after the last used column of the header row AND of the
  /// data, so it cannot overwrite anything.
  Future<void> ensureStatusColumn() async {
    final table = await api.readSheet(spreadsheetId, worksheetTitle);
    final layout = SheetLayout.detect(table, statusHeader);
    _emailCol = layout.emailCol;
    if (layout.statusCol != null) {
      _statusCol = layout.statusCol;
      return;
    }

    final col = layout.width;
    final meta = await api.getSpreadsheet(spreadsheetId);
    final tab = meta.worksheets.where((w) => w.sheetId == worksheetId);
    if (tab.isNotEmpty && col >= tab.first.columnCount) {
      await api.addColumns(
          spreadsheetId, worksheetId, col - tab.first.columnCount + 1);
    }
    await api.writeCells(spreadsheetId, {
      A1.cell(worksheetTitle, col, layout.headerRow): statusHeader,
    });
    _statusCol = col;
  }

  static const _chunk = 100;

  /// Saves [updates]. Never throws: every update gets an outcome.
  ///
  /// Before writing, each recipient's email cell is compared with what was
  /// read earlier. When the row moved (rows inserted / deleted / sorted since
  /// loading) it is looked up again by its email; if that is not unambiguous
  /// the status is NOT written and the outcome says so a wrong row is worse
  /// than a missing status.
  Future<List<StatusOutcome>> write(List<StatusUpdate> updates) async {
    if (updates.isEmpty) return const [];
    try {
      if (_statusCol == null || _emailCol == null) await ensureStatusColumn();
    } on SheetsApiException catch (e) {
      return _failAll(updates, e.message);
    } on SheetFormatException catch (e) {
      return _failAll(updates, e.message);
    } catch (_) {
      return _failAll(updates, 'Could not prepare the status column.');
    }
    final statusCol = _statusCol!;

    final List<String> emails;
    try {
      emails = await api.readColumn(spreadsheetId, worksheetTitle, _emailCol!);
    } on SheetsApiException catch (e) {
      return _failAll(updates, e.message);
    } catch (_) {
      return _failAll(updates, 'Could not check the sheet before saving.');
    }

    final outcomes = <StatusOutcome>[];
    final cells = <StatusUpdate, String>{}; // update -> A1 of its status cell
    final claimed = <int>{};
    for (final u in updates) {
      final want = u.receipt.sourceEmailCell.trim();
      final row0 = u.receipt.sourceRow;
      int? target;
      if (row0 != null &&
          row0 >= 1 &&
          row0 <= emails.length &&
          emails[row0 - 1].trim() == want &&
          want.isNotEmpty) {
        target = row0;
      } else if (want.isNotEmpty) {
        final hits = <int>[
          for (var i = 0; i < emails.length; i++)
            if (emails[i].trim() == want) i + 1,
        ];
        if (hits.length == 1) target = hits.first;
      }
      if (target == null) {
        outcomes.add(StatusOutcome(u,
            error: 'The sheet changed: this recipient\'s row could not be '
                'found again. Reload the sheet.'));
      } else if (!claimed.add(target)) {
        outcomes.add(StatusOutcome(u,
            error: 'Two recipients point to sheet row $target. Reload the '
                'sheet.'));
      } else {
        cells[u] = A1.cell(worksheetTitle, statusCol, target);
      }
    }

    final list = cells.entries.toList();
    for (var i = 0; i < list.length; i += _chunk) {
      final part = list.sublist(i, i + _chunk > list.length ? list.length : i + _chunk);
      try {
        await api.writeCells(spreadsheetId, {
          for (final e in part) e.value: e.key.sent,
        });
        outcomes.addAll(part.map((e) => StatusOutcome(e.key)));
      } on SheetsApiException catch (e) {
        outcomes.addAll(part.map((p) => StatusOutcome(p.key, error: e.message)));
      } catch (_) {
        outcomes.addAll(part.map((p) =>
            StatusOutcome(p.key, error: 'The status could not be saved.')));
      }
    }
    return outcomes;
  }

  static List<StatusOutcome> _failAll(List<StatusUpdate> updates, String why) =>
      [for (final u in updates) StatusOutcome(u, error: why)];
}

/// Collects statuses while a bulk run is going on and saves them in batches:
/// one write request for many recipients keeps a 100-row run far below
/// Google's per-minute write quota.
///
/// [enqueue] returns at once, so sending is never held up by the sheet. Call
/// [flush] when the run ends (and it also fires by itself every [maxDelay]
/// or [batchSize] recipients).
class SheetStatusSync {
  SheetStatusSync(
    this.writer, {
    required this.onOutcome,
    this.batchSize = 10,
    this.maxDelay = const Duration(seconds: 3),
  });

  final SheetStatusWriter writer;
  final void Function(StatusOutcome) onOutcome;
  final int batchSize;
  final Duration maxDelay;

  final _pending = <StatusUpdate>[];
  Timer? _timer;
  Future<void> _inflight = Future.value();

  void enqueue(ReceiptData r, bool sent) {
    // The value to save is remembered on the row: if the save fails (or the
    // app is closed first) the row still knows what is owed to the sheet.
    r.sheetPending = sent;
    _pending.add(StatusUpdate(r, sent));
    if (_pending.length >= batchSize) {
      flush();
    } else {
      _timer ??= Timer(maxDelay, flush);
    }
  }

  /// Saves everything queued so far; completes when it is written (or has
  /// failed). Batches never overlap.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return _inflight;
    final batch = List<StatusUpdate>.of(_pending);
    _pending.clear();
    return _inflight = _inflight.then((_) async {
      final List<StatusOutcome> outcomes;
      try {
        outcomes = await writer.write(batch);
      } catch (_) {
        for (final u in batch) {
          onOutcome(StatusOutcome(u, error: 'The status could not be saved.'));
        }
        return;
      }
      for (final o in outcomes) {
        onOutcome(o);
      }
    });
  }
}

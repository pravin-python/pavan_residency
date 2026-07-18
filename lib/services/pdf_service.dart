import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/receipt_data.dart';
import 'amount_words.dart';
import 'receipt_l10n.dart';

/// Builds the receipt as a proper vector PDF (A5 landscape),
/// with embedded Gujarati / Devanagari / Latin fonts.
class PdfService {
  static final _red = PdfColor.fromHex('#b3222a');
  static final _pink = PdfColor.fromHex('#fdeef0');
  static final _pinkDark = PdfColor.fromHex('#fbdfe3');
  static final _ink = PdfColor.fromHex('#222222');

  static pw.Font? _gu, _guB, _hi, _hiB, _en, _enB;

  static Future<void> _loadFonts() async {
    if (_gu != null) return;
    Future<pw.Font> f(String p) async =>
        pw.Font.ttf(await rootBundle.load('assets/fonts/$p'));
    _gu = await f('NotoSansGujarati-Regular.ttf');
    _guB = await f('NotoSansGujarati-Bold.ttf');
    _hi = await f('NotoSansDevanagari-Regular.ttf');
    _hiB = await f('NotoSansDevanagari-Bold.ttf');
    _en = await f('NotoSans-Regular.ttf');
    _enB = await f('NotoSans-Bold.ttf');
  }

  static Future<Uint8List> buildReceiptPdf(ReceiptData d,
      {Uint8List? signature}) async {
    await _loadFonts();
    final t = ReceiptL10n.of(d.lang);

    final base = d.lang == 'hi' ? _hi! : (d.lang == 'en' ? _en! : _gu!);
    final bold = d.lang == 'hi' ? _hiB! : (d.lang == 'en' ? _enB! : _guB!);
    final fallback = [_en!, _gu!, _hi!];

    pw.TextStyle st(double size,
            {bool b = false, PdfColor? color}) =>
        pw.TextStyle(
          font: b ? bold : base,
          fontFallback: fallback,
          fontSize: size,
          color: color ?? _red,
          fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal,
        );

    pw.Widget dotted(String value, {double size = 10, bool b = false}) =>
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6),
          decoration: pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(
                  color: _red, width: .7, style: pw.BorderStyle.dotted),
            ),
          ),
          child: pw.Text(value, style: st(size, b: b, color: _ink)),
        );

    final sigImg = signature != null ? pw.MemoryImage(signature) : null;

    final typeKeys = PaymentType.values;
    final tableRows = <pw.TableRow>[
      pw.TableRow(
        decoration: pw.BoxDecoration(color: _pinkDark),
        children: [
          for (final h in t.col)
            pw.Padding(
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: pw.Text(h,
                  style: st(9.5, b: true), textAlign: pw.TextAlign.center),
            ),
        ],
      ),
      for (var i = 0; i < typeKeys.length; i++)
        pw.TableRow(children: [
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: pw.Text(t.nums[i],
                style: st(9.5), textAlign: pw.TextAlign.center),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: pw.Text(t.rows[typeKeys[i]]!, style: st(9.5)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: pw.Text(
              typeKeys[i] == d.type ? formatIndian(d.amount) : '',
              style: st(9.5, b: typeKeys[i] == d.type, color: _ink),
              textAlign: pw.TextAlign.right,
            ),
          ),
        ]),
      pw.TableRow(children: [
        pw.SizedBox(),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: pw.Text(t.total,
              style: st(9.5, b: true), textAlign: pw.TextAlign.right),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: pw.Text(formatIndian(d.amount),
              style: st(9.5, b: true, color: _ink),
              textAlign: pw.TextAlign.right),
        ),
      ]),
    ];

    final payline = d.chqNo.isNotEmpty
        ? pw.Row(children: [
            pw.Text('${t.pay}: ${t.chq} ', style: st(10)),
            dotted(d.chqNo),
            pw.Text('  ${t.bank}: ', style: st(10)),
            dotted(d.chqBank.isEmpty ? '-' : d.chqBank),
          ])
        : pw.Row(children: [
            pw.Text('${t.pay}: ', style: st(10)),
            pw.Text(t.cash, style: st(10, b: true, color: _ink)),
          ]);

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a5.landscape,
        margin: const pw.EdgeInsets.all(16),
        build: (ctx) => pw.Container(
          decoration: pw.BoxDecoration(
            color: _pink,
            border: pw.Border.all(color: _red, width: 1.5),
            borderRadius: pw.BorderRadius.circular(10),
          ),
          padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(t.society,
                  style: st(15, b: true), textAlign: pw.TextAlign.center),
              pw.Text(t.reg,
                  style: st(7.5), textAlign: pw.TextAlign.center),
              pw.Text(t.addr,
                  style: st(8.5), textAlign: pw.TextAlign.center),
              pw.SizedBox(height: 5),
              pw.Center(
                child: pw.Container(
                  padding:
                      const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: _red, width: 1.2),
                    borderRadius: pw.BorderRadius.circular(6),
                  ),
                  child: pw.Text(t.title, style: st(11.5, b: true)),
                ),
              ),
              pw.SizedBox(height: 7),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Row(children: [
                    pw.Text('${t.recNo} ', style: st(10, b: true)),
                    dotted('${d.recNo}', b: true),
                  ]),
                  pw.Row(children: [
                    pw.Text('${t.date} : ', style: st(10, b: true)),
                    dotted(d.date),
                  ]),
                ],
              ),
              pw.SizedBox(height: 6),
              pw.Row(children: [
                pw.Text('${t.name} ', style: st(10)),
                pw.Expanded(child: dotted(d.name, b: true)),
              ]),
              pw.SizedBox(height: 6),
              pw.Row(children: [
                pw.Text('${t.block} ', style: st(10)),
                dotted(d.block.isEmpty ? '-' : d.block),
                pw.Text('   ${t.flat} ', style: st(10)),
                dotted(d.house.isEmpty ? '-' : d.house),
              ]),
              pw.SizedBox(height: 6),
              payline,
              pw.SizedBox(height: 5),
              pw.Text(t.received, style: st(9.5)),
              pw.SizedBox(height: 5),
              pw.Table(
                border: pw.TableBorder.all(color: _red, width: .8),
                columnWidths: {
                  0: const pw.FixedColumnWidth(34),
                  1: const pw.FlexColumnWidth(),
                  2: const pw.FixedColumnWidth(90),
                },
                children: tableRows,
              ),
              pw.SizedBox(height: 6),
              pw.Row(children: [
                pw.Text('${t.words} : ', style: st(9.5)),
                pw.Expanded(
                    child: dotted(amountToWords(d.amount, d.lang), size: 9.5)),
              ]),
              pw.Spacer(),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Expanded(child: pw.Text(t.note, style: st(7.5))),
                  pw.SizedBox(width: 14),
                  pw.Column(children: [
                    if (sigImg != null)
                      pw.Image(sigImg, height: 30)
                    else
                      pw.SizedBox(height: 24),
                    pw.Container(
                      width: 120,
                      padding: const pw.EdgeInsets.only(top: 2),
                      decoration: pw.BoxDecoration(
                        border: pw.Border(
                            top: pw.BorderSide(color: _red, width: .9)),
                      ),
                      child: pw.Text(t.sign,
                          style: st(8.5), textAlign: pw.TextAlign.center),
                    ),
                  ]),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return doc.save();
  }
}

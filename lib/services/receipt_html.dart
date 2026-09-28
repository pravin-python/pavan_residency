import '../models/receipt_data.dart';
import 'amount_words.dart';
import 'receipt_l10n.dart';

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Email-safe (table + inline styles) HTML receipt.
/// If [inlineSignature] is true the signature is referenced as `cid:sig`
/// and must be attached inline to the email with that content-id.
String buildReceiptHtml(ReceiptData d, {bool inlineSignature = false}) {
  final t = ReceiptL10n.of(d.lang);
  final fontCss = d.lang == 'hi'
      ? "'Noto Sans Devanagari','Noto Sans',Arial,sans-serif"
      : d.lang == 'en'
          ? "'Noto Sans',Arial,sans-serif"
          : "'Noto Sans Gujarati','Noto Sans',Arial,sans-serif";

  // Universal payment block: same layout for cash / cheque / online.
  String cell(String label, String value, {bool b = false}) =>
      '<td style="padding:4px 8px 4px 0;vertical-align:bottom;">$label : '
      '<span style="border-bottom:1px dotted #b3222a;color:#222;padding:0 8px;'
      '${b ? 'font-weight:700;' : ''}overflow-wrap:anywhere;word-wrap:break-word;">'
      '${_esc(value.isEmpty ? '-' : value)}</span></td>';
  final payment = '''
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:6px;font-size:13.5px;color:#b3222a;">
    <tr>${cell(t.pay, t.modes[d.mode]!, b: true)}${cell(t.bank, d.chqBank)}</tr>
    <tr>${cell(t.chq, d.chqNo)}${cell(t.txn, d.txnNo)}</tr>
  </table>''';

  final rows = StringBuffer();
  const keys = PaymentType.values;
  for (var i = 0; i < keys.length; i++) {
    final k = keys[i];
    final isIt = k == d.type;
    final label = isIt && k == PaymentType.other && d.remark.isNotEmpty
        ? '${t.rows[k]} – ${_esc(d.remark)}'
        : t.rows[k];
    rows.write('''
    <tr>
      <td style="border:1px solid #b3222a;padding:6px 8px;text-align:center;width:36px;">${t.nums[i]}</td>
      <td style="border:1px solid #b3222a;padding:6px 8px;">$label</td>
      <td style="border:1px solid #b3222a;padding:6px 8px;text-align:right;width:110px;color:#222;font-weight:${isIt ? '700' : '400'};">${isIt ? formatIndian(d.amount) : ''}</td>
    </tr>''');
  }

  final sig = inlineSignature
      ? '<img src="cid:sig" style="height:42px;display:block;margin:0 auto 2px;">'
      : '<div style="height:34px"></div>';

  return '''
<div style="background:#fdeef0;padding:14px 8px;">
<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;max-width:640px;margin:0 auto;">
<tr><td style="border:2px solid #b3222a;border-radius:12px;padding:16px 18px;font-family:$fontCss;color:#b3222a;font-size:14px;background:#fdeef0;">
  <div style="text-align:center;font-size:19px;font-weight:700;line-height:1.3;">${t.society}</div>
  <div style="text-align:center;font-size:11px;">${t.reg}</div>
  <div style="text-align:center;font-size:12px;margin-bottom:8px;">${t.addr}</div>
  <div style="text-align:center;margin:6px 0 10px;">
    <span style="display:inline-block;border:1.5px solid #b3222a;border-radius:8px;padding:3px 22px;font-weight:700;font-size:15px;">${t.title}</span>
  </div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:13.5px;color:#b3222a;">
    <tr>
      <td><b>${t.recNo}</b> <span style="color:#222;font-weight:700;">${d.recNo}</span></td>
      <td align="right"><b>${t.date} :</b> <span style="color:#222;">${_esc(d.date)}</span></td>
    </tr>
  </table>
  <div style="margin-top:9px;font-size:13.5px;">${t.name}
    <span style="border-bottom:1px dotted #b3222a;color:#222;font-weight:700;padding:0 8px;">${_esc(d.name)}</span></div>
  <div style="margin-top:8px;font-size:13.5px;">${t.block}
    <span style="border-bottom:1px dotted #b3222a;color:#222;padding:0 8px;">${_esc(d.block.isEmpty ? '-' : d.block)}</span>
    &nbsp; ${t.flat}
    <span style="border-bottom:1px dotted #b3222a;color:#222;padding:0 8px;">${_esc(d.house.isEmpty ? '-' : d.house)}</span></div>
$payment
  <div style="margin-top:8px;font-size:13px;">${t.received}</div>
  <table cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;margin-top:9px;font-size:13px;color:#b3222a;">
    <tr>
      <th style="border:1px solid #b3222a;padding:6px 8px;background:#fbdfe3;">${t.col[0]}</th>
      <th style="border:1px solid #b3222a;padding:6px 8px;background:#fbdfe3;">${t.col[1]}</th>
      <th style="border:1px solid #b3222a;padding:6px 8px;background:#fbdfe3;">${t.col[2]}</th>
    </tr>
    $rows
    <tr>
      <td colspan="2" style="border:1px solid #b3222a;padding:6px 8px;font-weight:700;text-align:right;">${t.total}</td>
      <td style="border:1px solid #b3222a;padding:6px 8px;text-align:right;font-weight:700;color:#222;">${formatIndian(d.amount)}</td>
    </tr>
  </table>
  <div style="margin-top:9px;font-size:13px;">${t.words} :
    <span style="border-bottom:1px dotted #b3222a;color:#222;font-weight:600;padding:0 6px;">${amountToWords(d.amount, d.lang)}</span></div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:16px;">
    <tr>
      <td style="font-size:10.5px;vertical-align:bottom;color:#b3222a;">${t.note}</td>
      <td align="right" style="vertical-align:bottom;width:170px;">
        <div style="text-align:center;">$sig
          <div style="border-top:1.2px solid #b3222a;font-size:11.5px;padding-top:3px;">${t.sign}</div>
        </div>
      </td>
    </tr>
  </table>
</td></tr>
</table>
</div>''';
}

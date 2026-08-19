import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

class ParsedItem {
  String productName;
  String category;
  String serialNumbers;
  String quantity;
  String rawAmount;
  double? netPrice;
  String gstRate;
  String notes;
  String status;
  String transactionType;

  ParsedItem({
    required this.productName,
    required this.category,
    required this.serialNumbers,
    required this.quantity,
    required this.rawAmount,
    required this.netPrice,
    required this.gstRate,
    required this.notes,
    required this.status,
    required this.transactionType,
  });
}

class ParsedRecord {
  String date;
  String subject;
  String transactionType;
  String billingName;
  String billingAddress;
  String deliveryName;
  String deliveryAddress;
  String? gstin;
  String? phone;
  String? email;
  String sourceFile;
  List<ParsedItem> items;

  ParsedRecord({
    required this.date,
    required this.subject,
    required this.transactionType,
    required this.billingName,
    required this.billingAddress,
    required this.deliveryName,
    required this.deliveryAddress,
    required this.gstin,
    required this.phone,
    required this.email,
    this.sourceFile = '',
    required this.items,
  });
}

class ParseSummary {
  final int records;
  final int items;
  final int sales;
  final int nonSales;
  final List<String> warnings;

  const ParseSummary({
    required this.records,
    required this.items,
    required this.sales,
    required this.nonSales,
    required this.warnings,
  });
}

String _normalize(String s) {
  return s
      .replaceAll('\u00A0', ' ')
      .replaceAll('\u200B', '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .trim();
}

String _cleanValue(String value) {
  return _normalize(value
      .replaceFirst(RegExp(r'^[•·▪●\-]+\s*'), '')
      .replaceAll(RegExp(r'^[:\-]\s*'), ''));
}

String _extractTextFromDocx(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final file = archive.findFile('word/document.xml');
  if (file == null) throw const FormatException('DOCX does not contain word/document.xml');

  final xml = XmlDocument.parse(utf8.decode(file.content as List<int>));
  final out = StringBuffer();

  // Preserve paragraph boundaries and table rows. The source files are mostly
  // paragraph text, but a few Word versions put address/data fragments in tables.
  for (final p in xml.findAllElements('w:p')) {
    final text = p.findAllElements('w:t').map((e) => e.value).join();
    if (_normalize(text).isNotEmpty) out.writeln(_normalize(text));
  }
  for (final table in xml.findAllElements('w:tbl')) {
    for (final row in table.findAllElements('w:tr')) {
      final cells = row.findAllElements('w:tc').map((cell) {
        return _normalize(cell.findAllElements('w:t').map((e) => e.value).join());
      }).where((e) => e.isNotEmpty).toList();
      if (cells.isNotEmpty) out.writeln(cells.join(' | '));
    }
  }
  return out.toString();
}

DateTime? _parseDate(String value) {
  final m = RegExp(r'\b(\d{1,2})[\-/](\d{1,2})[\-/](\d{2}|\d{4})\b').firstMatch(value);
  if (m == null) return null;
  var year = int.parse(m.group(3)!);
  if (year < 100) year += year < 50 ? 2000 : 1900;
  try {
    return DateTime(year, int.parse(m.group(2)!), int.parse(m.group(1)!));
  } catch (_) {
    return null;
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _fieldValue(String line, List<String> labels) {
  line = line.replaceFirst(RegExp(r'^\s*ITEM\s*\d*\s*[:.]?\s*', caseSensitive: false), '');
  for (final label in labels) {
    final pattern = label.toLowerCase() == 'item'
        ? r'^\s*Item(?:\s*\d+)?\s*[:\-]?\s*(.*)$'
        : '^\\s*${RegExp.escape(label)}\\s*[:\\-]?\\s*(.*)\$';
    final m = RegExp(pattern, caseSensitive: false).firstMatch(line);
    if (m != null && label.toLowerCase() == 'item' && RegExp(r'^\s*\d+\s*$').hasMatch(m.group(1)!)) return '';
    if (m != null) return _cleanValue(m.group(1)!);
  }
  return '';
}

bool _isItemMarker(String line) => RegExp(r'^\s*ITEM\s*\d*\s*[:.]?\s*$', caseSensitive: false).hasMatch(line);

bool _isAttributeLine(String line) => RegExp(
      r'^\s*(Product|Device|Item|Transducer|Serial\s*(?:No|Number|No\.)?|Number|Quantity|Qty|Amount|Price|GSTIN|GST|Tax|Reason|Other Items|New Items|Billing(?:/Delivery)? Address|Bill(?:ing)? Address|Delivery Address|Dispatch Address|Bill|Delivery|Contact|Contact No|Mob|Phone|Email|E-mail)\s*[:\-]?\s*',
      caseSensitive: false,
    ).hasMatch(line);

String _canonicalCategory(String product, String notes) {
  final s = '$product $notes'.toLowerCase();
  if (RegExp(r'calibration|calibrat|service|repair|checking|checkup|after service|repair charges|certificate').hasMatch(s)) return 'Calibration & Service';
  if (RegExp(r'probe|tip|cable|adapter|charger|battery|headphone|earphone|electrode|electrodes|speaker|pre[- ]?amp|power cord|power adapter|tube|foam|insert|printer|paper|gel|accessor|spare').hasMatch(s)) return 'Spares & Accessories';
  if (RegExp(r'quantity|no[’\']?s|pack|rolls|filters|gel|brochures|paper').hasMatch(s) && !RegExp(r'audiometer|oae|tymp|abr|titan|mi\d|ad\d|teny|duet|menor|sera|usb').hasMatch(s)) return 'Consumables';
  if (RegExp(r'audiometer|oae|eroscan|easyscreen|easy tymp|easytymp|tymp|ad\d+|abr|duet|sera|titan|mi\d|mb\d|teny|menor|maico|inventis|labat|i hs|ihs|ecochg|amplifier|system').hasMatch(s)) return 'Main Equipment';
  return 'Other';
}

String _inferTransactionType(String block) {
  final s = block.toLowerCase();
  if (RegExp(r'\breturn\b|returned|replace|replacement').hasMatch(s)) return 'Return';
  if (RegExp(r'\brepair\b|service|not repairable|checkup|checking|calibration').hasMatch(s) && !RegExp(r'for sale|bill and dispatch|bill the').hasMatch(s)) return 'Repair / Service';
  if (RegExp(r'\bdemo\b|demo purpose|demonstration').hasMatch(s)) return 'Demo';
  if (RegExp(r'\bon dc\b|\bdc\b|delivery challan|short supply|standby').hasMatch(s) && !RegExp(r'for sale|bill').hasMatch(s)) return 'DC / Internal Movement';
  if (RegExp(r'please bill|bill and dispatch|bill the|bill item|for sale|amount\s*:').hasMatch(s)) return 'Sale / Billing';
  return 'Other';
}

String _inferStatus(String block, String transactionType) {
  if (transactionType == 'Sale / Billing') return 'Billed / Sale';
  if (transactionType == 'DC / Internal Movement') return 'DC';
  if (transactionType == 'Demo') return 'Demo';
  if (transactionType == 'Repair / Service') return 'Service';
  if (transactionType == 'Return') return 'Returned';
  return 'Other';
}

double? _amountFromText(String value) {
  var s = value.toLowerCase().replaceAll(',', '').replaceAll('₹', '');
  final lakh = RegExp(r'(\d+(?:\.\d+)?)\s*l(?:ac|akh|)', caseSensitive: false).firstMatch(s);
  if (lakh != null) return double.parse(lakh.group(1)!) * 100000;
  final crore = RegExp(r'(\d+(?:\.\d+)?)\s*cr(?:ore)?', caseSensitive: false).firstMatch(s);
  if (crore != null) return double.parse(crore.group(1)!) * 10000000;
  final explicit = RegExp(r'(?:rs\.?|inr)\s*([0-9]+(?:\.[0-9]+)?)').allMatches(s).map((m) => double.tryParse(m.group(1)!)).whereType<double>().toList();
  if (explicit.isNotEmpty) return explicit.first;
  final nums = RegExp(r'(?<![0-9])\d{1,3}(?:,?\d{2,3})+(?:\.\d+)?|\d{4,}(?:\.\d+)?').allMatches(s).map((m) => double.tryParse(m.group(0)!.replaceAll(',', ''))).whereType<double>().toList();
  if (nums.isEmpty) return null;
  return nums.first;
}

String _gstRate(String value) {
  final m = RegExp(r'GST\s*@?\s*(\d+(?:\.\d+)?)\s*%', caseSensitive: false).firstMatch(value);
  if (m != null) return '${m.group(1)}%';
  return '';
}

String _firstValueAfterLabels(List<String> lines, List<String> labels, {int from = 0}) {
  for (int i = from; i < lines.length; i++) {
    final v = _fieldValue(lines[i], labels);
    if (v.isNotEmpty) return v;
  }
  return '';
}

String _extractAddress(List<String> lines, List<String> labels) {
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!labels.any((l) => RegExp('^\\s*${RegExp.escape(l)}\\s*[:\\-]?', caseSensitive: false).hasMatch(line))) continue;
    final direct = _fieldValue(line, labels);
    final parts = <String>[];
    if (direct.isNotEmpty && !RegExp(r'^(as per po|n/?a|same|shubham|h?ac\b)', caseSensitive: false).hasMatch(direct)) parts.add(direct);
    for (int j = i + 1; j < lines.length && j <= i + 7; j++) {
      final next = _normalize(lines[j]);
      if (next.isEmpty || _isItemMarker(next) || _isAttributeLine(next)) break;
      if (RegExp(r'^Dear\b|^\d{1,2}[\-/]\d{1,2}[\-/]\d{2,4}\b', caseSensitive: false).hasMatch(next)) break;
      parts.add(next);
    }
    if (parts.isNotEmpty) return parts.join(', ');
  }
  return '';
}

String _extractNameFromAddress(String value) {
  if (value.isEmpty) return '';
  final first = value.split(',').map(_normalize).where((s) => s.isNotEmpty).toList();
  if (first.isEmpty) return '';
  var name = first.first;
  name = name.replaceAll(RegExp(r'^(c/o|w/o|s/o|d/o)\s+', caseSensitive: false), '').trim();
  return name;
}

List<_DatedBlock> _splitDatedBlocks(String text) {
  final lines = text.split(RegExp(r'\r?\n')).map(_normalize).where((x) => x.isNotEmpty).toList();
  final result = <_DatedBlock>[];
  var currentDate = '';
  var current = <String>[];
  void flush() {
    if (current.isNotEmpty) {
      result.add(_DatedBlock(currentDate, List<String>.from(current)));
      current = <String>[];
    }
  }
  for (final line in lines) {
    final d = _parseDate(line);
    if (d != null) {
      flush();
      currentDate = _isoDate(d);
      continue;
    }
    if (RegExp(r'^Dear\b', caseSensitive: false).hasMatch(line) && current.isNotEmpty) flush();
    current.add(line);
  }
  flush();
  return result;
}

class _DatedBlock {
  final String date;
  final List<String> lines;
  _DatedBlock(this.date, this.lines);
}

List<List<String>> _splitItems(List<String> block) {
  final result = <List<String>>[];
  var current = <String>[];
  for (final line in block) {
    final marker = _isItemMarker(line);
    if (marker && current.isNotEmpty) {
      result.add(current);
      current = <String>[];
      continue;
    }
    if (_fieldValue(line, ['Product', 'Device', 'Item', 'Transducer']).isNotEmpty && current.isNotEmpty) {
      final hasProduct = current.any((x) => _fieldValue(x, ['Product', 'Device', 'Item', 'Transducer']).isNotEmpty);
      if (hasProduct) {
        result.add(current);
        current = <String>[];
      }
    }
    current.add(line);
  }
  if (current.isNotEmpty) result.add(current);
  if (result.isEmpty) return [block];
  final useful = result.where((part) => part.any((x) => _fieldValue(x, ['Product', 'Device', 'Item', 'Transducer']).isNotEmpty)).toList();
  return useful.isEmpty ? [block] : useful;
}

ParsedRecord _parseBlock(List<String> block, String currentDate) {
  final transactionType = _inferTransactionType(block.join(' '));
  final billingAddress = _extractAddress(block, ['Bill/Delivery Address', 'Billing/Delivery Address', 'Billing Address', 'Bill Address', 'Bill']);
  final deliveryAddress = _extractAddress(block, ['Delivery Address', 'Dispatch Address', 'Delivery']);
  final combinedAddress = billingAddress.isNotEmpty ? billingAddress : deliveryAddress;
  final gstin = _firstValueAfterLabels(block, ['GSTIN', 'GST No', 'GST']);
  final phone = _firstValueAfterLabels(block, ['Contact No', 'Contact', 'Mob', 'Phone']);
  final email = _firstValueAfterLabels(block, ['Email', 'E-mail', 'Email id']);
  final billingName = _extractNameFromAddress(combinedAddress);
  final deliveryName = _extractNameFromAddress(deliveryAddress);

  final itemParts = _splitItems(block);
  final items = <ParsedItem>[];
  for (final part in itemParts) {
    final productLines = <String>[];
    for (final line in part) {
      final v = _fieldValue(line, ['Product', 'Device', 'Item', 'Transducer']);
      if (v.isNotEmpty) productLines.add(v);
      else if (productLines.isNotEmpty && !_isAttributeLine(line) && !RegExp(r'^Dear\b', caseSensitive: false).hasMatch(line)) productLines.add(line);
    }
    final product = _normalize(productLines.join(' '));
    if (product.isEmpty) continue;
    final serial = _firstValueAfterLabels(part, ['Serial Number', 'Serial No', 'Serial No.', "Serial No’s"]) .replaceFirst(RegExp(r'^SN\s*[:\-]?\s*', caseSensitive: false), 'SN ');
    final quantity = _firstValueAfterLabels(part, ['Quantity', 'Qty', 'Number']);
    final amount = _firstValueAfterLabels(part, ['Amount', 'Price']);
    final reason = _firstValueAfterLabels(part, ['Reason']);
    final transaction = transactionType;
    items.add(ParsedItem(
      productName: product,
      category: _canonicalCategory(product, reason),
      serialNumbers: serial.isEmpty ? 'N/A' : serial,
      quantity: quantity.isEmpty ? '1' : quantity,
      rawAmount: amount,
      netPrice: _amountFromText(amount),
      gstRate: _gstRate(amount),
      notes: reason,
      status: _inferStatus(part.join(' '), transaction),
      transactionType: transaction,
    ));
  }

  return ParsedRecord(
    date: currentDate,
    subject: block.where((x) => RegExp(r'^Please\b', caseSensitive: false).hasMatch(x)).take(1).join(' '),
    transactionType: transactionType,
    billingName: billingName,
    billingAddress: billingAddress,
    deliveryName: deliveryName,
    deliveryAddress: deliveryAddress,
    gstin: gstin.isEmpty ? null : gstin,
    phone: phone.isEmpty ? null : phone,
    email: email.isEmpty ? null : email,
    items: items,
  );
}

List<ParsedRecord> parseDocxBytes(Uint8List bytes) {
  final text = _extractTextFromDocx(bytes);
  final blocks = _splitDatedBlocks(text);
  final records = <ParsedRecord>[];
  for (final block in blocks) {
    final record = _parseBlock(block.lines, block.date);
    if (record.items.isNotEmpty) records.add(record);
  }
  return records;
}

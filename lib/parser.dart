import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

class ParsedItem {
  String productName;
  String category;
  String serialNumbers;
  String rawAmount;
  double? netPrice;
  String gstRate;
  String notes;
  String status; // DC, Billed, Pending, Returned, Other

  ParsedItem({
    required this.productName,
    required this.category,
    required this.serialNumbers,
    required this.rawAmount,
    this.netPrice,
    required this.gstRate,
    required this.notes,
    required this.status,
  });
}

class ParsedRecord {
  String date;
  String dispatchType;
  String billingAddress;
  String? gstin;
  String? phone;
  List<ParsedItem> items;

  ParsedRecord({
    required this.date,
    required this.dispatchType,
    required this.billingAddress,
    this.gstin,
    this.phone,
    required this.items,
  });
}

// Extract plain text lines from .docx bytes
String _extractTextFromDocx(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final docEntry = archive.files.firstWhere((f) => f.name == 'word/document.xml', orElse: () => throw Exception('document.xml not found'));
  final xmlStr = utf8.decode(docEntry.content as List<int>);
  final xml = XmlDocument.parse(xmlStr);
  final buffer = StringBuffer();

  for (final p in xml.findAllElements('w:p')) {
  final texts = p.findAllElements('w:t').map((n) => n.value).join();
    if (texts.trim().isNotEmpty) buffer.writeln(texts.trim());
  }


  // tables
  for (final tbl in xml.findAllElements('w:tbl')) {
    for (final row in tbl.findAllElements('w:tr')) {
    final cells = row.findAllElements('w:tc').map((c) => c.findAllElements('w:t').map((n) => n.value).join()).where((t) => t.trim().isNotEmpty).toList();
      if (cells.isNotEmpty) buffer.writeln(cells.join(' | '));
    }
  }

  return buffer.toString();
}

List<ParsedRecord> parseDocxBytes(Uint8List bytes) {
  final text = _extractTextFromDocx(bytes);
  final lines = text.split(RegExp(r'\r?\n'));

  String currentDate = 'Unknown';
  List<String> blocksDates = [];
  List<String> blocksText = [];
  List<String> currentBlock = [];

  for (final line in lines) {
    final dateMatch = RegExp(r'\b\d{1,2}/\d{1,2}/\d{2,4}\b').firstMatch(line);
    if (dateMatch != null) {
      currentDate = dateMatch.group(0)!;
      continue;
    }
    if (line.toLowerCase().startsWith('dear sir')) {
      if (currentBlock.isNotEmpty) {
        blocksDates.add(currentDate);
        blocksText.add(currentBlock.join('\n'));
        currentBlock = [];
      }
    }
    currentBlock.add(line);
  }
  if (currentBlock.isNotEmpty) {
    blocksDates.add(currentDate);
    blocksText.add(currentBlock.join('\n'));
  }

  List<ParsedRecord> records = [];

  for (int i = 0; i < blocksText.length; i++) {
    final docDate = blocksDates[i];
    final block = blocksText[i].replaceAll(RegExp(r'\s+'), ' ');

    final intentMatch = RegExp(r'Please\s+(.*?)\s+(?:as mentioned below|item|;)', caseSensitive: false).firstMatch(block);
    final dispatchType = intentMatch?.group(1)?.trim() ?? 'Dispatch';

    final gstMatch = RegExp(r'GST(?:IN)?\s*[:\-]?\s*([A-Z0-9\-]+)', caseSensitive: false).firstMatch(block);
    final gstin = gstMatch?.group(1)?.trim();

    final phoneMatch = RegExp(r'(?:Contact|Mob|Ph)\s*[-.:]?\s*([+\d\s/,]+)', caseSensitive: false).firstMatch(block);
    final phone = phoneMatch?.group(1)?.trim();

    final billMatch = RegExp(r'Bill\s*(?:and\s*Delivery)?\s*Address\s*[:\-]?\s*(.*?)(?=Delivery Address|GST|Contact|Mob|Ph|Dear|$)', caseSensitive: false).firstMatch(block);
    final billAddr = billMatch?.group(1)?.trim();

    final delivMatch = RegExp(r'Delivery\s*Address\s*[:\-]?\s*(.*?)(?=GST|Contact|Mob|Ph|Dear|$)', caseSensitive: false).firstMatch(block);
    final delivAddr = delivMatch?.group(1)?.trim();

    final itemSplit = block.split(RegExp(r'ITEM\\s*\\d*\\s*:', caseSensitive: false));
    final itemsRaw = itemSplit.length > 1 ? itemSplit.sublist(1) : [block];

    List<ParsedItem> extractedItems = [];

    for (final rawItem in itemsRaw) {
      final prodM = RegExp(r'Product\s*[:\-]?\s*(.*?)(?=Serial Number|Number|Amount|Reason|Other Items|New Items|Bill|Delivery|$)', caseSensitive: false).firstMatch(rawItem);
      final snM = RegExp(r'(?:Serial Number|Number)\s*[:\-]?\s*(.*?)(?=Amount|Reason|Other Items|New Items|Bill|Delivery|$)', caseSensitive: false).firstMatch(rawItem);
      final amtM = RegExp(r'Amount\s*[:\-]?\s*(.*?)(?=Reason|Other Items|New Items|Bill|Delivery|$)', caseSensitive: false).firstMatch(rawItem);
      final reasonM = RegExp(r'Reason\s*[:\-]?\s*(.*?)(?=Amount|Bill|Delivery|$)', caseSensitive: false).firstMatch(rawItem);

      final prod = prodM?.group(1)?.trim() ?? 'Unknown Product';
      final sn = snM?.group(1)?.trim() ?? 'N/A';
      final amt = amtM?.group(1)?.trim() ?? 'N/A';
      final reason = reasonM?.group(1)?.trim() ?? '';

      final isSpare = prod.toLowerCase().contains(RegExp(r'\b(tip|probe|cable|headphone|set|kit|encoder)\b'));
      final category = isSpare ? 'Spares/Accessory' : 'Main Equipment';

      double? netVal;
      if (amt.contains('1.9L')) {
        netVal = 190000.0;
      } else {
        final numMatch = RegExp(r'[\d,]{3,}').allMatches(amt).map((m) => m.group(0)!).toList();
        if (numMatch.isNotEmpty) {
          final s = numMatch.last.replaceAll(',', '');
          netVal = double.tryParse(s);
        }
      }

      final gstRateMatch = RegExp(r'GST@?(\d+%)').firstMatch(amt);
      final gstRate = gstRateMatch?.group(1) ?? (amt.contains('5%') ? '5%' : amt.contains('12%') ? '12%' : 'N/A');

      // Status inference
      String status = 'Other';
      if (RegExp(r'\bDC\b|Delivery Challan', caseSensitive: false).hasMatch(rawItem)) status = 'DC';
      if (RegExp(r'\bBill(ed)?\b|Invoice', caseSensitive: false).hasMatch(rawItem)) status = 'Billed';

      extractedItems.add(ParsedItem(
        productName: prod,
        category: category,
        serialNumbers: sn,
        rawAmount: amt,
        netPrice: netVal,
        gstRate: gstRate,
        notes: reason,
        status: status,
      ));
    }

    records.add(ParsedRecord(
      date: docDate,
      dispatchType: dispatchType,
      billingAddress: billAddr ?? delivAddr ?? 'N/A',
      gstin: gstin,
      phone: phone,
      items: extractedItems,
    ));
  }

  return records;
}

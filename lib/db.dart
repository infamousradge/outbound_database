import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'parser.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  late Database _db;

  Future<void> init() async {
    sqfliteFfiInit();
    final databaseFactory = databaseFactoryFfi;

    // Use a per-user app data folder on Windows to persist DB reliably
    String baseDir;
    if (Platform.isWindows) {
      baseDir = Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path;
    } else {
      baseDir = Directory.current.path;
    }
    final appDirPath = p.join(baseDir, 'OutboundDatabase');
    await Directory(appDirPath).create(recursive: true);
    final dbPath = p.join(appDirPath, 'outbound_database.db');
    _db = await databaseFactory.openDatabase(dbPath);

    await _db.execute('''
      CREATE TABLE IF NOT EXISTS clients (
        client_id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_name TEXT,
        billing_address TEXT,
        normalized_key TEXT,
        gstin TEXT,
        contact_number TEXT
      );
    ''');

    await _db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_clients_norm ON clients(normalized_key);
    ''');

    await _db.execute('''
      CREATE TABLE IF NOT EXISTS dispatch_orders (
        order_id INTEGER PRIMARY KEY AUTOINCREMENT,
        dispatch_date TEXT,
        dispatch_type TEXT,
        client_id INTEGER,
        FOREIGN KEY (client_id) REFERENCES clients (client_id)
      );
    ''');

    await _db.execute('''
      CREATE TABLE IF NOT EXISTS dispatch_items (
        item_id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id INTEGER,
        product_name TEXT,
        category TEXT,
        serial_numbers TEXT,
        raw_amount_text TEXT,
        net_price REAL,
        gst_rate TEXT,
        notes TEXT,
        dispatch_status TEXT,
        FOREIGN KEY (order_id) REFERENCES dispatch_orders (order_id)
      );
    ''');

    await _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_items_serial ON dispatch_items(serial_numbers);
    ''');
  }

  String _normalizeKey(String? address, String? phone, String? gstin) {
    if (gstin != null && gstin.trim().isNotEmpty) return gstin.trim().toUpperCase();
    final a = (address ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final pno = (phone ?? '').toLowerCase().replaceAll(RegExp(r'[^0-9]'), '');
    return (a + '|' + pno).trim();
  }

  Future<int> insertOrMergeClient(String? name, String? address, String? gstin, String? phone) async {
    final norm = _normalizeKey(address, phone, gstin);
    final existing = await _db.query('clients', where: 'normalized_key = ?', whereArgs: [norm]);
    if (existing.isNotEmpty) {
      final row = existing.first;
      final id = row['client_id'] as int;
      // merge: update empty fields with new values
      final updates = <String, dynamic>{};
      if ((row['client_name'] == null || (row['client_name'] as String).trim().isEmpty) && (name ?? '').trim().isNotEmpty) updates['client_name'] = name;
      if ((row['billing_address'] == null || (row['billing_address'] as String).trim().isEmpty) && (address ?? '').trim().isNotEmpty) updates['billing_address'] = address;
      if ((row['gstin'] == null || (row['gstin'] as String).trim().isEmpty) && (gstin ?? '').trim().isNotEmpty) updates['gstin'] = gstin;
      if ((row['contact_number'] == null || (row['contact_number'] as String).trim().isEmpty) && (phone ?? '').trim().isNotEmpty) updates['contact_number'] = phone;
      if (updates.isNotEmpty) {
        await _db.update('clients', updates, where: 'client_id = ?', whereArgs: [id]);
      }
      return id;
    } else {
      final id = await _db.insert('clients', {
        'client_name': name ?? '',
        'billing_address': address ?? '',
        'normalized_key': norm,
        'gstin': gstin ?? '',
        'contact_number': phone ?? ''
      });
      return id;
    }
  }

  Future<int> createOrder(String date, String type, int clientId) async {
    final id = await _db.insert('dispatch_orders', {
      'dispatch_date': date,
      'dispatch_type': type,
      'client_id': clientId
    });
    return id;
  }

  Future<int> saveItem(int orderId, ParsedItem item) async {
    // Better duplicate handling: if serial exists and incoming status is Billed, upgrade existing record
    final sn = item.serialNumbers.trim();
    if (sn.isNotEmpty && sn != 'N/A') {
      final found = await _db.query('dispatch_items', where: 'serial_numbers = ?', whereArgs: [sn]);
      if (found.isNotEmpty) {
        final existing = found.first;
        final existingStatus = existing['dispatch_status'] as String? ?? 'Other';
        final existingId = existing['item_id'] as int;
        // If incoming is Billed and existing is not, update status to Billed (sold)
        if (item.status == 'Billed' && existingStatus != 'Billed') {
        await _db.update('dispatch_items', {'dispatch_status': 'Billed', 'notes': (existing['notes'] ?? '').toString() + '\nUpdated: billed'}, where: 'item_id = ?', whereArgs: [existingId]);
          return existingId;
        }
        // Otherwise skip to avoid duplicate
        return -1; // indicate skipped duplicate
      }
    }

    final id = await _db.insert('dispatch_items', {
      'order_id': orderId,
      'product_name': item.productName,
      'category': item.category,
      'serial_numbers': item.serialNumbers,
      'raw_amount_text': item.rawAmount,
      'net_price': item.netPrice,
      'gst_rate': item.gstRate,
      'notes': item.notes,
      'dispatch_status': item.status,
    });
    return id;
  }

  Future<void> saveParsedRecords(List<ParsedRecord> records) async {
    for (final r in records) {
      final clientName = r.billingAddress.split(RegExp(r',|;')).first.trim();
      final clientId = await insertOrMergeClient(clientName, r.billingAddress, r.gstin, r.phone);
      final orderId = await createOrder(r.date, r.dispatchType, clientId);
      for (final it in r.items) {
        await saveItem(orderId, it);
      }
    }
  }

  Future<List<Map<String, dynamic>>> allItems({String? status, String? category}) async {
    final where = <String>[];
    final args = <dynamic>[];
    if (status != null) { where.add('dispatch_status = ?'); args.add(status); }
    if (category != null) { where.add('category = ?'); args.add(category); }
    final q = await _db.rawQuery('''
      SELECT i.*, d.dispatch_date, d.dispatch_type, c.client_name, c.billing_address, c.gstin, c.contact_number
      FROM dispatch_items i
      JOIN dispatch_orders d ON i.order_id = d.order_id
      JOIN clients c ON d.client_id = c.client_id
      ${where.isNotEmpty ? 'WHERE ' + where.join(' AND ') : ''}
      ORDER BY d.dispatch_date DESC
    ''', args);
    return q;
  }

  // Fetch clients for Clients view
  Future<List<Map<String, dynamic>>> fetchClients() async {
    final q = await _db.query('clients', orderBy: 'client_name ASC');
    return q;
  }

  // Update an item's status (e.g., mark as Billed)
  Future<void> updateItemStatus(int itemId, String newStatus) async {
    await _db.update('dispatch_items', {'dispatch_status': newStatus}, where: 'item_id = ?', whereArgs: [itemId]);
  }

  // Export items as CSV to provided path
  Future<String> exportItemsToCsv(String outPath) async {
    final rows = await allItems();
    final lines = <String>[];
    lines.add('item_id,order_id,product_name,category,serial_numbers,net_price,dispatch_status,client_name,client_address,dispatch_date');
    for (final r in rows) {
      final line = [
        r['item_id'] ?? '',
        r['order_id'] ?? '',
        '"${(r['product_name'] ?? '').toString().replaceAll('"', '""')}"',
        r['category'] ?? '',
        r['serial_numbers'] ?? '',
        r['net_price'] ?? '',
        r['dispatch_status'] ?? '',
        '"${(r['client_name'] ?? '').toString().replaceAll('"', '""')}"',
        '"${(r['billing_address'] ?? '').toString().replaceAll('"', '""')}"',
        r['dispatch_date'] ?? '',
      ].join(',');
      lines.add(line);
    }
    final file = File(outPath);
    await file.writeAsString(lines.join('\n'));
    return outPath;
  }

  // Export items as JSON
  Future<String> exportItemsToJson(String outPath) async {
    final rows = await allItems();
    final file = File(outPath);
    await file.writeAsString(jsonEncode(rows));
    return outPath;
  }

  // Simple CSV parser for a line (handles quoted fields)
  List<String> _parseCsvLine(String line) {
    final List<String> out = [];
    final buffer = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++; // skip escaped quote
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        out.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    out.add(buffer.toString());
    return out;
  }

  // Import items from CSV — updates existing items by item_id or serial_numbers; new rows are inserted; client/order are created/merged
  Future<void> importItemsFromCsv(String path) async {
    final f = File(path);
    if (!(await f.exists())) throw Exception('File not found: $path');
    final lines = await f.readAsLines();
    if (lines.isEmpty) return;
    final header = _parseCsvLine(lines.first);
    final idxOf = (String name) => header.indexWhere((h) => h.toLowerCase() == name.toLowerCase());

    for (int i = 1; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      final cols = _parseCsvLine(lines[i]);
      final get = (String name) {
        final idx = idxOf(name);
        if (idx >= 0 && idx < cols.length) return cols[idx].trim();
        return '';
      };

      final itemIdStr = get('item_id');
      final serial = get('serial_numbers');
      final product = get('product_name');
      final category = get('category');
      final netPriceStr = get('net_price');
      final status = get('dispatch_status').isNotEmpty ? get('dispatch_status') : 'Other';
      final clientName = get('client_name');
      final clientAddress = get('client_address');
      final dispatchDate = get('dispatch_date');

      double? netPrice;
      if (netPriceStr.isNotEmpty) netPrice = double.tryParse(netPriceStr.replaceAll(',', ''));

      // Ensure client exists
      final clientId = await insertOrMergeClient(clientName, clientAddress, null, null);

      // Create an order for this import row — simple strategy: create a new order per CSV row
      final orderId = await createOrder(dispatchDate, 'Import', clientId);

      // If item_id provided and exists, update
      if (itemIdStr.isNotEmpty) {
        final itemId = int.tryParse(itemIdStr);
        if (itemId != null) {
          final existing = await _db.query('dispatch_items', where: 'item_id = ?', whereArgs: [itemId]);
          if (existing.isNotEmpty) {
            await _db.update('dispatch_items', {
              'product_name': product,
              'category': category,
              'serial_numbers': serial,
              'net_price': netPrice,
              'dispatch_status': status,
            }, where: 'item_id = ?', whereArgs: [itemId]);
            continue; // done
          }
        }
      }

      // If serial exists, update that row
      if (serial.isNotEmpty) {
        final found = await _db.query('dispatch_items', where: 'serial_numbers = ?', whereArgs: [serial]);
        if (found.isNotEmpty) {
          final existingId = found.first['item_id'] as int;
          await _db.update('dispatch_items', {
            'product_name': product,
            'category': category,
            'net_price': netPrice,
            'dispatch_status': status,
          }, where: 'item_id = ?', whereArgs: [existingId]);
          continue;
        }
      }

      // Otherwise insert new
      await _db.insert('dispatch_items', {
        'order_id': orderId,
        'product_name': product,
        'category': category,
        'serial_numbers': serial,
        'raw_amount_text': '',
        'net_price': netPrice,
        'gst_rate': '',
        'notes': 'Imported',
        'dispatch_status': status,
      });
    }
  }

  Future<void> importItemsFromJson(String path) async {
    final f = File(path);
    if (!(await f.exists())) throw Exception('File not found: $path');
    final content = await f.readAsString();
    final decoded = jsonDecode(content);
    if (decoded is List) {
      for (final entry in decoded) {
        final serial = (entry['serial_numbers'] ?? '').toString();
        final product = (entry['product_name'] ?? '').toString();
        final category = (entry['category'] ?? '').toString();
        final netPrice = entry['net_price'] != null ? double.tryParse(entry['net_price'].toString()) : null;
        final status = (entry['dispatch_status'] ?? 'Other').toString();
        final clientName = (entry['client_name'] ?? '').toString();
        final clientAddress = (entry['billing_address'] ?? '').toString();
        final dispatchDate = (entry['dispatch_date'] ?? '').toString();

        final clientId = await insertOrMergeClient(clientName, clientAddress, null, null);
        final orderId = await createOrder(dispatchDate, 'Import', clientId);

        if (entry['item_id'] != null) {
          final itemId = int.tryParse(entry['item_id'].toString());
          if (itemId != null) {
            final existing = await _db.query('dispatch_items', where: 'item_id = ?', whereArgs: [itemId]);
            if (existing.isNotEmpty) {
              await _db.update('dispatch_items', {
                'product_name': product,
                'category': category,
                'net_price': netPrice,
                'dispatch_status': status,
              }, where: 'item_id = ?', whereArgs: [itemId]);
              continue;
            }
          }
        }

        if (serial.isNotEmpty) {
          final found = await _db.query('dispatch_items', where: 'serial_numbers = ?', whereArgs: [serial]);
          if (found.isNotEmpty) {
            final existingId = found.first['item_id'] as int;
            await _db.update('dispatch_items', {
              'product_name': product,
              'category': category,
              'net_price': netPrice,
              'dispatch_status': status,
            }, where: 'item_id = ?', whereArgs: [existingId]);
            continue;
          }
        }

        await _db.insert('dispatch_items', {
          'order_id': orderId,
          'product_name': product,
          'category': category,
          'serial_numbers': serial,
          'raw_amount_text': '',
          'net_price': netPrice,
          'gst_rate': '',
          'notes': 'Imported',
          'dispatch_status': status,
        });
      }
    } else {
      throw Exception('JSON root is not a list');
    }
  }
}

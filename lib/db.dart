import 'dart:convert';
import 'dart:io';

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
    final base = Platform.isWindows
        ? (Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path)
        : Directory.current.path;
    final dir = p.join(base, 'OutboundDatabase');
    await Directory(dir).create(recursive: true);
    final dbPath = p.join(dir, 'outbound_database_v2.db');
    _db = await databaseFactoryFfi.openDatabase(dbPath);

    await _db.execute('PRAGMA foreign_keys = ON');
    await _db.execute('''CREATE TABLE IF NOT EXISTS clients(
      client_id INTEGER PRIMARY KEY AUTOINCREMENT,
      client_name TEXT NOT NULL DEFAULT '',
      billing_address TEXT NOT NULL DEFAULT '',
      delivery_address TEXT NOT NULL DEFAULT '',
      normalized_key TEXT NOT NULL UNIQUE,
      gstin TEXT NOT NULL DEFAULT '',
      contact_number TEXT NOT NULL DEFAULT '',
      email TEXT NOT NULL DEFAULT '',
      first_seen TEXT NOT NULL DEFAULT '',
      last_seen TEXT NOT NULL DEFAULT ''
    )''');
    await _db.execute('''CREATE TABLE IF NOT EXISTS transactions(
      transaction_id INTEGER PRIMARY KEY AUTOINCREMENT,
      transaction_date TEXT NOT NULL,
      transaction_type TEXT NOT NULL,
      source_file TEXT NOT NULL DEFAULT '',
      fingerprint TEXT NOT NULL UNIQUE,
      billing_client_id INTEGER,
      billing_address TEXT NOT NULL DEFAULT '',
      delivery_address TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT '',
      FOREIGN KEY (billing_client_id) REFERENCES clients(client_id)
    )''');
    await _db.execute('''CREATE TABLE IF NOT EXISTS equipment_master(
      equipment_id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_key TEXT NOT NULL UNIQUE,
      product_name TEXT NOT NULL,
      category TEXT NOT NULL,
      brand TEXT NOT NULL DEFAULT '',
      model TEXT NOT NULL DEFAULT '',
      first_seen TEXT NOT NULL DEFAULT '',
      last_seen TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT ''
    )''');
    await _db.execute('''CREATE TABLE IF NOT EXISTS equipment_events(
      event_id INTEGER PRIMARY KEY AUTOINCREMENT,
      equipment_id INTEGER,
      transaction_id INTEGER,
      serial_numbers TEXT NOT NULL DEFAULT '',
      quantity TEXT NOT NULL DEFAULT '1',
      raw_amount_text TEXT NOT NULL DEFAULT '',
      net_price REAL,
      gst_rate TEXT NOT NULL DEFAULT '',
      transaction_type TEXT NOT NULL,
      status TEXT NOT NULL,
      notes TEXT NOT NULL DEFAULT '',
      FOREIGN KEY (equipment_id) REFERENCES equipment_master(equipment_id),
      FOREIGN KEY (transaction_id) REFERENCES transactions(transaction_id)
    )''');
    await _db.execute('CREATE INDEX IF NOT EXISTS idx_client_gstin ON clients(gstin)');
    await _db.execute('CREATE INDEX IF NOT EXISTS idx_event_serial ON equipment_events(serial_numbers)');
    await _db.execute('CREATE INDEX IF NOT EXISTS idx_event_price ON equipment_events(equipment_id, net_price)');
  }

  String _normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

  String _clientKey(String name, String address, String gstin, String phone) {
    if (gstin.trim().isNotEmpty) return 'gst:${gstin.trim().toUpperCase()}';
    final phoneDigits = phone.replaceAll(RegExp(r'\D'), '');
    final addr = _normalize(address);
    if (phoneDigits.isNotEmpty) return 'phone:$phoneDigits|addr:$addr';
    return 'name:${_normalize(name)}|addr:$addr';
  }

  String _productKey(String product) => _normalize(product);

  String _brand(String product) {
    final l = product.toLowerCase();
    for (final b in ['maico', 'interacoustics', 'inventis', 'labat', 'ihs', 'h.a.c', 'hac']) {
      if (l.contains(b)) return b.toUpperCase();
    }
    return '';
  }

  Future<int> _upsertClient(ParsedRecord r, String date) async {
    final name = r.billingName.isNotEmpty ? r.billingName : (r.deliveryName.isNotEmpty ? r.deliveryName : 'Unknown Client');
    final address = r.billingAddress.isNotEmpty ? r.billingAddress : r.deliveryAddress;
    final key = _clientKey(name, address, r.gstin ?? '', r.phone ?? '');
    final rows = await _db.query('clients', where: 'normalized_key=?', whereArgs: [key], limit: 1);
    final values = {
      'client_name': name,
      'billing_address': address,
      'delivery_address': r.deliveryAddress,
      'gstin': r.gstin ?? '',
      'contact_number': r.phone ?? '',
      'email': r.email ?? '',
      'last_seen': date,
    };
    if (rows.isEmpty) {
      return _db.insert('clients', {...values, 'normalized_key': key, 'first_seen': date});
    }
    final id = rows.first['client_id'] as int;
    await _db.update('clients', values, where: 'client_id=?', whereArgs: [id]);
    return id;
  }

  Future<int> _upsertEquipment(ParsedItem item, String date) async {
    final key = _productKey(item.productName);
    final rows = await _db.query('equipment_master', where: 'product_key=?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) {
      return _db.insert('equipment_master', {
        'product_key': key,
        'product_name': item.productName,
        'category': item.category,
        'brand': _brand(item.productName),
        'model': '',
        'first_seen': date,
        'last_seen': date,
        'notes': '',
      });
    }
    final id = rows.first['equipment_id'] as int;
    await _db.update('equipment_master', {
      'product_name': item.productName,
      'category': item.category,
      'brand': _brand(item.productName),
      'last_seen': date,
    }, where: 'equipment_id=?', whereArgs: [id]);
    return id;
  }

  Future<Map<String, int>> saveRecords(List<ParsedRecord> records, {String sourceFile = ''}) async {
    var clients = 0;
    var transactions = 0;
    var events = 0;
    await _db.transaction((txn) async {
      for (final r in records) {
        final date = r.date.isEmpty ? 'Unknown' : r.date;
        final clientName = r.billingName.isNotEmpty ? r.billingName : (r.deliveryName.isNotEmpty ? r.deliveryName : 'Unknown Client');
        final clientAddress = r.billingAddress.isNotEmpty ? r.billingAddress : r.deliveryAddress;
        final key = _clientKey(clientName, clientAddress, r.gstin ?? '', r.phone ?? '');
        final existing = await txn.query('clients', where: 'normalized_key=?', whereArgs: [key], limit: 1);
        late int clientId;
        if (existing.isEmpty) {
          clientId = await txn.insert('clients', {
            'client_name': clientName,
            'billing_address': r.billingAddress,
            'delivery_address': r.deliveryAddress,
            'normalized_key': key,
            'gstin': r.gstin ?? '',
            'contact_number': r.phone ?? '',
            'email': r.email ?? '',
            'first_seen': date,
            'last_seen': date,
          });
          clients++;
        } else {
          clientId = existing.first['client_id'] as int;
          await txn.update('clients', {
            'client_name': clientName.isNotEmpty && clientName != 'Unknown Client' ? clientName : existing.first['client_name'],
            'billing_address': r.billingAddress.isNotEmpty ? r.billingAddress : existing.first['billing_address'],
            'delivery_address': r.deliveryAddress.isNotEmpty ? r.deliveryAddress : existing.first['delivery_address'],
            'gstin': (r.gstin ?? '').isNotEmpty ? r.gstin : existing.first['gstin'],
            'contact_number': (r.phone ?? '').isNotEmpty ? r.phone : existing.first['contact_number'],
            'email': (r.email ?? '').isNotEmpty ? r.email : existing.first['email'],
            'last_seen': date,
          }, where: 'client_id=?', whereArgs: [clientId]);
        }

        final fingerprint = _normalize('${date}|${r.transactionType}|${key}|${r.billingAddress}|${r.deliveryAddress}|${r.items.map((e) => '${_productKey(e.productName)}|${e.serialNumbers}|${e.rawAmount}').join(';')}');
        final existingTx = await txn.query('transactions', where: 'fingerprint=?', whereArgs: [fingerprint], limit: 1);
        if (existingTx.isNotEmpty) {
          continue;
        }
        final transactionId = await txn.insert('transactions', {
          'transaction_date': date,
          'transaction_type': r.transactionType,
          'source_file': r.sourceFile.isNotEmpty ? r.sourceFile : sourceFile,
          'fingerprint': fingerprint,
          'billing_client_id': clientId,
          'billing_address': r.billingAddress,
          'delivery_address': r.deliveryAddress,
          'notes': r.subject,
        });
        transactions++;

        for (final item in r.items) {
          final keyProduct = _productKey(item.productName);
          final eq = await txn.query('equipment_master', where: 'product_key=?', whereArgs: [keyProduct], limit: 1);
          late int equipmentId;
          if (eq.isEmpty) {
            equipmentId = await txn.insert('equipment_master', {
              'product_key': keyProduct,
              'product_name': item.productName,
              'category': item.category,
              'brand': _brand(item.productName),
              'model': '',
              'first_seen': date,
              'last_seen': date,
              'notes': '',
            });
          } else {
            equipmentId = eq.first['equipment_id'] as int;
            await txn.update('equipment_master', {'category': item.category, 'last_seen': date}, where: 'equipment_id=?', whereArgs: [equipmentId]);
          }

          await txn.insert('equipment_events', {
            'equipment_id': equipmentId,
            'transaction_id': transactionId,
            'serial_numbers': item.serialNumbers,
            'quantity': item.quantity,
            'raw_amount_text': item.rawAmount,
            'net_price': item.netPrice,
            'gst_rate': item.gstRate,
            'transaction_type': item.transactionType,
            'status': item.status,
            'notes': item.notes,
          });
          events++;
        }
      }
    });
    return {'clients': clients, 'transactions': transactions, 'events': events};
  }

  Future<List<Map<String, dynamic>>> dashboard() async {
    Future<int> count(String sql) async {
      final rows = await _db.rawQuery(sql);
      if (rows.isEmpty) return 0;
      final value = rows.first.values.first;
      return value is int ? value : int.tryParse('$value') ?? 0;
    }
    final clients = await count('SELECT COUNT(*) FROM clients');
    final transactions = await count('SELECT COUNT(*) FROM transactions');
    final sales = await count("SELECT COUNT(*) FROM transactions WHERE transaction_type='Sale / Billing'");
    final equipment = await count('SELECT COUNT(*) FROM equipment_master');
    final priced = await count('SELECT COUNT(*) FROM equipment_events WHERE net_price IS NOT NULL');
    return [{'clients': clients, 'transactions': transactions, 'sales': sales, 'equipment': equipment, 'priced_events': priced}];
  }

  Future<List<Map<String, dynamic>>> transactions({String? type, int limit = 200}) async {
    final where = type == null ? '' : 'WHERE t.transaction_type = ?';
    return _db.rawQuery('''SELECT t.*, c.client_name, c.gstin, c.contact_number FROM transactions t LEFT JOIN clients c ON c.client_id=t.billing_client_id $where ORDER BY t.transaction_date DESC, t.transaction_id DESC LIMIT $limit''', type == null ? null : [type]);
  }

  Future<List<Map<String, dynamic>>> eventRows({String? category, String? type, int limit = 500}) async {
    final clauses = <String>[];
    final args = <dynamic>[];
    if (category != null) { clauses.add('e.category=?'); args.add(category); }
    if (type != null) { clauses.add('ev.transaction_type=?'); args.add(type); }
    final w = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _db.rawQuery('''SELECT ev.*, e.product_name, e.category, t.transaction_date, t.transaction_type, c.client_name, c.gstin FROM equipment_events ev JOIN equipment_master e ON e.equipment_id=ev.equipment_id JOIN transactions t ON t.transaction_id=ev.transaction_id LEFT JOIN clients c ON c.client_id=t.billing_client_id $w ORDER BY t.transaction_date DESC, ev.event_id DESC LIMIT $limit''', args);
  }

  Future<List<Map<String, dynamic>>> equipmentMaster({String? category}) async {
    final w = category == null ? '' : 'WHERE e.category=?';
    return _db.rawQuery('''SELECT e.*, COUNT(ev.event_id) AS event_count, MIN(ev.net_price) AS min_price, MAX(ev.net_price) AS max_price FROM equipment_master e LEFT JOIN equipment_events ev ON ev.equipment_id=e.equipment_id $w GROUP BY e.equipment_id ORDER BY e.category, e.product_name''', category == null ? null : [category]);
  }

  Future<List<Map<String, dynamic>>> clients({String query = ''}) async {
    if (query.trim().isEmpty) return _db.query('clients', orderBy: 'client_name ASC');
    final q = '%${query.trim()}%';
    return _db.query('clients', where: 'client_name LIKE ? OR billing_address LIKE ? OR gstin LIKE ? OR contact_number LIKE ?', whereArgs: [q, q, q, q], orderBy: 'client_name ASC');
  }

  Future<List<Map<String, dynamic>>> priceHistory() async {
    return _db.rawQuery('''SELECT e.product_name, e.category, substr(t.transaction_date,1,4) AS year, AVG(ev.net_price) AS avg_price, MIN(ev.net_price) AS min_price, MAX(ev.net_price) AS max_price, COUNT(ev.net_price) AS samples FROM equipment_events ev JOIN equipment_master e ON e.equipment_id=ev.equipment_id JOIN transactions t ON t.transaction_id=ev.transaction_id WHERE ev.net_price IS NOT NULL AND ev.net_price > 0 GROUP BY e.product_name, e.category, substr(t.transaction_date,1,4) ORDER BY e.category, e.product_name, year''');
  }

  Future<String> exportAllJson(String outPath) async {
    final data = {
      'clients': await clients(),
      'transactions': await transactions(limit: 100000),
      'equipment': await equipmentMaster(),
      'events': await eventRows(limit: 100000),
      'priceHistory': await priceHistory(),
    };
    await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return outPath;
  }
}

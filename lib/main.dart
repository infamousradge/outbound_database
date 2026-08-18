import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'parser.dart';
import 'db.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper().init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Outbound Database',
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  List<ParsedRecord> _records = [];
  bool _loading = false;
  TabController? _tabController;

  // Items view state
  List<Map<String, dynamic>> _items = [];
  String? _filterStatus;
  String? _filterCategory;

  // Clients view
  List<Map<String, dynamic>> _clients = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadItems();
    _loadClients();
  }

  Future<void> _loadItems() async {
    final rows = await DatabaseHelper().allItems(status: _filterStatus, category: _filterCategory);
    setState(() => _items = rows);
  }

  int _countByStatus(String status) {
    return _items.where((r) => (r['dispatch_status'] ?? '') == status).length;
  }

  Future<void> _loadClients() async {
    final rows = await DatabaseHelper().fetchClients();
    setState(() => _clients = rows);
  }

  Future<void> _pickDocx() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['docx']);
    if (result == null) return;
    setState(() => _loading = true);
    try {
      final bytes = result.files.first.bytes;
      Uint8List data;
      if (bytes == null) {
        final path = result.files.first.path!;
        data = await File(path).readAsBytes();
      } else {
        data = bytes;
      }
      final recs = parseDocxBytes(data);
      setState(() => _records = recs);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to parse .docx: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _saveAll() async {
    setState(() => _loading = true);
    try {
      await DatabaseHelper().saveParsedRecords(_records);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved parsed records to DB')));
      setState(() => _records = []);
      await _loadItems();
      await _loadClients();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleItemStatus(Map<String, dynamic> item) async {
    final id = item['item_id'] as int;
    final current = item['dispatch_status'] as String? ?? 'Other';
    final next = current == 'Billed' ? 'DC' : 'Billed';
    await DatabaseHelper().updateItemStatus(id, next);
    await _loadItems();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Item $id marked $next')));
  }

  Widget _importTab() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          Row(children: [
            ElevatedButton.icon(onPressed: _pickDocx, icon: const Icon(Icons.upload_file), label: const Text('Import .docx')),
            const SizedBox(width: 12),
            ElevatedButton.icon(onPressed: _records.isEmpty ? null : _saveAll, icon: const Icon(Icons.save), label: const Text('Save All')),
            const SizedBox(width: 12),
            if (_loading) const CircularProgressIndicator(),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _records.isEmpty
                ? const Center(child: Text('No parsed records. Import a .docx to preview.'))
                : ListView.builder(
                    itemCount: _records.length,
                    itemBuilder: (context, idx) {
                      final r = _records[idx];
                      return Card(
                        child: ExpansionTile(
                          title: Text('${r.date} • ${r.dispatchType}'),
                          subtitle: Text(r.billingAddress),
                          children: r.items.asMap().entries.map((entry) {
                            final it = entry.value;
                            final itemIndex = entry.key;
                            return ListTile(
                              title: Text(it.productName),
                              subtitle: Text('${it.category} • ${it.serialNumbers}\n${it.rawAmount} • ${it.gstRate}'),
                              isThreeLine: true,
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                Text(it.status),
                                IconButton(icon: const Icon(Icons.edit), onPressed: () => _editParsedItem(idx, itemIndex)),
                              ]),
                            );
                          }).toList(),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _editParsedItem(int recordIndex, int itemIndex) {
    final item = _records[recordIndex].items[itemIndex];
    final nameCtrl = TextEditingController(text: item.productName);
    final serialCtrl = TextEditingController(text: item.serialNumbers);
    final amountCtrl = TextEditingController(text: item.rawAmount);
    String category = item.category;
    String status = item.status;

    showDialog(context: context, builder: (context) {
      return AlertDialog(
        title: const Text('Edit Item'),
        content: SingleChildScrollView(
          child: Column(
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Product Name')),
              TextField(controller: serialCtrl, decoration: const InputDecoration(labelText: 'Serial Numbers')),
              TextField(controller: amountCtrl, decoration: const InputDecoration(labelText: 'Raw Amount')),
              DropdownButtonFormField<String>(value: category, items: ['Main Equipment','Spares/Accessory','Consumable','Service','Other'].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(), onChanged: (v) => category = v ?? category, decoration: const InputDecoration(labelText: 'Category')),
              DropdownButtonFormField<String>(value: status, items: ['DC','Billed','Pending','Returned','Other'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(), onChanged: (v) => status = v ?? status, decoration: const InputDecoration(labelText: 'Status')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          ElevatedButton(onPressed: () {
            setState(() {
              _records[recordIndex].items[itemIndex] = ParsedItem(
                productName: nameCtrl.text,
                category: category,
                serialNumbers: serialCtrl.text,
                rawAmount: amountCtrl.text,
                netPrice: item.netPrice,
                gstRate: item.gstRate,
                notes: item.notes,
                status: status,
              );
            });
            Navigator.of(context).pop();
          }, child: const Text('Save')),
        ],
      );
    });
  }

  Widget _itemsTab() {
    final statuses = [null, 'DC', 'Billed', 'Pending', 'Returned', 'Other'];
    final categories = [null, 'Main Equipment', 'Spares/Accessory', 'Consumable', 'Service', 'Other'];

    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          Row(children: [
            const Text('Status:'),
            const SizedBox(width: 8),
            DropdownButton<String?>(value: _filterStatus, items: statuses.map((s) => DropdownMenuItem(value: s, child: Text(s ?? 'All'))).toList(), onChanged: (v) { setState(() => _filterStatus = v); _loadItems(); }),
            const SizedBox(width: 16),
            const Text('Category:'),
            const SizedBox(width: 8),
            DropdownButton<String?>(value: _filterCategory, items: categories.map((c) => DropdownMenuItem(value: c, child: Text(c ?? 'All'))).toList(), onChanged: (v) { setState(() => _filterCategory = v); _loadItems(); }),
            const Spacer(),
            Row(children: [
              Column(children: [Text('DC', style: TextStyle(fontWeight: FontWeight.bold)), Text('${_countByStatus('DC')}')]),
              const SizedBox(width: 12),
              Column(children: [Text('Billed', style: TextStyle(fontWeight: FontWeight.bold)), Text('${_countByStatus('Billed')}')]),
              const SizedBox(width: 12),
              Column(children: [Text('Pending', style: TextStyle(fontWeight: FontWeight.bold)), Text('${_countByStatus('Pending')}')]),
            ]),
            const SizedBox(width: 12),
            ElevatedButton.icon(onPressed: _loadItems, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
            const SizedBox(width: 8),
            ElevatedButton.icon(onPressed: _exportCsv, icon: const Icon(Icons.file_download), label: const Text('Export CSV')),
            const SizedBox(width: 8),
            ElevatedButton.icon(onPressed: _exportJson, icon: const Icon(Icons.file_download), label: const Text('Export JSON')),
            const SizedBox(width: 8),
            ElevatedButton.icon(onPressed: _importCsv, icon: const Icon(Icons.file_upload), label: const Text('Import CSV')),
            const SizedBox(width: 8),
            ElevatedButton.icon(onPressed: _importJson, icon: const Icon(Icons.file_upload), label: const Text('Import JSON')),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('No items found'))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final it = _items[i];
                      return Card(
                        child: ListTile(
                          title: Text(it['product_name'] ?? 'Unnamed'),
                          subtitle: Text('Client: ${it['client_name'] ?? ''}\nSerial: ${it['serial_numbers'] ?? ''}\nStatus: ${it['dispatch_status'] ?? ''}'),
                          isThreeLine: true,
                          trailing: PopupMenuButton<String>(onSelected: (v) async { if (v == 'toggle') await _toggleItemStatus(it); }, itemBuilder: (_) => [const PopupMenuItem(value: 'toggle', child: Text('Toggle Billed/DC'))]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportCsv() async {
    final docs = Platform.environment['USERPROFILE'] ?? Directory.current.path;
    final outDir = Directory(p.join(docs, 'Documents', 'OutboundDatabase_exports'));
    await outDir.create(recursive: true);
    final outPath = p.join(outDir.path, 'items_export_${DateTime.now().toIso8601String().replaceAll(':', '-')}.csv');
    try {
      await DatabaseHelper().exportItemsToCsv(outPath);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported CSV to $outPath')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _exportJson() async {
    final docs = Platform.environment['USERPROFILE'] ?? Directory.current.path;
    final outDir = Directory(p.join(docs, 'Documents', 'OutboundDatabase_exports'));
    await outDir.create(recursive: true);
    final outPath = p.join(outDir.path, 'items_export_${DateTime.now().toIso8601String().replaceAll(':', '-')}.json');
    try {
      await DatabaseHelper().exportItemsToJson(outPath);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported JSON to $outPath')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Widget _clientsTab() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          Row(children: [
            const Text('Clients'),
            const Spacer(),
            ElevatedButton.icon(onPressed: _loadClients, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _clients.isEmpty
                ? const Center(child: Text('No clients found'))
                : ListView.builder(
                    itemCount: _clients.length,
                    itemBuilder: (context, i) {
                      final c = _clients[i];
                      return Card(
                        child: ListTile(
                          title: Text(c['client_name'] ?? ''),
                          subtitle: Text('${c['billing_address'] ?? ''}\nGSTIN: ${c['gstin'] ?? ''}\nPhone: ${c['contact_number'] ?? ''}'),
                          isThreeLine: true,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _importCsv() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (result == null) return;
    final path = result.files.first.path!;
    setState(() => _loading = true);
    try {
      await DatabaseHelper().importItemsFromCsv(path);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported CSV and updated DB')));
      await _loadItems();
      await _loadClients();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _importJson() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (result == null) return;
    final path = result.files.first.path!;
    setState(() => _loading = true);
    try {
      await DatabaseHelper().importItemsFromJson(path);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported JSON and updated DB')));
      await _loadItems();
      await _loadClients();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Outbound Database'),
        actions: [
          IconButton(onPressed: _showAbout, icon: const Icon(Icons.info_outline)),
        ],
        bottom: TabBar(controller: _tabController, tabs: const [Tab(text: 'Import'), Tab(text: 'Items'), Tab(text: 'Clients')]),
      ),
      body: TabBarView(controller: _tabController, children: [_importTab(), _itemsTab(), _clientsTab()]),
    );
  }

  void _showAbout() async {
    final dbPath = '';
    showAboutDialog(
      context: context,
      applicationName: 'Outbound Database',
      applicationVersion: '0.1.0',
      applicationLegalese: 'MIT License',
      children: [Text('Database path (on Windows): %APPDATA%\\OutboundDatabase\\outbound_database.db')],
    );
  }
}

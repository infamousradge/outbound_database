import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'parser.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper().init();
  runApp(const OutboundApp());
}

class OutboundApp extends StatelessWidget {
  const OutboundApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = Colors.indigo;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Outbound Database',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
        visualDensity: VisualDensity.standard,
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _index = 0;
  Map<String, int> _stats = const {'clients': 0, 'transactions': 0, 'sales': 0, 'equipment': 0, 'priced_events': 0};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refreshStats();
  }

  Future<void> _refreshStats() async {
    final s = (await DatabaseHelper().dashboard()).first;
    if (mounted) setState(() => _stats = s.map((k, v) => MapEntry(k, v as int)));
  }

  Future<void> _importFiles() async {
    final group = XTypeGroup(label: 'Word documents', extensions: ['docx']);
    final files = await openFiles(acceptedTypeGroups: [group]);
    if (files.isEmpty) return;
    setState(() => _loading = true);
    var allRecords = <ParsedRecord>[];
    final fileNames = <String>[];
    final warnings = <String>[];
    try {
      for (final file in files) {
        try {
          final data = await File(file.path).readAsBytes();
          final records = parseDocxBytes(data);
          for (final r in records) { r.sourceFile = p.basename(file.path); }
          allRecords.addAll(records);
          fileNames.add(p.basename(file.path));
          if (records.isEmpty) warnings.add('${p.basename(file.path)}: no records detected');
        } catch (e) {
          warnings.add('${p.basename(file.path)}: $e');
        }
      }
      if (allRecords.isEmpty) {
        _toast('No transaction records were extracted. Check the Word files.');
      } else {
        final result = await DatabaseHelper().saveRecords(allRecords, sourceFile: fileNames.join('; '));
        await _refreshStats();
        _toast('Imported ${result['transactions']} transactions and ${result['events']} items from ${files.length} Word file(s).');
        if (warnings.isNotEmpty) _showWarnings(warnings);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _exportBackup() async {
    final docs = Platform.environment['USERPROFILE'] ?? Directory.current.path;
    final outDir = Directory(p.join(docs, 'Documents', 'OutboundDatabase_exports'));
    await outDir.create(recursive: true);
    final outPath = p.join(outDir.path, 'outbound_database_backup_${DateTime.now().toIso8601String().replaceAll(':', '-')}.json');
    await DatabaseHelper().exportAllJson(outPath);
    _toast('Backup exported to $outPath');
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  void _showWarnings(List<String> warnings) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import notes'),
        content: SizedBox(width: 600, child: SingleChildScrollView(child: Text(warnings.join('\n')))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeOverview(stats: _stats, onImport: _importFiles, onExport: () { _exportBackup(); }),
      ImportPage(onChanged: _refreshStats),
      const TransactionsPage(),
      const EquipmentPage(),
      const PriceHistoryPage(),
      const ClientsPage(),
    ];
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (v) => setState(() => _index = v),
            extended: MediaQuery.of(context).size.width >= 1100,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Icon(Icons.inventory_2_outlined, size: 34),
            ),
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: Text('Dashboard')),
              NavigationRailDestination(icon: Icon(Icons.upload_file_outlined), selectedIcon: Icon(Icons.upload_file), label: Text('Import')),
              NavigationRailDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: Text('Transactions')),
              NavigationRailDestination(icon: Icon(Icons.precision_manufacturing_outlined), selectedIcon: Icon(Icons.precision_manufacturing), label: Text('Equipment Master')),
              NavigationRailDestination(icon: Icon(Icons.show_chart_outlined), selectedIcon: Icon(Icons.show_chart), label: Text('Price History')),
              NavigationRailDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: Text('Clients')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: Stack(children: [pages[_index], if (_loading) const Positioned.fill(child: ColoredBox(color: Color(0x55303030), child: Center(child: CircularProgressIndicator())))])),
        ],
      ),
    );
  }
}

class HomeOverview extends StatelessWidget {
  final Map<String, int> stats;
  final VoidCallback onImport;
  final VoidCallback onExport;
  const HomeOverview({super.key, required this.stats, required this.onImport, required this.onExport});

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'Outbound Database',
      subtitle: 'Extract Word files into a structured client, sales, equipment and price database.',
      actions: [OutlinedButton.icon(onPressed: onExport, icon: const Icon(Icons.backup_outlined), label: const Text('Export Backup')), const SizedBox(width: 10), FilledButton.icon(onPressed: onImport, icon: const Icon(Icons.upload_file), label: const Text('Import Word Files'))],
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              _Kpi(label: 'Clients', value: '${stats['clients'] ?? 0}', icon: Icons.people),
              _Kpi(label: 'Transactions', value: '${stats['transactions'] ?? 0}', icon: Icons.receipt_long),
              _Kpi(label: 'Sales / Billing', value: '${stats['sales'] ?? 0}', icon: Icons.point_of_sale),
              _Kpi(label: 'Equipment / Item Master', value: '${stats['equipment'] ?? 0}', icon: Icons.inventory_2),
              _Kpi(label: 'Price observations', value: '${stats['priced_events'] ?? 0}', icon: Icons.currency_rupee),
            ],
          ),
          const SizedBox(height: 28),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                Text('What the app extracts', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                SizedBox(height: 12),
                Text('• Client master: name, billing/delivery address, GSTIN, phone and email.\n• Transactions: Sale/Billing, DC, Demo, Repair/Service and Return.\n• Equipment master: standardized product category and product history.\n• Price history: yearly min / average / max values from the amounts found in the Word files.\n• Serial numbers and quantities stay attached to each transaction event.'),
              ]),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                Text('Important', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                SizedBox(height: 8),
                Text('The original documents use several field names — Product, Device, Item and Transducer — and contain both sales and non-sales movements. This version recognizes those variants instead of treating unmatched lines as “Unknown Product”.'),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _Kpi({required this.label, required this.value, required this.icon});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 210,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [Icon(icon, size: 30), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)), Text(label, style: Theme.of(context).textTheme.bodySmall)])])
          ),
        ),
      );
}

class ImportPage extends StatefulWidget {
  final Future<void> Function() onChanged;
  const ImportPage({super.key, required this.onChanged});
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  List<ParsedRecord> _preview = [];
  bool _busy = false;
  String _message = 'Select one or more .docx files. The app will extract the entire batch and save it into the database.';

  Future<void> _choose() async {
    final group = XTypeGroup(label: 'Word documents', extensions: ['docx']);
    final files = await openFiles(acceptedTypeGroups: [group]);
    if (files.isEmpty) return;
    setState(() => _busy = true);
    final records = <ParsedRecord>[];
    final sourceNames = <String>[];
    try {
      for (final f in files) {
        final bytes = await File(f.path).readAsBytes();
        final parsed = parseDocxBytes(bytes);
        for (final r in parsed) { r.sourceFile = p.basename(f.path); }
        records.addAll(parsed);
        sourceNames.add(p.basename(f.path));
      }
      setState(() {
        _preview = records;
        _message = 'Parsed ${records.length} transaction blocks from ${files.length} file(s).';
      });
      final result = await DatabaseHelper().saveRecords(records, sourceFile: sourceNames.join('; '));
      setState(() => _message = 'Saved ${result['transactions']} transactions and ${result['events']} item events.');
      await widget.onChanged();
    } catch (e) {
      setState(() => _message = 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _PageScaffold(
        title: 'Import & Review',
        subtitle: 'Batch-import your historical Word files and save structured records.',
        actions: [FilledButton.icon(onPressed: _busy ? null : _choose, icon: const Icon(Icons.folder_open), label: const Text('Choose DOCX Files'))],
        child: Column(children: [
          Container(width: double.infinity, margin: const EdgeInsets.fromLTRB(24, 16, 24, 12), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)), child: Row(children: [const Icon(Icons.info_outline), const SizedBox(width: 10), Expanded(child: Text(_message))])),
          Expanded(child: _preview.isEmpty ? const Center(child: Text('No import preview yet.')) : ListView.builder(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), itemCount: _preview.length, itemBuilder: (_, i) => _RecordCard(record: _preview[i]))),
        ]),
      );
}

class _RecordCard extends StatelessWidget {
  final ParsedRecord record;
  const _RecordCard({required this.record});
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ExpansionTile(
          title: Row(children: [Text(record.date, style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(width: 12), Chip(label: Text(record.transactionType))]),
          subtitle: Text(record.billingName.isEmpty ? record.billingAddress : '${record.billingName} • ${record.billingAddress}'),
          children: record.items.map((item) => ListTile(dense: true, leading: Icon(_categoryIcon(item.category)), title: Text(item.productName), subtitle: Text('${item.category} • Serial: ${item.serialNumbers} • Qty: ${item.quantity}'), trailing: item.netPrice == null ? null : Text('₹${item.netPrice!.toStringAsFixed(0)}'))).toList(),
        ),
      );

  IconData _categoryIcon(String c) => switch (c) {
        'Main Equipment' => Icons.precision_manufacturing,
        'Spares & Accessories' => Icons.build_outlined,
        'Consumables' => Icons.inventory_2_outlined,
        'Calibration & Service' => Icons.handyman_outlined,
        _ => Icons.category_outlined,
      };
}

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({super.key});
  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}
class _TransactionsPageState extends State<TransactionsPage> {
  String? _type;
  Future<List<Map<String, dynamic>>> _load() => DatabaseHelper().transactions(type: _type);
  @override
  Widget build(BuildContext context) => _PageScaffold(
        title: 'Transactions',
        subtitle: 'All extracted movements, separated into sales, DC, demos, service and returns.',
        actions: [DropdownButton<String?>(value: _type, hint: const Text('All types'), items: [const DropdownMenuItem(value: null, child: Text('All types')), ...['Sale / Billing', 'DC / Internal Movement', 'Demo', 'Repair / Service', 'Return', 'Other'].map((x) => DropdownMenuItem(value: x, child: Text(x)))], onChanged: (v) => setState(() => _type = v)), const SizedBox(width: 12), IconButton(onPressed: () => setState(() {}), icon: const Icon(Icons.refresh))],
        child: FutureBuilder<List<Map<String, dynamic>>>(future: _load(), builder: (_, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final rows = snap.data!;
          return ListView.separated(padding: const EdgeInsets.all(24), itemCount: rows.length, separatorBuilder: (_, __) => const SizedBox(height: 8), itemBuilder: (_, i) {
            final r = rows[i];
            return Card(child: ListTile(leading: const Icon(Icons.receipt_long), title: Text('${r['transaction_date']} • ${r['client_name'] ?? 'Unknown client'}'), subtitle: Text('${r['transaction_type']} • GSTIN: ${r['gstin'] ?? ''}\n${r['billing_address'] ?? ''}'), isThreeLine: true));
          });
        }),
      );
}

class EquipmentPage extends StatefulWidget {
  const EquipmentPage({super.key});
  @override
  State<EquipmentPage> createState() => _EquipmentPageState();
}
class _EquipmentPageState extends State<EquipmentPage> {
  String? _category;
  @override
  Widget build(BuildContext context) => _PageScaffold(
        title: 'Equipment & Item Master',
        subtitle: 'Deduplicated products with category, price range and number of historical observations.',
        actions: [DropdownButton<String?>(value: _category, hint: const Text('All categories'), items: [const DropdownMenuItem(value: null, child: Text('All categories')), ...['Main Equipment', 'Spares & Accessories', 'Consumables', 'Calibration & Service', 'Other'].map((x) => DropdownMenuItem(value: x, child: Text(x)))], onChanged: (v) => setState(() => _category = v))],
        child: FutureBuilder<List<Map<String, dynamic>>>(future: DatabaseHelper().equipmentMaster(category: _category), builder: (_, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView.builder(padding: const EdgeInsets.all(24), itemCount: snap.data!.length, itemBuilder: (_, i) {
            final r = snap.data![i];
            return Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(
              leading: CircleAvatar(child: Text('${i + 1}')),
              title: Text(r['product_name'] ?? ''),
              subtitle: Text('${r['category']} • ${r['brand'] ?? ''}\nSeen ${r['first_seen']} → ${r['last_seen']} • ${r['event_count']} events'),
              isThreeLine: true,
              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [Text(r['min_price'] == null ? 'No price' : '₹${(r['min_price'] as num).toStringAsFixed(0)} min'), Text(r['max_price'] == null ? '' : '₹${(r['max_price'] as num).toStringAsFixed(0)} max')]),
            ));
          });
        }),
      );
}

class PriceHistoryPage extends StatefulWidget {
  const PriceHistoryPage({super.key});
  @override
  State<PriceHistoryPage> createState() => _PriceHistoryPageState();
}
class _PriceHistoryPageState extends State<PriceHistoryPage> {
  @override
  Widget build(BuildContext context) => _PageScaffold(
        title: 'Price History',
        subtitle: 'Compare the prices recorded for the same equipment, spare or service across years.',
        actions: [IconButton(onPressed: () => setState(() {}), icon: const Icon(Icons.refresh))],
        child: FutureBuilder<List<Map<String, dynamic>>>(future: DatabaseHelper().priceHistory(), builder: (_, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final rows = snap.data!;
          return SingleChildScrollView(padding: const EdgeInsets.all(24), child: DataTable(columnSpacing: 28, columns: const [DataColumn(label: Text('Product')), DataColumn(label: Text('Category')), DataColumn(label: Text('Year')), DataColumn(label: Text('Samples')), DataColumn(label: Text('Min')), DataColumn(label: Text('Average')), DataColumn(label: Text('Max'))], rows: rows.map((r) => DataRow(cells: [DataCell(Text('${r['product_name']}')), DataCell(Text('${r['category']}')), DataCell(Text('${r['year']}')), DataCell(Text('${r['samples']}')), DataCell(Text('₹${(r['min_price'] as num).toStringAsFixed(0)}')), DataCell(Text('₹${(r['avg_price'] as num).toStringAsFixed(0)}')), DataCell(Text('₹${(r['max_price'] as num).toStringAsFixed(0)}'))])).toList()));
        }),
      );
}

class ClientsPage extends StatefulWidget {
  const ClientsPage({super.key});
  @override
  State<ClientsPage> createState() => _ClientsPageState();
}
class _ClientsPageState extends State<ClientsPage> {
  final _search = TextEditingController();
  @override
  void dispose() { _search.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => _PageScaffold(
        title: 'Client Master',
        subtitle: 'Deduplicated client records with billing/delivery addresses, GSTIN and contact details.',
        actions: [SizedBox(width: 280, child: TextField(controller: _search, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search client, GSTIN, address', border: OutlineInputBorder()), onChanged: (_) => setState(() {}))],
        child: FutureBuilder<List<Map<String, dynamic>>>(future: DatabaseHelper().clients(query: _search.text), builder: (_, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView.builder(padding: const EdgeInsets.all(24), itemCount: snap.data!.length, itemBuilder: (_, i) {
            final r = snap.data![i];
            return Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(leading: const CircleAvatar(child: Icon(Icons.person)), title: Text(r['client_name'] ?? 'Unknown'), subtitle: Text('${r['billing_address'] ?? ''}\nDelivery: ${r['delivery_address'] ?? ''}\nGSTIN: ${r['gstin'] ?? ''} • Phone: ${r['contact_number'] ?? ''}'), isThreeLine: true));
          });
        }),
      );
}

class _PageScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final Widget child;
  const _PageScaffold({required this.title, required this.subtitle, required this.actions, required this.child});
  @override
  Widget build(BuildContext context) => Column(children: [
    Container(padding: const EdgeInsets.fromLTRB(24, 22, 24, 16), decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)), const SizedBox(height: 4), Text(subtitle)])), ...actions]),
    Expanded(child: child),
  ]);
}

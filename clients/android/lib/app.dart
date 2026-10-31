import 'package:flutter/material.dart';

import 'core.dart';
import 'db.dart';
import 'money.dart';

int _byName(Entity a, Entity b) {
  final s = a.sort.compareTo(b.sort);
  return s != 0 ? s : a.str('name').compareTo(b.str('name'));
}

class ZeroSumApp extends StatelessWidget {
  const ZeroSumApp({super.key, required this.db});
  final Db db;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'zero-sum',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        home: Home(db: db),
      );
}

class Home extends StatefulWidget {
  const Home({super.key, required this.db});
  final Db db;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  int _tab = 0;
  String _month = thisMonth();
  Db get db => widget.db;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (db.serverUrl.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _server());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Pull on foreground, as the architecture requires.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      db
        ..connect()
        ..sync();
    }
  }

  Future<void> _server() async {
    final url = await promptText(context, 'Server URL',
        initial: db.serverUrl,
        hint: 'https://mac-mini.tailnet.ts.net',
        keyboard: TextInputType.url);
    if (url != null) await db.setServer(url);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: db,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: const Text('zero-sum'),
            actions: [
              _SyncChip(db: db),
              IconButton(
                  icon: const Icon(Icons.settings), tooltip: 'Server', onPressed: _server),
            ],
          ),
          body: switch (_tab) {
            0 => BudgetPage(
                db: db, month: _month, setMonth: (m) => setState(() => _month = m)),
            1 => TransactionsPage(db: db),
            _ => AccountsPage(db: db),
          },
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.pie_chart), label: 'Budget'),
              NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Transactions'),
              NavigationDestination(icon: Icon(Icons.account_balance), label: 'Accounts'),
            ],
          ),
        ),
      );
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.db});
  final Db db;

  @override
  Widget build(BuildContext context) {
    final label = switch (db.state) {
      SyncState.idle => db.serverUrl.isEmpty ? 'No server' : 'Synced',
      SyncState.syncing => 'Syncing…',
      SyncState.offline => 'Offline',
    };
    final pending = db.outbox.isEmpty ? '' : ' · ${db.outbox.length} pending';
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text('$label$pending', key: const Key('sync'), style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

// ---- dialogs ----

Future<String?> promptText(BuildContext context, String title,
    {String initial = '', String? hint, TextInputType? keyboard}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: keyboard,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String question) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(question),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    ) ??
    false;

void _toast(BuildContext context, Object e) => ScaffoldMessenger.of(context)
    .showSnackBar(SnackBar(content: Text(e is CoreException ? e.message : '$e')));

// ---- budget ----

class BudgetPage extends StatefulWidget {
  const BudgetPage({super.key, required this.db, required this.month, required this.setMonth});
  final Db db;
  final String month;
  final void Function(String) setMonth;

  @override
  State<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends State<BudgetPage> {
  int _forVersion = -1;
  String _forMonth = '';
  Map<String, dynamic> _budget = const {};

  Db get db => widget.db;

  /// Recompute only when data or month changed.
  Map<String, dynamic> _compute() {
    if (_forVersion != db.version || _forMonth != widget.month) {
      _budget = Core.instance.budget(
          [for (final e in db.entities.values) e.json], widget.month);
      _forVersion = db.version;
      _forMonth = widget.month;
    }
    return _budget;
  }

  @override
  Widget build(BuildContext context) {
    final b = _compute();
    final rta = b['ready_to_assign'] as int;
    final rows = {
      for (final c in b['categories'] as List) c['category_id'] as String: c as Map<String, dynamic>
    };
    final groups = db.list('category_group')..sort(_byName);
    final cats = db.list('category')..sort(_byName);
    final theme = Theme.of(context);
    final red = theme.colorScheme.error;

    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          IconButton(
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => widget.setMonth(shiftMonth(widget.month, -1))),
          Text(widget.month, key: const Key('month'), style: theme.textTheme.titleMedium),
          IconButton(
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => widget.setMonth(shiftMonth(widget.month, 1))),
          const Spacer(),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('Ready to Assign', style: theme.textTheme.labelSmall),
            Text(fmt(rta),
                key: const Key('rta'),
                style: theme.textTheme.titleMedium?.copyWith(color: rta < 0 ? red : null)),
          ]),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView(children: [
          for (final g in groups) ...[
            Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: ListTile(
                dense: true,
                title: Text(g.str('name'), style: const TextStyle(fontWeight: FontWeight.bold)),
                trailing: IconButton(
                  tooltip: 'Delete group',
                  icon: const Icon(Icons.close),
                  onPressed: () async {
                    if (await confirm(context, 'Delete group ${g.str('name')}?')) {
                      await db.remove('category_group', g.id);
                    }
                  },
                ),
              ),
            ),
            for (final c in cats.where((c) => c.data['group_id'] == g.id))
              _CategoryRow(
                db: db,
                month: widget.month,
                cat: c,
                row: rows[c.id],
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.add),
              title: const Text('Add category'),
              onTap: () async {
                final n = (await promptText(context, 'New category'))?.trim();
                if (n != null && n.isNotEmpty) {
                  await db.edit('category', newId(), {'group_id': g.id, 'name': n});
                }
              },
            ),
          ],
          ListTile(
            leading: const Icon(Icons.create_new_folder),
            title: const Text('Add category group'),
            onTap: () async {
              final n = (await promptText(context, 'New category group'))?.trim();
              if (n != null && n.isNotEmpty) {
                await db.edit('category_group', newId(), {'name': n, 'sort': groups.length});
              }
            },
          ),
        ]),
      ),
    ]);
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.db, required this.month, required this.cat, this.row});
  final Db db;
  final String month;
  final Entity cat;
  final Map<String, dynamic>? row;

  @override
  Widget build(BuildContext context) {
    final assigned = (row?['assigned'] as int?) ?? 0;
    final activity = (row?['activity'] as int?) ?? 0;
    final available = (row?['available'] as int?) ?? 0;
    final red = Theme.of(context).colorScheme.error;
    return ListTile(
      key: Key('cat-${cat.str('name')}'),
      title: Text(cat.str('name')),
      subtitle: Text('Assigned ${fmt(assigned)}  ·  Activity ${fmt(activity)}'),
      trailing: Text(fmt(available),
          style: TextStyle(fontWeight: FontWeight.bold, color: available < 0 ? red : null)),
      onTap: () async {
        final text = await promptText(context, 'Assigned to ${cat.str('name')}',
            initial: fmt(assigned),
            keyboard: const TextInputType.numberWithOptions(decimal: true, signed: true));
        if (text == null) return;
        final v = parseAmount(text);
        if (v == null || v == assigned) return;
        try {
          await db.edit('budget_entry', Core.instance.budgetEntryId(cat.id, month),
              {'category_id': cat.id, 'month': month, 'assigned': v});
        } catch (e) {
          if (context.mounted) _toast(context, e);
        }
      },
    );
  }
}

// ---- accounts ----

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key, required this.db});
  final Db db;

  @override
  Widget build(BuildContext context) {
    final balances = <String, int>{};
    for (final t in db.list('transaction')) {
      final a = t.data['account_id'] as String;
      balances[a] = (balances[a] ?? 0) + (t.data['amount'] as int);
    }
    final accounts = db.list('account')..sort(_byName);
    return Scaffold(
      body: ListView(children: [
        for (final a in accounts)
          ListTile(
            title: Text(a.str('name')),
            subtitle: a.data['on_budget'] == false ? const Text('Tracking') : null,
            trailing: Text(fmt(balances[a.id] ?? 0)),
          ),
        if (accounts.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('Add an account to start.')),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Account'),
        onPressed: () => _addAccount(context),
      ),
    );
  }

  Future<void> _addAccount(BuildContext context) async {
    final name = TextEditingController();
    var onBudget = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New account'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name')),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('On budget'),
                value: onBudget,
                onChanged: (v) => set(() => onBudget = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    await db.edit('account', newId(), {
      'name': name.text.trim(),
      'kind': onBudget ? 'checking' : 'other',
      'on_budget': onBudget,
    });
  }
}

// ---- transactions ----

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({super.key, required this.db});
  final Db db;

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  String? _account;
  Db get db => widget.db;

  @override
  Widget build(BuildContext context) {
    final accounts = db.list('account')..sort(_byName);
    if (accounts.isEmpty) {
      return const Center(child: Text('Add an account to start.'));
    }
    String name(List<Entity> l, Object? id) {
      for (final e in l) {
        if (e.id == id) return e.str('name');
      }
      return '';
    }

    final payees = db.list('payee');
    final cats = db.list('category');
    final txs = db
        .list('transaction')
        .where((t) => _account == null || t.data['account_id'] == _account)
        .toList()
      ..sort((a, b) => b.str('date').compareTo(a.str('date')));

    return Scaffold(
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: DropdownButtonFormField<String?>(
            initialValue: _account,
            decoration: const InputDecoration(labelText: 'Account'),
            items: [
              const DropdownMenuItem(value: null, child: Text('All accounts')),
              for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.str('name'))),
            ],
            onChanged: (v) => setState(() => _account = v),
          ),
        ),
        Expanded(
          child: ListView(children: [
            for (final t in txs)
              Dismissible(
                key: Key('tx-${t.id}'),
                direction: DismissDirection.endToStart,
                background: Container(
                    color: Theme.of(context).colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    child: const Icon(Icons.delete)),
                onDismissed: (_) => db.remove('transaction', t.id),
                child: ListTile(
                  title: Text(name(payees, t.data['payee_id']).ifEmpty('—')),
                  subtitle: Text([
                    t.str('date'),
                    if (_account == null) name(accounts, t.data['account_id']),
                    name(cats, t.data['category_id']).ifEmpty('Income'),
                    if (t.str('memo').isNotEmpty) t.str('memo'),
                  ].join(' · ')),
                  trailing: Text(fmt(t.data['amount'] as int),
                      style: TextStyle(
                          color: (t.data['amount'] as int) < 0
                              ? Theme.of(context).colorScheme.error
                              : Colors.green)),
                ),
              ),
          ]),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Transaction'),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => TxForm(db: db, account: _account),
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class TxForm extends StatefulWidget {
  const TxForm({super.key, required this.db, this.account});
  final Db db;
  final String? account;

  @override
  State<TxForm> createState() => _TxFormState();
}

class _TxFormState extends State<TxForm> {
  late DateTime _date = DateTime.now();
  late String? _account = widget.account ?? widget.db.list('account').firstOrNull?.id;
  String? _category;
  bool _inflow = false;
  final _amount = TextEditingController();
  final _memo = TextEditingController();
  TextEditingController? _payee;

  Future<void> _save() async {
    final db = widget.db;
    final v = parseAmount(_amount.text);
    if (v == null || _account == null) {
      _toast(context, 'Enter a valid amount');
      return;
    }
    String? payeeId;
    final name = (_payee?.text ?? '').trim();
    if (name.isNotEmpty) {
      final hit = db
          .list('payee')
          .where((p) => p.str('name').toLowerCase() == name.toLowerCase())
          .firstOrNull;
      payeeId = hit?.id ?? newId();
      if (hit == null) await db.edit('payee', payeeId, {'name': name});
    }
    final memo = _memo.text.trim();
    try {
      await db.edit('transaction', newId(), {
        'account_id': _account,
        'date': isoDate(_date),
        'amount': _inflow ? v.abs() : -v.abs(),
        'payee_id': payeeId,
        'category_id': _category,
        'memo': memo.isEmpty ? null : memo,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _toast(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    final accounts = db.list('account')..sort(_byName);
    final cats = db.list('category')..sort(_byName);
    final payees = [for (final p in db.list('payee')) p.str('name')];
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today),
                label: Text(isoDate(_date)),
                onPressed: () async {
                  final d = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100));
                  if (d != null) setState(() => _date = d);
                },
              ),
            ),
          ]),
          DropdownButtonFormField<String>(
            initialValue: _account,
            decoration: const InputDecoration(labelText: 'Account'),
            items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.str('name')))],
            onChanged: (v) => _account = v,
          ),
          Autocomplete<String>(
            optionsBuilder: (v) => payees.where((p) => p.toLowerCase().contains(v.text.toLowerCase())),
            fieldViewBuilder: (ctx, c, focus, _) {
              _payee = c;
              return TextField(
                  controller: c, focusNode: focus, decoration: const InputDecoration(labelText: 'Payee'));
            },
          ),
          DropdownButtonFormField<String?>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Income (Ready to Assign)')),
              for (final c in cats) DropdownMenuItem(value: c.id, child: Text(c.str('name'))),
            ],
            onChanged: (v) => _category = v,
          ),
          TextField(controller: _memo, decoration: const InputDecoration(labelText: 'Memo')),
          TextField(
            controller: _amount,
            key: const Key('amount'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount'),
          ),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Inflow'),
              value: _inflow,
              onChanged: (v) => setState(() => _inflow = v)),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('Add'))),
        ]),
      ),
    );
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';

import 'core.dart';
import 'db.dart';
import 'ledger.dart';
import 'money.dart';

int _byName(Entity a, Entity b) {
  final s = a.sort.compareTo(b.sort);
  return s != 0
      ? s
      : a.str('name').toLowerCase().compareTo(b.str('name').toLowerCase());
}

/// Newest first: date, then when the date was last edited, then id.
int _byNewest(Entity a, Entity b) {
  final d = b.str('date').compareTo(a.str('date'));
  if (d != 0) return d;
  int ts(Entity e) => ((e.json['stamps'] as Map?)?['date']?['ts'] as int?) ?? 0;
  final t = ts(b).compareTo(ts(a));
  return t != 0 ? t : a.id.compareTo(b.id);
}

class ZeroSumApp extends StatelessWidget {
  const ZeroSumApp({super.key, required this.db});
  final Db db;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'zero-sum',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
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
    final url = await promptText(
      context,
      'Server URL',
      initial: db.serverUrl,
      hint: 'https://mac-mini.tailnet.ts.net',
      keyboard: TextInputType.url,
    );
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
            icon: const Icon(Icons.settings),
            tooltip: 'Server',
            onPressed: _server,
          ),
        ],
      ),
      body: switch (_tab) {
        0 => BudgetPage(
          db: db,
          month: _month,
          setMonth: (m) => setState(() => _month = m),
        ),
        1 => TransactionsPage(db: db),
        _ => AccountsPage(db: db),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.pie_chart), label: 'Budget'),
          NavigationDestination(
            icon: Icon(Icons.receipt_long),
            label: 'Transactions',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance),
            label: 'Accounts',
          ),
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
      child: Text(
        '$label$pending',
        key: const Key('sync'),
        style: Theme.of(context).textTheme.labelMedium,
      ),
    );
  }
}

// ---- dialogs ----

Future<String?> promptText(
  BuildContext context,
  String title, {
  String initial = '',
  String? hint,
  TextInputType? keyboard,
}) {
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
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, c.text),
          child: const Text('OK'),
        ),
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

void _toast(BuildContext context, Object e) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(e is CoreException ? e.message : '$e')));

// ---- budget ----

class BudgetPage extends StatefulWidget {
  const BudgetPage({
    super.key,
    required this.db,
    required this.month,
    required this.setMonth,
  });
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
      _budget = Core.instance.budget([
        for (final e in db.entities.values) e.json,
      ], widget.month);
      _forVersion = db.version;
      _forMonth = widget.month;
    }
    return _budget;
  }

  /// D1: a group that still has categories cannot be deleted.
  Future<void> _deleteGroup(Entity g) async {
    if (categoriesInGroup(db, g.id).isNotEmpty) {
      _toast(
        context,
        'Move or delete the categories in ${g.str('name')} first.',
      );
      return;
    }
    if (await confirm(context, 'Delete group ${g.str('name')}?')) {
      await db.remove('category_group', g.id);
    }
  }

  Widget _categoryRow(
    Entity c,
    Map<String, Map<String, dynamic>> rows,
    List<Entity> groups,
    bool orphaned,
  ) => _CategoryRow(
    db: db,
    month: widget.month,
    cat: c,
    row: rows[c.id],
    groups: orphaned ? groups : null,
  );

  @override
  Widget build(BuildContext context) {
    final b = _compute();
    final rta = b['ready_to_assign'] as int;
    final rows = {
      for (final c in b['categories'] as List)
        c['category_id'] as String: c as Map<String, dynamic>,
    };
    final groups = db.list('category_group')..sort(_byName);
    final cats = db.list('category')..sort(_byName);
    final orphaned = {
      for (final id in (b['orphaned_category_ids'] as List?) ?? const [])
        id as String,
    };
    final theme = Theme.of(context);
    final red = theme.colorScheme.error;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Previous month',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => widget.setMonth(shiftMonth(widget.month, -1)),
              ),
              Text(
                widget.month,
                key: const Key('month'),
                style: theme.textTheme.titleMedium,
              ),
              IconButton(
                tooltip: 'Next month',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => widget.setMonth(shiftMonth(widget.month, 1)),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Ready to Assign', style: theme.textTheme.labelSmall),
                  Text(
                    fmt(rta),
                    key: const Key('rta'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: rta < 0 ? red : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final g in groups) ...[
                Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: ListTile(
                    dense: true,
                    title: Text(
                      g.str('name'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    trailing: IconButton(
                      tooltip: 'Delete group',
                      icon: const Icon(Icons.close),
                      onPressed: () => _deleteGroup(g),
                    ),
                  ),
                ),
                for (final c in cats.where((c) => c.data['group_id'] == g.id))
                  _categoryRow(c, rows, groups, false),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add),
                  title: const Text('Add category'),
                  onTap: () async {
                    final n = (await promptText(
                      context,
                      'New category',
                    ))?.trim();
                    if (n != null && n.isNotEmpty) {
                      await db.edit('category', newId(), {
                        'group_id': g.id,
                        'name': n,
                      });
                    }
                  },
                ),
              ],
              // D2: categories whose group is gone stay visible, so no money hides.
              if (orphaned.isNotEmpty) ...[
                Container(
                  key: const Key('orphaned'),
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const ListTile(
                    dense: true,
                    title: Text(
                      'Orphaned (group was deleted)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                for (final c in cats.where((c) => orphaned.contains(c.id)))
                  _categoryRow(c, rows, groups, true),
              ],
              ListTile(
                leading: const Icon(Icons.create_new_folder),
                title: const Text('Add category group'),
                onTap: () async {
                  final n = (await promptText(
                    context,
                    'New category group',
                  ))?.trim();
                  if (n != null && n.isNotEmpty) {
                    await db.edit('category_group', newId(), {
                      'name': n,
                      'sort': groups.length,
                    });
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.db,
    required this.month,
    required this.cat,
    this.row,
    this.groups,
  });
  final Db db;
  final String month;
  final Entity cat;
  final Map<String, dynamic>? row;

  /// Set for an orphaned category: the groups it can move to.
  final List<Entity>? groups;

  Future<void> _delete(BuildContext context) async {
    if (txsInCategory(db, cat.id).isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => _DeleteCategoryDialog(db: db, category: cat),
      );
    } else if (await confirm(
      context,
      'Delete category ${cat.str('name')}? Money assigned to it returns to Ready to Assign.',
    )) {
      await deleteEmptyCategory(db, cat.id);
    }
  }

  Future<void> _move(BuildContext context) async {
    final gs = groups!;
    if (gs.isEmpty) {
      _toast(context, 'Add a category group first.');
      return;
    }
    final g = await showDialog<Entity>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Move ${cat.str('name')} to'),
        children: [
          for (final g in gs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g),
              child: Text(g.str('name')),
            ),
        ],
      ),
    );
    if (g != null) await db.edit('category', cat.id, {'group_id': g.id});
  }

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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            fmt(available),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: available < 0 ? red : null,
            ),
          ),
          PopupMenuButton<String>(
            key: Key('menu-${cat.str('name')}'),
            tooltip: 'Category actions',
            onSelected: (v) => v == 'move' ? _move(context) : _delete(context),
            itemBuilder: (_) => [
              if (groups != null)
                const PopupMenuItem(
                  value: 'move',
                  child: Text('Move to group…'),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete category'),
              ),
            ],
          ),
        ],
      ),
      onTap: () async {
        final text = await promptText(
          context,
          'Assigned to ${cat.str('name')}',
          initial: fmt(assigned),
          keyboard: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
        );
        if (text == null) return;
        final v = parseAmount(text);
        if (v == null || v == assigned) return;
        try {
          await db.edit(
            'budget_entry',
            Core.instance.budgetEntryId(cat.id, month),
            {'category_id': cat.id, 'month': month, 'assigned': v},
          );
        } catch (e) {
          if (context.mounted) _toast(context, e);
        }
      },
    );
  }
}

/// D3: a category with transactions is deleted only after they are deleted or
/// moved to another category.
class _DeleteCategoryDialog extends StatefulWidget {
  const _DeleteCategoryDialog({required this.db, required this.category});
  final Db db;
  final Entity category;

  @override
  State<_DeleteCategoryDialog> createState() => _DeleteCategoryDialogState();
}

class _DeleteCategoryDialogState extends State<_DeleteCategoryDialog> {
  String? _target;

  Future<void> _run(Future<void> Function() op) async {
    try {
      await op();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _toast(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = widget.db, cat = widget.category;
    final n = txsInCategory(db, cat.id).length;
    final others = db.list('category').where((c) => c.id != cat.id).toList()
      ..sort(_byName);
    return AlertDialog(
      title: Text('Delete category ${cat.str('name')}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$n transaction${n == 1 ? '' : 's'} use it. Move them to another '
            'category or delete them. Money assigned to it returns to Ready '
            'to Assign.',
          ),
          DropdownButtonFormField<String>(
            key: const Key('move-target'),
            initialValue: _target,
            decoration: const InputDecoration(
              labelText: 'Move transactions to',
            ),
            items: [
              for (final c in others)
                DropdownMenuItem(value: c.id, child: Text(c.str('name'))),
            ],
            onChanged: (v) => setState(() => _target = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            if (!await confirm(
              context,
              'Delete $n transaction${n == 1 ? '' : 's'} and the category? '
              'This cannot be undone.',
            )) {
              return;
            }
            await _run(() => deleteCategoryTransactions(db, cat.id));
          },
          child: const Text('Delete transactions'),
        ),
        FilledButton(
          onPressed: _target == null
              ? null
              : () =>
                    _run(() => moveCategoryTransactions(db, cat.id, _target!)),
          child: const Text('Move and delete'),
        ),
      ],
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
      body: ListView(
        children: [
          for (final a in accounts)
            ListTile(
              title: Text(a.str('name')),
              subtitle: a.data['on_budget'] == false
                  ? const Text('Tracking')
                  : null,
              trailing: Text(fmt(balances[a.id] ?? 0)),
            ),
          if (accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Add an account to start.'),
            ),
        ],
      ),
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
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('On budget'),
                value: onBudget,
                onChanged: (v) => set(() => onBudget = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add'),
            ),
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

  void _form({Entity? editing}) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => TxForm(db: db, account: _account, editing: editing),
  );

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

    String payeeCell(Entity t) {
      if (!isTransfer(t)) return name(payees, t.data['payee_id']);
      final other = name(accounts, t.data['transfer_account_id']);
      final label = (t.data['amount'] as int) < 0
          ? 'Transfer to $other'
          : 'Transfer from $other';
      return isUnmatched(db, t) ? '$label (unmatched)' : label;
    }

    String categoryCell(Entity t) {
      final lines = splitsOf(t);
      if (lines.isNotEmpty) return 'Split (${lines.length})';
      final c = name(cats, t.data['category_id']);
      return isTransfer(t) ? c : c.ifEmpty('Income');
    }

    final txs =
        db
            .list('transaction')
            .where((t) => _account == null || t.data['account_id'] == _account)
            .toList()
          ..sort(_byNewest);

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: DropdownButtonFormField<String?>(
              initialValue: _account,
              decoration: const InputDecoration(labelText: 'Account'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('All accounts'),
                ),
                for (final a in accounts)
                  DropdownMenuItem(value: a.id, child: Text(a.str('name'))),
              ],
              onChanged: (v) => setState(() => _account = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final t in txs)
                  Dismissible(
                    key: Key('tx-${t.id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Theme.of(context).colorScheme.errorContainer,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 16),
                      child: const Icon(Icons.delete),
                    ),
                    // Delete here and refuse the dismissal: the row leaves the
                    // list when the edit lands, which also skips a cancelled
                    // transfer prompt cleanly.
                    confirmDismiss: (_) async {
                      if (isTransfer(t) &&
                          !await confirm(
                            context,
                            'Delete both legs of this transfer?',
                          )) {
                        return false;
                      }
                      await removeTransaction(db, t);
                      return false;
                    },
                    child: ListTile(
                      key: Key('row-${t.id}'),
                      onTap: () => _form(editing: t),
                      title: Text(payeeCell(t).ifEmpty('—')),
                      subtitle: Text(
                        [
                          t.str('date'),
                          if (_account == null)
                            name(accounts, t.data['account_id']),
                          categoryCell(t),
                          if (t.str('memo').isNotEmpty) t.str('memo'),
                        ].where((p) => p.isNotEmpty).join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (t.data['cleared'] == true)
                            const Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: Icon(Icons.check, size: 16),
                            ),
                          Text(
                            fmt(t.data['amount'] as int),
                            style: TextStyle(
                              color: (t.data['amount'] as int) < 0
                                  ? Theme.of(context).colorScheme.error
                                  : Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Transaction'),
        onPressed: _form,
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _Line {
  String? category;
  final amount = TextEditingController();
}

/// Add or edit a transaction or transfer, in a bottom sheet.
class TxForm extends StatefulWidget {
  const TxForm({super.key, required this.db, this.account, this.editing});
  final Db db;

  /// Account the list is filtered by. Default for a new transaction.
  final String? account;

  /// The transaction to edit. For a transfer, either leg.
  final Entity? editing;

  @override
  State<TxForm> createState() => _TxFormState();
}

class _TxFormState extends State<TxForm> {
  Db get db => widget.db;
  Entity? get _edit => widget.editing;

  bool _transfer = false;
  late DateTime _date;
  String? _account, _to, _category;
  bool _inflow = false, _cleared = false, _split = false;
  final _amount = TextEditingController();
  final _memo = TextEditingController();
  final _payee = TextEditingController();
  final _payeeFocus = FocusNode();
  final _lines = <_Line>[_Line()];
  String _error = '';

  @override
  void initState() {
    super.initState();
    final accounts = db.list('account')..sort(_byName);
    // Default to an on-budget account: that is where most transactions go.
    final first =
        (accounts.where((a) => a.data['on_budget'] != false).firstOrNull ??
                accounts.firstOrNull)
            ?.id;
    _account = widget.account ?? first;
    _to = accounts.where((a) => a.id != _account).firstOrNull?.id;
    _date = DateTime.now();
    final t = _edit;
    if (t == null) return;
    _transfer = isTransfer(t);
    _date = DateTime.parse(t.str('date'));
    _account = t.data['account_id'] as String?;
    _to = t.data['transfer_account_id'] as String?;
    _category = t.data['category_id'] as String?;
    _memo.text = t.str('memo');
    _amount.text = fmt((t.data['amount'] as int).abs());
    _inflow = (t.data['amount'] as int) >= 0;
    _cleared = t.data['cleared'] == true;
    _payee.text =
        db.get('payee', t.data['payee_id'] as String? ?? '')?.str('name') ?? '';
    final lines = splitsOf(t);
    if (lines.isNotEmpty) {
      _split = true;
      _lines
        ..clear()
        ..addAll([
          for (final l in lines)
            _Line()
              ..category = l['category_id'] as String?
              ..amount.text = fmt((l['amount'] as int).abs()),
        ]);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _memo.dispose();
    _payee.dispose();
    _payeeFocus.dispose();
    for (final l in _lines) {
      l.amount.dispose();
    }
    super.dispose();
  }

  /// The outflow side of the transfer. An edited pair keeps its direction.
  String? get _from {
    final t = _edit;
    if (t == null || !_transfer) return _account;
    return (t.data['amount'] as int) < 0
        ? t.data['account_id'] as String?
        : t.data['transfer_account_id'] as String?;
  }

  String? get _dest {
    final t = _edit;
    if (t == null || !_transfer) return _to;
    return (t.data['amount'] as int) < 0
        ? t.data['transfer_account_id'] as String?
        : t.data['account_id'] as String?;
  }

  bool get _needsCategory {
    final f = _from, d = _dest;
    return _transfer &&
        f != null &&
        d != null &&
        transferNeedsCategory(db, f, d);
  }

  int get _lineSum =>
      _lines.fold(0, (s, l) => s + (parseAmount(l.amount.text)?.abs() ?? 0));

  void _fail(String m) => setState(() => _error = m);

  Future<void> _save() async {
    setState(() => _error = '');
    final total = parseAmount(_amount.text);
    if (total == null) return _fail('Enter an amount.');
    final mag = total.abs();
    final memo = _memo.text.trim().isEmpty ? null : _memo.text.trim();
    try {
      final saved = _transfer
          ? await _saveTransfer(mag, memo)
          : await _saveTx(mag, memo);
      if (saved && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _fail(e is CoreException ? e.message : '$e');
    }
  }

  /// Both save methods return false when validation failed and the form stays open.
  Future<bool> _saveTransfer(int mag, String? memo) async {
    // The core checks the accounts, the amount and the category, and words the
    // error. `_save` shows it.
    final category = _category;
    final t = _edit;
    if (t != null) {
      await editTransfer(
        db,
        t,
        date: isoDate(_date),
        amount: mag,
        memo: memo,
        cleared: _cleared,
        categoryId: category,
      );
    } else {
      await addTransfer(
        db,
        date: isoDate(_date),
        from: _from,
        to: _dest,
        amount: mag,
        memo: memo,
        cleared: _cleared,
        categoryId: category,
      );
    }
    return true;
  }

  Future<bool> _saveTx(int mag, String? memo) async {
    final account = _account;
    if (account == null) {
      _fail('Pick an account.');
      return false;
    }
    var splits = <Json>[];
    if (_split) {
      final ms = [for (final l in _lines) parseAmount(l.amount.text)];
      for (var i = 0; i < _lines.length; i++) {
        if (_lines[i].category == null || ms[i] == null || ms[i] == 0) {
          _fail('Every split line needs a category and an amount.');
          return false;
        }
      }
      if (_lineSum != mag) {
        _fail(
          'Split lines add up to ${fmt(_lineSum)}, but the amount is ${fmt(mag)}.',
        );
        return false;
      }
      splits = [
        for (var i = 0; i < _lines.length; i++)
          {
            'category_id': _lines[i].category,
            'amount': _inflow ? ms[i]!.abs() : -ms[i]!.abs(),
          },
      ];
    }

    String? payeeId;
    final name = _payee.text.trim();
    if (name.isNotEmpty) {
      final hit = db
          .list('payee')
          .where((p) => p.str('name').toLowerCase() == name.toLowerCase())
          .firstOrNull;
      payeeId = hit?.id ?? newId();
      if (hit == null) await db.edit('payee', payeeId, {'name': name});
    }
    final fields = <String, dynamic>{
      'account_id': account,
      'date': isoDate(_date),
      'amount': _inflow ? mag : -mag,
      'payee_id': payeeId,
      'category_id': _split ? null : _category,
      'memo': memo,
      'cleared': _cleared,
    };
    final t = _edit;
    if (t == null) {
      await db.edit('transaction', newId(), {
        ...fields,
        if (_split) 'splits': splits,
      });
      return true;
    }
    // Send only what changed, so edits made elsewhere to other fields survive the merge.
    String enc(Object? v) => jsonEncode(v);
    final changed = <String, dynamic>{
      for (final e in fields.entries)
        if (enc(e.value ?? (e.key == 'cleared' ? false : null)) !=
            enc(t.data[e.key] ?? (e.key == 'cleared' ? false : null)))
          e.key: e.value,
    };
    if (enc(splits) != enc(splitsOf(t))) changed['splits'] = splits;
    if (changed.isNotEmpty) await db.edit('transaction', t.id, changed);
    return true;
  }

  Widget _categoryField({
    required String? value,
    required void Function(String?) onChanged,
    required String blank,
    Key? key,
  }) {
    final cats = db.list('category')..sort(_byName);
    return DropdownButtonFormField<String?>(
      key: key,
      // A deleted category is no longer an item; show it as the blank choice.
      initialValue: cats.any((c) => c.id == value) ? value : null,
      decoration: const InputDecoration(labelText: 'Category'),
      items: [
        DropdownMenuItem(value: null, child: Text(blank)),
        for (final c in cats)
          DropdownMenuItem(value: c.id, child: Text(c.str('name'))),
      ],
      onChanged: onChanged,
    );
  }

  Widget _accountField(
    String label,
    String? value,
    void Function(String?) onChanged, {
    bool enabled = true,
    Key? key,
  }) {
    final accounts = db.list('account')..sort(_byName);
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final a in accounts)
          DropdownMenuItem(value: a.id, child: Text(a.str('name'))),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final payees = [for (final p in db.list('payee')) p.str('name')];
    final editing = _edit != null;
    final left = (parseAmount(_amount.text)?.abs() ?? 0) - _lineSum;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!editing)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Transaction')),
                  ButtonSegment(value: true, label: Text('Transfer')),
                ],
                selected: {_transfer},
                onSelectionChanged: (s) => setState(() => _transfer = s.first),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today),
                    label: Text(isoDate(_date)),
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) setState(() => _date = d);
                    },
                  ),
                ),
              ],
            ),
            if (_transfer) ...[
              _accountField(
                'From',
                _from,
                (v) => setState(() => _account = v),
                enabled: !editing,
                key: const Key('from'),
              ),
              _accountField(
                'To',
                _dest,
                (v) => setState(() => _to = v),
                enabled: !editing,
                key: const Key('to'),
              ),
              if (_needsCategory)
                _categoryField(
                  key: const Key('transfer-category'),
                  value: _category,
                  blank: 'Category (required)',
                  onChanged: (v) => _category = v,
                ),
            ] else ...[
              _accountField(
                'Account',
                _account,
                (v) => _account = v,
                key: const Key('account'),
              ),
              Autocomplete<String>(
                textEditingController: _payee,
                focusNode: _payeeFocus,
                optionsBuilder: (v) => payees.where(
                  (p) => p.toLowerCase().contains(v.text.toLowerCase()),
                ),
                fieldViewBuilder: (ctx, c, focus, _) => TextField(
                  controller: c,
                  focusNode: focus,
                  decoration: const InputDecoration(labelText: 'Payee'),
                ),
              ),
              if (!_split)
                _categoryField(
                  key: const Key('category'),
                  value: _category,
                  blank: 'Income (Ready to Assign)',
                  onChanged: (v) => _category = v,
                ),
              SwitchListTile(
                key: const Key('split'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Split'),
                value: _split,
                onChanged: (v) => setState(() => _split = v),
              ),
            ],
            TextField(
              controller: _memo,
              decoration: const InputDecoration(labelText: 'Memo'),
            ),
            TextField(
              controller: _amount,
              key: const Key('amount'),
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Amount'),
            ),
            if (!_transfer)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Inflow'),
                value: _inflow,
                onChanged: (v) => setState(() => _inflow = v),
              ),
            if (!_transfer && _split) ...[
              for (var i = 0; i < _lines.length; i++)
                Row(
                  key: Key('line-$i'),
                  children: [
                    Expanded(
                      child: _categoryField(
                        value: _lines[i].category,
                        blank: 'Category',
                        onChanged: (v) => _lines[i].category = v,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        key: Key('line-amount-$i'),
                        controller: _lines[i].amount,
                        onChanged: (_) => setState(() {}),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Amount'),
                      ),
                    ),
                    if (_lines.length > 1)
                      IconButton(
                        tooltip: 'Remove line',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _lines.removeAt(i).amount.dispose();
                        }),
                      ),
                  ],
                ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() => _lines.add(_Line())),
                    child: const Text('Add split line'),
                  ),
                  const Spacer(),
                  Text('Left to split: ${fmt(left)}', key: const Key('left')),
                ],
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cleared'),
              value: _cleared,
              onChanged: (v) => setState(() => _cleared = v),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error,
                  key: const Key('error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _save,
                child: Text(editing ? 'Save' : 'Add'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:material_ui/material_ui.dart';

import 'library.dart';
import 'trash.dart';

/// A byte count as B, KB, MB or GB.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 || value >= 100 ? 0 : 1)} '
      '${units[unit]}';
}

String _formatDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

enum _ItemAction { select, restore, delete }

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.library});

  final Library library;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late final _trash = Trash(widget.library);
  late List<TrashItem> _items = _trash.items();

  /// The paths of the selected items' folders, or null when not selecting.
  Set<String>? _selection;

  void _reload() => setState(() {
    _items = _trash.items();
    final paths = {for (final i in _items) i.dir.path};
    _selection = _selection?.where(paths.contains).toSet();
    if (_selection?.isEmpty ?? false) _selection = null;
  });

  void _toggle(TrashItem item) => setState(() {
    final selection = _selection ??= {};
    if (!selection.remove(item.dir.path)) selection.add(item.dir.path);
    if (selection.isEmpty) _selection = null;
  });

  List<TrashItem> get _selected => [
    for (final item in _items)
      if (_selection?.contains(item.dir.path) ?? false) item,
  ];

  String _count(int n) => '$n ${n == 1 ? 'item' : 'items'}';

  void _restoreSelected() {
    final items = _selected;
    for (final item in items) {
      _trash.restore(item);
    }
    setState(() => _selection = null);
    _reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Restored ${_count(items.length)}'),
        persist: false,
      ),
    );
  }

  Future<void> _deleteSelected() async {
    final items = _selected;
    final title = 'Permanently delete ${_count(items.length)}?';
    if (!await _confirm(title, 'Delete')) return;
    for (final item in items) {
      _trash.deletePermanently(item);
    }
    setState(() => _selection = null);
    _reload();
  }

  Future<bool> _confirm(String title, String action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _delete(TrashItem item) async {
    if (!await _confirm('Delete ${item.name} permanently?', 'Delete')) return;
    _trash.deletePermanently(item);
    _reload();
  }

  Future<void> _empty() async {
    final count = _items.length;
    final title = 'Permanently delete $count ${count == 1 ? 'item' : 'items'}?';
    if (!await _confirm(title, 'Empty trash')) return;
    _trash.empty();
    _reload();
  }

  void _restore(TrashItem item) {
    _trash.restore(item);
    _reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Restored ${item.name}'), persist: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _items.fold(0, (sum, item) => sum + item.bytes);
    final selection = _selection;
    return PopScope(
      canPop: selection == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selection = null);
      },
      child: Scaffold(
        appBar: selection != null
            ? AppBar(
                leading: IconButton(
                  tooltip: 'Stop selecting',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _selection = null),
                ),
                title: Text('${selection.length} selected'),
                actions: [
                  IconButton(
                    tooltip: 'Select all',
                    icon: const Icon(Icons.select_all),
                    onPressed: () => setState(
                      () => _selection = {for (final i in _items) i.dir.path},
                    ),
                  ),
                  IconButton(
                    tooltip: 'Restore',
                    icon: const Icon(Icons.restore_from_trash_outlined),
                    onPressed: _restoreSelected,
                  ),
                  IconButton(
                    tooltip: 'Delete permanently',
                    icon: const Icon(Icons.delete_forever_outlined),
                    onPressed: _deleteSelected,
                  ),
                ],
              )
            : AppBar(
                title: const Text('Trash'),
                actions: [
                  TextButton(
                    onPressed: _items.isEmpty ? null : _empty,
                    child: const Text('Empty trash'),
                  ),
                ],
              ),
        body: _items.isEmpty
            ? Center(
                child: Text(
                  'Trash is empty',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '${_items.length} ${_items.length == 1 ? 'item' : 'items'}'
                      ', ${formatBytes(total)}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final item in _items)
                    ListTile(
                      selected: selection?.contains(item.dir.path) ?? false,
                      selectedTileColor: theme.colorScheme.secondaryContainer,
                      onTap: selection == null ? null : () => _toggle(item),
                      onLongPress: () => _toggle(item),
                      leading: selection == null
                          ? Icon(
                              item.isFolder
                                  ? Icons.folder_outlined
                                  : Icons.graphic_eq,
                            )
                          : Icon(
                              selection.contains(item.dir.path)
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                            ),
                      title: Text(item.name, maxLines: 2, overflow: .ellipsis),
                      subtitle: Text(
                        [
                          if (item.origin.isNotEmpty) 'from ${item.origin}',
                          _formatDate(item.deletedAt),
                          formatBytes(item.bytes),
                        ].join(', '),
                      ),
                      trailing: selection != null
                          ? null
                          : PopupMenuButton<_ItemAction>(
                              onSelected: (action) => switch (action) {
                                _ItemAction.select => _toggle(item),
                                _ItemAction.restore => _restore(item),
                                _ItemAction.delete => _delete(item),
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: _ItemAction.select,
                                  child: Text('Select multiple'),
                                ),
                                PopupMenuItem(
                                  value: _ItemAction.restore,
                                  child: Text('Restore'),
                                ),
                                PopupMenuItem(
                                  value: _ItemAction.delete,
                                  child: Text('Delete permanently'),
                                ),
                              ],
                            ),
                    ),
                ],
              ),
      ),
    );
  }
}

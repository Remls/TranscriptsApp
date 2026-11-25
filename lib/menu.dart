import 'package:material_ui/material_ui.dart';

/// One item in a [MenuButton]: an icon, a label and what it does. A
/// [destructive] item is in the error color, a [selected] one is tinted.
typedef MenuEntry = ({
  IconData? icon,
  String label,
  VoidCallback onPressed,
  bool destructive,
  bool selected,
});

/// A [MenuEntry] with the usual defaults.
MenuEntry menuEntry(
  IconData? icon,
  String label,
  VoidCallback onPressed, {
  bool destructive = false,
  bool selected = false,
}) => (
  icon: icon,
  label: label,
  onPressed: onPressed,
  destructive: destructive,
  selected: selected,
);

/// A button that opens a menu of [groups], with dividers between them. Shows
/// [child] when given, else a ⋮ icon.
class MenuButton extends StatelessWidget {
  const MenuButton({
    super.key,
    required this.tooltip,
    required this.groups,
    this.child,
    this.onOpen,
    this.onClose,
  });

  final String tooltip;
  final List<List<MenuEntry>> groups;
  final Widget? child;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      onOpen: onOpen,
      onClose: onClose,
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 8),
        ),
      ),
      menuChildren: [
        for (final (i, group) in groups.indexed) ...[
          if (i > 0) const Divider(height: 9, indent: 12, endIndent: 12),
          for (final entry in group)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: MenuItemButton(
                leadingIcon: entry.icon == null
                    ? null
                    : Icon(
                        entry.icon,
                        color: entry.destructive
                            ? scheme.error
                            : entry.selected
                            ? scheme.onSecondaryContainer
                            : null,
                      ),
                trailingIcon: entry.selected ? const Icon(Icons.check) : null,
                style: MenuItemButton.styleFrom(
                  minimumSize: const Size(200, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  foregroundColor: entry.destructive
                      ? scheme.error
                      : entry.selected
                      ? scheme.onSecondaryContainer
                      : null,
                  backgroundColor: entry.selected
                      ? scheme.secondaryContainer
                      : null,
                ),
                onPressed: entry.onPressed,
                child: Text(entry.label),
              ),
            ),
        ],
      ],
      builder: (context, controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        final child = this.child;
        if (child == null) {
          return IconButton(
            tooltip: tooltip,
            onPressed: toggle,
            icon: const Icon(Icons.more_vert),
          );
        }
        return Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: toggle,
            borderRadius: BorderRadius.circular(20),
            child: child,
          ),
        );
      },
    );
  }
}

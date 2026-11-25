import 'package:material_ui/material_ui.dart';

/// Shows a bottom sheet built by [builder], with a drag handle, sized to its
/// content up to most of the screen's height.
Future<T?> showSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: SafeArea(child: builder(context)),
    ),
  );
}

/// A sheet's layout: [title] with a back arrow when [onBack] is set, an
/// optional [header] below it, then [children] in a scrolling list.
class SheetBody extends StatelessWidget {
  const SheetBody({
    super.key,
    this.title,
    this.onBack,
    this.header,
    required this.children,
  });

  final String? title;
  final VoidCallback? onBack;
  final Widget? header;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        if (title != null || onBack != null)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              onBack == null ? 24 : 8,
              0,
              24,
              12,
            ),
            child: Row(
              children: [
                if (onBack != null) ...[
                  IconButton(
                    tooltip: 'Back',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    title ?? '',
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: header,
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: children,
          ),
        ),
      ],
    );
  }
}

/// One row of a sheet: an option to pick or an action to take. A [selected]
/// row is tinted and ticked. A [destructive] row is in the error color.
class SheetOption extends StatelessWidget {
  const SheetOption({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.destructive = false,
    this.trailing,
    this.onTap,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool selected;
  final bool destructive;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = destructive
        ? scheme.error
        : selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: .antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  if (leading != null) ...[
                    IconTheme.merge(
                      data: IconThemeData(
                        color: destructive
                            ? scheme.error
                            : selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                      child: leading!,
                    ),
                    const SizedBox(width: 16),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: .min,
                      crossAxisAlignment: .start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: foreground,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: selected
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null)
                    trailing!
                  else if (selected)
                    Icon(Icons.check, color: scheme.onSecondaryContainer),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A divider between groups of [SheetOption]s.
class SheetDivider extends StatelessWidget {
  const SheetDivider({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Divider(height: 1),
  );
}

/// A button that shows [label] and opens a picker, with a drop-down arrow.
class PickerButton extends StatelessWidget {
  const PickerButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Row(
        mainAxisSize: .min,
        children: [
          Flexible(child: Text(label, overflow: .ellipsis)),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

/// A labelled round button for a sheet's main actions, laid out in a row.
class SheetAction extends StatelessWidget {
  const SheetAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: .min,
          children: [
            Container(
              width: 56,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, color: theme.colorScheme.onSecondaryContainer),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: .center,
              maxLines: 2,
              style: theme.textTheme.labelMedium,
            ),
          ],
        ),
      ),
    );
  }
}

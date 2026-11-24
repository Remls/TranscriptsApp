import 'package:material_ui/material_ui.dart';

/// Calls [onSwipeBack] once when the user drags [child]'s horizontal page
/// view further right than its first page, by at least [distance].
class SwipeBack extends StatefulWidget {
  const SwipeBack({
    super.key,
    required this.onSwipeBack,
    required this.child,
    this.distance = 64,
  });

  final VoidCallback onSwipeBack;
  final double distance;
  final Widget child;

  @override
  State<SwipeBack> createState() => _SwipeBackState();
}

class _SwipeBackState extends State<SwipeBack> {
  double _pulled = 0;
  bool _done = false;

  bool _onNotification(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.horizontal) return false;
    if (n is ScrollStartNotification) {
      _pulled = 0;
      _done = false;
    } else if (n is OverscrollNotification &&
        n.dragDetails != null &&
        n.overscroll < 0 &&
        n.metrics.pixels <= n.metrics.minScrollExtent) {
      _pulled -= n.overscroll;
      if (!_done && _pulled >= widget.distance) {
        _done = true;
        widget.onSwipeBack();
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: widget.child,
    );
  }
}

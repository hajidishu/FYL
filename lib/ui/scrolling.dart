import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Limit a single wheel event, including drivers configured to scroll a page.
double launcherWheelDelta(double delta, double viewport) {
  if (!delta.isFinite || !viewport.isFinite) return 0;
  final limit = math.min(96.0, math.max(1.0, viewport * .2));
  return (delta * .6).clamp(-limit, limit);
}

class LauncherScrollController extends ScrollController {
  LauncherScrollController({super.initialScrollOffset, super.keepScrollOffset});

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => LauncherScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
  );
}

class LauncherScrollPosition extends ScrollPositionWithSingleContext {
  bool mouseWheel = true;
  LauncherScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
  });

  @override
  void pointerScroll(double delta) => super.pointerScroll(
    mouseWheel && hasContentDimensions
        ? launcherWheelDelta(delta, viewportDimension)
        : delta,
  );
}

class _ScrollArea extends StatefulWidget {
  final ScrollController? controller;
  final Widget Function(ScrollController) builder;
  const _ScrollArea({this.controller, required this.builder});
  @override
  State<_ScrollArea> createState() => _ScrollAreaState();
}

class _ScrollAreaState extends State<_ScrollArea> {
  final controller = LauncherScrollController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effective = widget.controller ?? controller;
    return Listener(
      // Scrollable resolves the event after bubbling, so this flag is available
      // before pointerScroll runs. The innermost scrollable still owns the event.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          for (final position in effective.positions) {
            if (position is LauncherScrollPosition) {
              position.mouseWheel = event.kind == PointerDeviceKind.mouse;
            }
          }
        }
      },
      child: widget.builder(effective),
    );
  }
}

class AppScrollView extends StatelessWidget {
  final Widget child;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;
  final Axis scrollDirection;
  final bool reverse;
  final bool primary;
  const AppScrollView({
    required this.child,
    this.controller,
    this.padding,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.primary = false,
    super.key,
  }) : assert(!primary);

  @override
  Widget build(BuildContext context) => _ScrollArea(
    controller: controller,
    builder: (controller) => SingleChildScrollView(
      controller: controller,
      padding: padding,
      scrollDirection: scrollDirection,
      reverse: reverse,
      primary: false,
      child: child,
    ),
  );
}

class AppSliverView extends StatelessWidget {
  final List<Widget> slivers;
  final ScrollController? controller;
  final bool reverse;
  const AppSliverView({
    required this.slivers,
    this.controller,
    this.reverse = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) => _ScrollArea(
    controller: controller,
    builder: (controller) => CustomScrollView(
      controller: controller,
      primary: false,
      reverse: reverse,
      slivers: slivers,
    ),
  );
}

class AppListView extends StatelessWidget {
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;
  final bool reverse, shrinkWrap;
  final List<Widget>? children;
  final IndexedWidgetBuilder? itemBuilder, separatorBuilder;
  final int? itemCount;
  const AppListView({
    required this.children,
    this.controller,
    this.padding,
    this.reverse = false,
    this.shrinkWrap = false,
    super.key,
  }) : itemBuilder = null,
       separatorBuilder = null,
       itemCount = null;

  const AppListView.builder({
    required this.itemBuilder,
    required this.itemCount,
    this.controller,
    this.padding,
    this.reverse = false,
    this.shrinkWrap = false,
    super.key,
  }) : children = null,
       separatorBuilder = null;

  const AppListView.separated({
    required this.itemBuilder,
    required this.separatorBuilder,
    required this.itemCount,
    this.controller,
    this.padding,
    this.reverse = false,
    this.shrinkWrap = false,
    bool primary = false,
    super.key,
  }) : assert(!primary),
       children = null;

  @override
  Widget build(BuildContext context) => _ScrollArea(
    controller: controller,
    builder: (controller) {
      if (children != null) {
        return ListView(
          controller: controller,
          primary: false,
          padding: padding,
          reverse: reverse,
          shrinkWrap: shrinkWrap,
          children: children!,
        );
      }
      if (separatorBuilder != null) {
        return ListView.separated(
          controller: controller,
          primary: false,
          padding: padding,
          reverse: reverse,
          shrinkWrap: shrinkWrap,
          itemCount: itemCount!,
          itemBuilder: itemBuilder!,
          separatorBuilder: separatorBuilder!,
        );
      }
      return ListView.builder(
        controller: controller,
        primary: false,
        padding: padding,
        reverse: reverse,
        shrinkWrap: shrinkWrap,
        itemCount: itemCount,
        itemBuilder: itemBuilder!,
      );
    },
  );
}

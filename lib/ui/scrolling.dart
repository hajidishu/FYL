import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

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
  double? _wheelTarget;
  LauncherScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
  });

  @override
  void beginActivity(ScrollActivity? newActivity) {
    // A drag, scrollbar jump or keyboard action cancels queued wheel movement.
    if (newActivity != null) _wheelTarget = null;
    super.beginActivity(newActivity);
  }

  @override
  void pointerScroll(double delta) {
    if (!mouseWheel || !hasContentDimensions || delta == 0) {
      super.pointerScroll(delta);
      return;
    }
    final step = launcherWheelDelta(delta, viewportDimension);
    if (MediaQuery.maybeDisableAnimationsOf(context.storageContext) ?? false) {
      super.pointerScroll(step);
      return;
    }
    final pending = _wheelTarget;
    final continuing =
        activity is _WheelScrollActivity &&
        pending != null &&
        (pending - pixels) * step > 0;
    final base = continuing ? pending : pixels;
    // Keep rapid wheel events responsive without building up a long backlog.
    final limit = math.min(240.0, viewportDimension * .6);
    final target = (base + step)
        .clamp(pixels - limit, pixels + limit)
        .clamp(minScrollExtent, maxScrollExtent);
    if ((target - pixels).abs() < physics.toleranceFor(this).distance) {
      super.pointerScroll(target - pixels);
      return;
    }
    updateUserScrollDirection(
      step > 0 ? ScrollDirection.reverse : ScrollDirection.forward,
    );
    beginActivity(
      _WheelScrollActivity(
        this,
        from: pixels,
        to: target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        vsync: context.vsync,
      ),
    );
    _wheelTarget = target;
  }
}

class _WheelScrollActivity extends DrivenScrollActivity {
  _WheelScrollActivity(
    super.delegate, {
    required super.from,
    required super.to,
    required super.duration,
    required super.curve,
    required super.vsync,
  });

  // Buttons, selection and nested lists remain usable during wheel animation.
  @override
  bool get shouldIgnorePointer => false;
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

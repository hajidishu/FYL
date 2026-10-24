import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/ui/scrolling.dart';

void main() {
  Future<void> wheel(
    WidgetTester tester,
    Finder target,
    double delta, {
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) => tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(target),
      scrollDelta: Offset(0, delta),
      kind: kind,
    ),
  );

  Widget harness(Widget child) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 500, height: 300, child: child),
      ),
    ),
  );

  for (final type in ['form', 'list', 'slivers']) {
    testWidgets('large mouse-wheel events stay bounded in $type views', (
      tester,
    ) async {
      final controller = LauncherScrollController();
      addTearDown(controller.dispose);
      final content = switch (type) {
        'form' => AppScrollView(
          controller: controller,
          child: const SizedBox(height: 5000, width: 500),
        ),
        'list' => AppListView.builder(
          controller: controller,
          itemCount: 100,
          itemBuilder: (_, _) => const SizedBox(height: 50),
        ),
        _ => AppSliverView(
          controller: controller,
          slivers: const [SliverToBoxAdapter(child: SizedBox(height: 5000))],
        ),
      };
      await tester.pumpWidget(harness(content));
      await wheel(tester, find.byType(Scrollable), 12000);
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(controller.offset, lessThan(100));
      expect(controller.offset, lessThan(controller.position.maxScrollExtent));
      await wheel(tester, find.byType(Scrollable), -12000);
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'trackpad signals and scrollbar-style jumps retain direct movement',
    (tester) async {
      final controller = LauncherScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        harness(
          AppScrollView(
            controller: controller,
            child: const SizedBox(height: 5000),
          ),
        ),
      );
      await wheel(
        tester,
        find.byType(Scrollable),
        180,
        kind: PointerDeviceKind.trackpad,
      );
      expect(controller.offset, 180);
      controller.jumpTo(750);
      expect(controller.offset, 750);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('nested lists consume their own wheel events before the page', (
    tester,
  ) async {
    final outer = LauncherScrollController(),
        inner = LauncherScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    await tester.pumpWidget(
      harness(
        AppScrollView(
          controller: outer,
          child: Column(
            children: [
              SizedBox(
                height: 180,
                child: AppListView.builder(
                  key: const ValueKey('inner-list'),
                  controller: inner,
                  itemCount: 100,
                  itemBuilder: (_, _) => const SizedBox(height: 40),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await wheel(tester, find.byKey(const ValueKey('inner-list')), 1200);
    await tester.pumpAndSettle();
    expect(inner.offset, greaterThan(0));
    expect(outer.offset, 0);
    inner.jumpTo(inner.position.maxScrollExtent);
    await tester.pump();
    await wheel(tester, find.byKey(const ValueKey('inner-list')), 1200);
    await tester.pumpAndSettle();
    expect(outer.offset, greaterThan(0));
    expect(inner.offset, inner.position.maxScrollExtent);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reversed log lists scroll in the native wheel direction', (
    tester,
  ) async {
    final controller = LauncherScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      harness(
        AppListView.builder(
          controller: controller,
          reverse: true,
          itemCount: 200,
          itemBuilder: (_, _) => const SizedBox(height: 30),
        ),
      ),
    );
    await wheel(tester, find.byType(Scrollable), -1200);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(100));
    await wheel(tester, find.byType(Scrollable), 1200);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

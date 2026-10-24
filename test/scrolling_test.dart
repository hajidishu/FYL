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

  testWidgets(
    'wheel movement has intermediate frames and merges rapid events',
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
      await wheel(tester, find.byType(Scrollable), 1200);
      expect(controller.offset, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(controller.offset, greaterThan(0));
      expect(controller.offset, lessThan(60));
      for (var i = 0; i < 10; i++) {
        await wheel(tester, find.byType(Scrollable), 1200);
      }
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(60));
      expect(controller.offset, lessThan(300));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reversing the wheel and dragging the scrollbar interrupt animation',
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
      controller.jumpTo(500);
      await wheel(tester, find.byType(Scrollable), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final before = controller.offset;
      await wheel(tester, find.byType(Scrollable), -1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(controller.offset, lessThan(before));
      controller.jumpTo(800);
      await tester.pumpAndSettle();
      expect(controller.offset, 800);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('wheel animation leaves buttons clickable', (tester) async {
    final controller = LauncherScrollController();
    addTearDown(controller.dispose);
    var taps = 0;
    await tester.pumpWidget(
      harness(
        AppScrollView(
          controller: controller,
          child: Column(
            children: [
              GestureDetector(
                key: const ValueKey('scroll-button'),
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(width: 300, height: 100),
              ),
              const SizedBox(height: 5000),
            ],
          ),
        ),
      ),
    );
    await wheel(tester, find.byType(Scrollable), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byKey(const ValueKey('scroll-button')));
    await tester.pumpAndSettle();
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reduced motion skips animation while keeping wheel movement bounded',
    (tester) async {
      final controller = LauncherScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        harness(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: AppScrollView(
              controller: controller,
              child: const SizedBox(height: 5000),
            ),
          ),
        ),
      );
      await wheel(tester, find.byType(Scrollable), 12000);
      expect(controller.offset, greaterThan(0));
      expect(controller.offset, lessThan(100));
      final stopped = controller.offset;
      await tester.pumpAndSettle();
      expect(controller.offset, stopped);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

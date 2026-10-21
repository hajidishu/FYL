import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/ui/theme.dart';

Widget harness(bool dark, Widget child) => MaterialApp(
  theme: LauncherColors(dark).material,
  home: FTheme(
    data: LauncherColors(dark).forui,
    child: Scaffold(body: child),
  ),
);

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'long dropdowns fit the viewport and close with Escape (dark=$dark)',
      (tester) async {
        tester.view.physicalSize = const Size(400, 320);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var value = 0;
        await tester.pumpWidget(
          harness(
            dark,
            StatefulBuilder(
              builder: (context, setState) => Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: 280,
                    child: SelectBox<int>(
                      compact: true,
                      value: value,
                      items: {for (var i = 0; i < 80; i++) i: 'Choice $i'},
                      onChanged: (selected) => setState(() => value = selected),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(SelectBox<int>));
        await tester.pumpAndSettle();
        final scrollable = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        );
        await tester.scrollUntilVisible(
          find.text('Choice 79'),
          160,
          scrollable: scrollable,
        );
        await tester.tap(find.text('Choice 79'));
        await tester.pumpAndSettle();
        expect(value, 79);
        await tester.tap(find.byType(SelectBox<int>));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Choice 78'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'duplicate labels retain distinct values and follow parent changes',
    (tester) async {
      var value = 'first';
      late StateSetter update;
      await tester.pumpWidget(
        harness(
          false,
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Center(
                child: SizedBox(
                  width: 280,
                  child: SelectBox<String>(
                    value: value,
                    items: const {
                      'first': 'Java 21',
                      'second': 'Java 21',
                      'auto': '自动选择',
                    },
                    onChanged: (selected) => setState(() => value = selected),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SelectBox<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Java 21').last);
      await tester.pumpAndSettle();
      expect(value, 'second');
      update(() => value = 'auto');
      await tester.pumpAndSettle();
      expect(find.text('自动选择'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

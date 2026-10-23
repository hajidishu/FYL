import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/launch_progress.dart';
import 'package:free_your_launcher/ui/launch_loading_card.dart';
import 'package:free_your_launcher/ui/theme.dart';

void main() {
  for (final dark in [true, false]) {
    testWidgets(
      'chunk animation fits a narrow card and enlarged text, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var stopped = false;
        final colors = LauncherColors(dark);
        await tester.pumpWidget(
          MaterialApp(
            theme: colors.material,
            home: FTheme(
              data: colors.forui,
              child: Scaffold(
                body: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: const TextScaler.linear(1.4)),
                    child: Center(
                      child: SizedBox(
                        width: 320,
                        child: LaunchLoadingCard(
                          instanceName:
                              'A very long Minecraft modpack version name',
                          progress: const LaunchProgress(LaunchPhase.window),
                          onStopWaiting: () => stopped = true,
                          tip: Future.value(
                            'An editable launch tip that remains readable when the window is narrow and the user enlarges the interface text.',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 1200));
        expect(find.text('等待游戏窗口'), findsOneWidget);
        expect(find.byType(ChunkGenerationAnimation), findsOneWidget);
        expect(find.byKey(const ValueKey('launch-tip')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('stop-waiting-for-window')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(stopped, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

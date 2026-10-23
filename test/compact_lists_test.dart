import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/ui/community_page.dart';
import 'package:free_your_launcher/ui/game_versions.dart';
import 'package:free_your_launcher/ui/theme.dart';

class CompactCatalog extends CommunityCatalog {
  CompactCatalog(super.settings);
  static const summary =
      'A detailed project description that stays readable while the remaining text is available on hover and in the project details.';
  @override
  Future<ContentSearchResult> search({
    required ContentKind kind,
    String query = '',
    String minecraft = '',
    String? loader,
    ContentSource? source,
    int page = 0,
    bool newest = false,
    CancellationToken? token,
  }) async => ContentSearchResult([
    for (var i = 0; i < 12; i++)
      ContentProject(
        source: ContentSource.modrinth,
        kind: kind,
        id: '$i',
        slug: '$i',
        name: 'Project $i',
        summary: summary,
        categories: const [
          'adventure',
          'lightweight',
          'multiplayer',
          'technology',
        ],
        author: 'Example author',
        website: 'https://modrinth.com',
        gameVersions: const ['1.21.1', '1.20.1', '1.19.4'],
        loaders: const ['fabric', 'neoforge', 'quilt'],
        downloads: 251234567,
        updated: DateTime.now().subtract(const Duration(days: 7)),
      ),
  ]);
}

void main() {
  late LauncherController controller;
  setUp(() {
    controller = LauncherController(
      supportDirectory: Directory.systemTemp.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    controller.instances.add(
      GameInstance(
        id: 'target',
        name: 'Target',
        version: '1.21.1',
        root: Directory.systemTemp.path,
        isolated: true,
        javaMajor: 21,
        components: 'Fabric 0.16.10',
      ),
    );
  });
  tearDown(() => controller.dispose());
  Future<void> show(
    WidgetTester tester,
    Widget child, {
    double top = 319,
  }) async {
    tester.view.physicalSize = const Size(1158, 762);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: const LauncherColors(true).material,
        home: FTheme(
          data: const LauncherColors(true).forui,
          child: Scaffold(
            body: Padding(
              padding: EdgeInsets.fromLTRB(242, top, 26, 25),
              child: child,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<Rect> alignFirst(WidgetTester tester, Finder first) async {
    await tester.scrollUntilVisible(
      first,
      120,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(first);
    await tester.pumpAndSettle();
    return tester.getRect(find.byType(CustomScrollView));
  }

  for (final kind in ContentKind.values) {
    testWidgets(
      'six ${kind.name} rows fit the reference viewport with readable descriptions',
      (tester) async {
        final catalog = CompactCatalog(controller.settings.copy());
        await show(
          tester,
          CommunityPage(
            controller: controller,
            kind: kind,
            catalog: catalog,
            onTaskStarted: () {},
            onOpenSettings: () {},
          ),
        );
        final viewport = await alignFirst(
          tester,
          find.byKey(const ValueKey('community-project-modrinth-0')),
        );
        for (var i = 0; i < 6; i++) {
          final row = find.byKey(ValueKey('community-project-modrinth-$i'));
          final bounds = tester.getRect(row);
          expect(bounds.top, greaterThanOrEqualTo(viewport.top - .5));
          expect(
            bounds.bottom,
            lessThanOrEqualTo(viewport.bottom + .5),
            reason:
                'Six complete rows should fit without reducing description text size',
          );
          final description = find.descendant(
            of: row,
            matching: find.text(CompactCatalog.summary),
          );
          expect(tester.widget<Text>(description).style?.fontSize, 14);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('six game version rows fit the reference viewport', (
    tester,
  ) async {
    for (var i = 0; i < 12; i++) {
      controller.versions.add(
        MinecraftVersion.fromJson({
          'id': '1.21.$i',
          'type': 'release',
          'url': 'https://example.invalid/version',
          'releaseTime': '2024-08-01T00:00:00Z',
        }),
      );
    }
    await show(
      tester,
      GameVersionList(controller: controller, onInstall: (_) {}),
      top: 254,
    );
    await tester.enterText(find.byType(EditableText).first, '1.21.');
    await tester.pumpAndSettle();
    final viewport = await alignFirst(
      tester,
      find.byKey(const ValueKey('game-version-card-1.21.0')),
    );
    for (var i = 0; i < 6; i++) {
      final bounds = tester.getRect(
        find.byKey(ValueKey('game-version-card-1.21.$i')),
      );
      expect(bounds.top, greaterThanOrEqualTo(viewport.top - .5));
      expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom + .5));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

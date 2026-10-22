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
import 'package:free_your_launcher/ui/theme.dart';

class SearchFixtureNetwork extends OfficialNetwork {
  SearchFixtureNetwork(super.settings) : super(community: true);

  int calls = 0;
  bool failFirstSearch = false;

  @override
  Future<dynamic> jsonValue(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async {
    calls++;
    if (failFirstSearch && calls <= 2) {
      throw const HttpException('fixture network failure');
    }
    if (url.startsWith('https://api.modrinth.com/')) {
      return {'hits': <Json>[], 'total_hits': 0};
    }
    return {
      'data': <Json>[],
      'pagination': {'totalCount': 0},
    };
  }
}

class PagingFixtureCatalog extends CommunityCatalog {
  PagingFixtureCatalog(super.settings);

  final requestedPages = <int>[];
  var pageOneAttempts = 0;

  static const first = ContentProject(
    source: ContentSource.modrinth,
    kind: ContentKind.mod,
    id: 'first',
    slug: 'first',
    name: 'First project',
    summary: 'First page result',
    author: 'Fixture',
    website: 'https://modrinth.com/mod/first',
  );
  static const second = ContentProject(
    source: ContentSource.modrinth,
    kind: ContentKind.mod,
    id: 'second',
    slug: 'second',
    name: 'Second project',
    summary: 'Second page result',
    author: 'Fixture',
    website: 'https://modrinth.com/mod/second',
  );

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
  }) async {
    requestedPages.add(page);
    if (page == 0) return const ContentSearchResult([first], hasMore: true);
    pageOneAttempts++;
    if (pageOneAttempts == 1) {
      return const ContentSearchResult(
        [],
        failed: true,
        notices: ['Modrinth：fixture page failure'],
      );
    }
    return const ContentSearchResult([second]);
  }
}

void main() {
  late Directory temporary;
  late LauncherController controller;
  late SearchFixtureNetwork network;
  late CommunityCatalog catalog;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-luna-ui-');
    controller = LauncherController(
      supportDirectory: temporary.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    final settings = controller.settings.copy()
      ..curseforgeApiKey = 'fixture-key';
    network = SearchFixtureNetwork(settings)..failFirstSearch = true;
    catalog = CommunityCatalog(settings, network: network);
  });

  tearDown(() async {
    catalog.close();
    controller.dispose();
    await temporary.delete(recursive: true);
  });

  testWidgets(
    'all community sources failing offers retry and clears on success',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: const LauncherColors(false).material,
          home: FTheme(
            data: const LauncherColors(false).forui,
            child: Scaffold(
              body: CommunityPage(
                controller: controller,
                kind: ContentKind.mod,
                catalog: catalog,
                onTaskStarted: () {},
                onOpenSettings: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('社区搜索失败'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('retry-community-search')),
        findsOneWidget,
      );
      expect(find.textContaining('fixture network failure'), findsOneWidget);
      expect(find.text('没有找到匹配的项目'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('retry-community-search')));
      await tester.pumpAndSettle();

      expect(network.calls, 4);
      expect(find.text('社区搜索失败'), findsNothing);
      expect(find.text('没有找到匹配的项目'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retrying a failed next page requests the same page and keeps prior results',
    (tester) async {
      final pagingCatalog = PagingFixtureCatalog(controller.settings.copy());
      addTearDown(pagingCatalog.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: const LauncherColors(false).material,
          home: FTheme(
            data: const LauncherColors(false).forui,
            child: Scaffold(
              body: CommunityPage(
                controller: controller,
                kind: ContentKind.mod,
                catalog: pagingCatalog,
                onTaskStarted: () {},
                onOpenSettings: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('First project'), findsOneWidget);

      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(pagingCatalog.requestedPages, [0, 1]);
      expect(find.text('First project'), findsOneWidget);
      expect(find.text('重试加载'), findsOneWidget);

      await tester.tap(find.text('重试加载'));
      await tester.pumpAndSettle();
      expect(pagingCatalog.requestedPages, [0, 1, 1]);
      expect(find.text('First project'), findsOneWidget);
      expect(find.text('Second project'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'a failed optional source does not turn a successful empty search into an error',
    () async {
      final settings = controller.settings.copy()..curseforgeApiKey = '';
      final partialNetwork = SearchFixtureNetwork(settings);
      final partialCatalog = CommunityCatalog(
        settings,
        network: partialNetwork,
      );
      addTearDown(() {
        partialCatalog.close();
      });

      final result = await partialCatalog.search(kind: ContentKind.mod);

      expect(result.projects, isEmpty);
      expect(result.notices, isNotEmpty);
      expect(result.failed, isFalse);
    },
  );
}

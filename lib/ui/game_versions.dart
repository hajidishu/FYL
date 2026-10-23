import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import '../core/controller.dart';
import '../core/models.dart';
import '../core/version_groups.dart';
import 'version_group_icon.dart';
import 'theme.dart';

class GameVersionList extends StatefulWidget {
  final LauncherController controller;
  final ValueChanged<MinecraftVersion> onInstall;
  const GameVersionList({
    required this.controller,
    required this.onInstall,
    super.key,
  });
  @override
  State<GameVersionList> createState() => _GameVersionListState();
}

class _GameVersionListState extends State<GameVersionList> {
  String query = '';
  late final opened = <MinecraftVersionGroup>{
    if (widget.controller.settings.showSnapshots) MinecraftVersionGroup.preview,
    if (widget.controller.settings.showHistorical)
      MinecraftVersionGroup.historical,
  };

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final controller = widget.controller;
    final all = controller.versions;
    final needle = query.trim().toLowerCase();
    final filtered = all
        .where((v) => v.id.toLowerCase().contains(needle))
        .toList();
    MinecraftVersion? latest(MinecraftVersionGroup group, String? id) =>
        all.where((v) => v.group == group && v.id == id).firstOrNull ??
        all.where((v) => v.group == group).firstOrNull;
    final release = latest(
      MinecraftVersionGroup.release,
      controller.latestRelease,
    );
    final preview = latest(
      MinecraftVersionGroup.preview,
      controller.latestSnapshot,
    );
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: AppInput(
                hint: '搜索版本，例如 1.21.1',
                onChanged: (v) => setState(() => query = v),
              ),
            ),
            const SizedBox(width: 12),
            AppButton(
              '刷新',
              icon: FIcons.refreshCw,
              secondary: true,
              onPressed: controller.loadingVersions
                  ? null
                  : controller.refreshVersions,
            ),
          ],
        ),
        const SizedBox(height: 15),
        Expanded(
          child: controller.loadingVersions && all.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
              ? Center(
                  child: Text(
                    all.isEmpty ? '暂时没有版本列表，请点击刷新。' : '没有找到匹配的版本',
                    style: TextStyle(color: c.muted),
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    if (needle.isEmpty && (release != null || preview != null))
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Surface(
                            key: const ValueKey('latest-version-panel'),
                            padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(14, 0, 14, 6),
                                  child: Text(
                                    '最新版本',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (release != null && preview != null)
                                  LayoutBuilder(
                                    builder: (_, constraints) =>
                                        constraints.maxWidth >= 760
                                        ? IntrinsicHeight(
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Expanded(
                                                  child: _versionRow(
                                                    release,
                                                    release,
                                                    preview,
                                                  ),
                                                ),
                                                Expanded(
                                                  child: _versionRow(
                                                    preview,
                                                    release,
                                                    preview,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          )
                                        : Column(
                                            children: [
                                              _versionRow(
                                                release,
                                                release,
                                                preview,
                                              ),
                                              _versionRow(
                                                preview,
                                                release,
                                                preview,
                                              ),
                                            ],
                                          ),
                                  )
                                else if (release != null)
                                  _versionRow(release, release, preview)
                                else if (preview != null)
                                  _versionRow(preview, release, preview),
                              ],
                            ),
                          ),
                        ),
                      ),
                    for (final group in MinecraftVersionGroup.values)
                      ..._group(group, filtered, release, preview),
                  ],
                ),
        ),
      ],
    );
  }

  List<Widget> _group(
    MinecraftVersionGroup group,
    List<MinecraftVersion> versions,
    MinecraftVersion? release,
    MinecraftVersion? preview,
  ) {
    final items = versions.where((v) => v.group == group).toList();
    if (query.trim().isNotEmpty && items.isEmpty) return [];
    final expanded = query.trim().isNotEmpty || opened.contains(group);
    final c = LauncherColors.of(context);
    return [
      SliverPadding(
        padding: const EdgeInsets.only(bottom: 10),
        sliver: DecoratedSliver(
          key: ValueKey('version-panel-${group.name}'),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border.withValues(alpha: .65)),
            borderRadius: BorderRadius.circular(14),
          ),
          sliver: SliverPadding(
            padding: const EdgeInsets.all(1),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      key: ValueKey('version-group-${group.name}'),
                      borderRadius: BorderRadius.vertical(
                        top: const Radius.circular(13),
                        bottom: Radius.circular(expanded ? 0 : 13),
                      ),
                      onTap: items.isEmpty
                          ? null
                          : () => setState(() {
                              if (!opened.remove(group)) opened.add(group);
                            }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            VersionGroupIcon(group, size: 24),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${group.label} (${items.length})',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              expanded ? FIcons.chevronUp : FIcons.chevronDown,
                              size: 16,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (expanded)
                  SliverPadding(
                    padding: const EdgeInsets.only(bottom: 6),
                    sliver: SliverList.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) =>
                          _versionRow(items[i], release, preview),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  Widget _versionRow(
    MinecraftVersion version,
    MinecraftVersion? release,
    MinecraftVersion? preview,
  ) {
    final c = LauncherColors.of(context);
    final installed = widget.controller.instances.any(
      (i) => i.version == version.id,
    );
    return Padding(
      key: ValueKey('game-version-card-${version.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: c.raised,
              borderRadius: BorderRadius.circular(8),
            ),
            child: VersionGroupIcon(version.group),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      version.id,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (version.id == release?.id)
                      const Tag('最新正式版', accent: true, compact: true),
                    if (version.id == preview?.id)
                      const Tag('最新预览版', accent: true, compact: true),
                    if (installed) const Tag('已安装', compact: true),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${version.group.label} · ${version.released.toLocal().toIso8601String().substring(0, 10)}',
                  style: TextStyle(color: c.muted, fontSize: 12, height: 1.25),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppButton(
            installed ? '再次安装' : '安装',
            key: ValueKey('install-version-${version.id}'),
            icon: FIcons.download,
            secondary: true,
            small: true,
            onPressed: widget.controller.installing
                ? null
                : () => widget.onInstall(version),
          ),
        ],
      ),
    );
  }
}

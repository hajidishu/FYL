import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../core/community_models.dart';
import '../core/mod_catalog.dart' show compareComponentVersions;
import 'theme.dart';

String formatContentDownloads(int count) {
  if (count < 10000) return '$count';
  var unit = count >= 100000000 ? '亿' : '万';
  var value = (count / (unit == '亿' ? 100000000 : 10000)).toStringAsFixed(2);
  if (unit == '万' && value == '10000.00') {
    unit = '亿';
    value = '1.00';
  }
  return '${value.replaceFirst(RegExp(r'\.?0+$'), '')} $unit';
}

String formatContentAge(DateTime? value, {DateTime? now}) {
  if (value == null) return '更新时间未知';
  final elapsed = (now ?? DateTime.now()).difference(value);
  if (elapsed.inMinutes < 1) return '刚刚更新';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} 分钟前更新';
  if (elapsed.inDays < 1) return '${elapsed.inHours} 小时前更新';
  if (elapsed.inDays < 30) return '${elapsed.inDays} 天前更新';
  if (elapsed.inDays < 365) return '${elapsed.inDays ~/ 30} 个月前更新';
  return '${elapsed.inDays ~/ 365} 年前更新';
}

final _releaseVersion = RegExp(r'^\d+\.\d+(?:\.\d+)?$');

List<String> sortedContentGameVersions(Iterable<String> values) =>
    values
        .map((value) => value.trim())
        .where((value) => _releaseVersion.hasMatch(value))
        .toSet()
        .toList()
      ..sort((a, b) => compareComponentVersions(b, a));

String contentGameVersionRanges(
  Iterable<String> values, {
  Iterable<String> releases = const [],
}) {
  final versions = sortedContentGameVersions(values);
  if (versions.isEmpty) return '';
  final official = sortedContentGameVersions(releases);
  final positions = {for (var i = 0; i < official.length; i++) official[i]: i};
  bool adjacent(String newer, String older) {
    final newerPosition = positions[newer];
    final olderPosition = positions[older];
    if (newerPosition != null && olderPosition != null) {
      return olderPosition == newerPosition + 1;
    }
    // Without the manifest, only consecutive patches can be proven adjacent.
    final first = newer.split('.').map(int.parse).toList();
    final second = older.split('.').map(int.parse).toList();
    return first[0] == second[0] &&
        first[1] == second[1] &&
        (first.length == 3 ? first[2] : 0) ==
            (second.length == 3 ? second[2] : 0) + 1;
  }

  final ranges = <String>[];
  var newest = versions.first;
  var oldest = newest;
  void finishRange() =>
      ranges.add(newest == oldest ? newest : '$newest~$oldest');
  for (final version in versions.skip(1)) {
    if (!adjacent(oldest, version)) {
      finishRange();
      newest = version;
    }
    oldest = version;
  }
  finishRange();
  return ranges.join(',');
}

String formatContentGameVersions(
  Iterable<String> values, {
  Iterable<String> releases = const [],
}) {
  final ranges = contentGameVersionRanges(values, releases: releases);
  return ranges.isEmpty ? '暂无正式版支持信息' : 'Minecraft $ranges';
}

class SupportedContentVersions extends StatelessWidget {
  final List<String> gameVersions, loaders;
  final Iterable<String> releases;
  final bool compact;
  const SupportedContentVersions({
    required this.gameVersions,
    required this.loaders,
    this.releases = const [],
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    const names = {
      'fabric': 'Fabric',
      'forge': 'Forge',
      'neoforge': 'NeoForge',
      'quilt': 'Quilt',
      'iris': 'Iris',
      'optifine': 'OptiFine',
      'datapack': '数据包',
      'minecraft': '原版',
    };
    final loaderText = loaders
        .map((value) => names[value.toLowerCase()] ?? value)
        .toSet()
        .join(' / ');
    final ranges = contentGameVersionRanges(gameVersions, releases: releases);
    final supported = ranges.isEmpty ? '暂无正式版支持信息' : 'Minecraft $ranges';
    return Tooltip(
      message: ranges.isEmpty ? supported : '支持的 Minecraft 版本：$ranges',
      constraints: const BoxConstraints(maxWidth: 480),
      child: Text(
        '${loaderText.isEmpty ? '' : '$loaderText · '}$supported',
        maxLines: compact ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: LauncherColors.of(context).secondaryText,
          fontSize: 12,
          height: compact ? 1.25 : 1.5,
        ),
      ),
    );
  }
}

class ProjectMetadata extends StatelessWidget {
  final ContentProject project;
  final Iterable<String> releases;
  final bool compact;
  const ProjectMetadata({
    required this.project,
    this.releases = const [],
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return LayoutBuilder(
        builder: (_, constraints) {
          final supported = SupportedContentVersions(
            gameVersions: project.gameVersions,
            loaders: project.loaders,
            releases: releases,
            compact: true,
          );
          final stats = [
            _MetadataItem(
              icon: FIcons.download,
              text: '${formatContentDownloads(project.downloads)} 次下载',
              tooltip: '${project.downloads} 次下载',
              compact: true,
            ),
            _MetadataItem(
              icon: FIcons.clock,
              text: formatContentAge(project.updated),
              tooltip: project.updated
                  ?.toLocal()
                  .toIso8601String()
                  .replaceFirst('T', ' ')
                  .substring(0, 16),
              compact: true,
            ),
            if (project.author.isNotEmpty)
              _MetadataItem(
                icon: FIcons.user,
                text: project.author,
                compact: true,
              ),
          ];
          final narrow =
              constraints.maxWidth <
              520 * MediaQuery.textScalerOf(context).scale(12) / 12;
          final row = Row(
            children: [
              if (!narrow) ...[
                Expanded(flex: 5, child: supported),
                const SizedBox(width: 12),
              ],
              for (var i = 0; i < stats.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Flexible(flex: 2, child: stats[i]),
              ],
            ],
          );
          return narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [supported, const SizedBox(height: 2), row],
                )
              : row;
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SupportedContentVersions(
          gameVersions: project.gameVersions,
          loaders: project.loaders,
          releases: releases,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            _MetadataItem(
              icon: FIcons.download,
              text: '${formatContentDownloads(project.downloads)} 次下载',
              tooltip: '${project.downloads} 次下载',
            ),
            _MetadataItem(
              icon: FIcons.clock,
              text: formatContentAge(project.updated),
              tooltip: project.updated == null
                  ? '更新时间未知'
                  : '更新于 ${project.updated!.toLocal().toIso8601String().replaceFirst('T', ' ').substring(0, 16)}',
            ),
            if (project.author.isNotEmpty)
              _MetadataItem(icon: FIcons.user, text: project.author),
          ],
        ),
      ],
    );
  }
}

class _MetadataItem extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? tooltip;
  final bool compact;
  const _MetadataItem({
    required this.icon,
    required this.text,
    this.tooltip,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = LauncherColors.of(context).secondaryText;
    return Tooltip(
      message: tooltip ?? text,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 13, color: color),
          SizedBox(width: compact ? 4 : 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                height: compact ? 1.25 : 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

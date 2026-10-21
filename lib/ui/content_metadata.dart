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

List<String> sortedContentGameVersions(Iterable<String> values) =>
    values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => compareComponentVersions(b, a));

String formatContentGameVersions(Iterable<String> values) {
  final versions = sortedContentGameVersions(values);
  if (versions.isEmpty) return '支持版本未提供';
  return 'Minecraft ${versions.take(3).join(' / ')}'
      '${versions.length > 3 ? ' 等 ${versions.length} 个版本' : ''}';
}

class SupportedContentVersions extends StatelessWidget {
  final List<String> gameVersions, loaders;
  const SupportedContentVersions({
    required this.gameVersions,
    required this.loaders,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    const names = {
      'fabric': 'Fabric',
      'forge': 'Forge',
      'neoforge': 'NeoForge',
      'quilt': 'Quilt',
    };
    final loaderText = loaders
        .map((value) => names[value.toLowerCase()] ?? value)
        .toSet()
        .join(' / ');
    final versions = sortedContentGameVersions(gameVersions);
    final supported = formatContentGameVersions(versions);
    return Tooltip(
      message: versions.isEmpty
          ? supported
          : '支持的 Minecraft 版本：${versions.join(' / ')}',
      constraints: const BoxConstraints(maxWidth: 480),
      child: Text(
        '${loaderText.isEmpty ? '' : '$loaderText · '}$supported',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: LauncherColors.of(context).secondaryText,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}

class ProjectMetadata extends StatelessWidget {
  final ContentProject project;
  const ProjectMetadata({required this.project, super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SupportedContentVersions(
        gameVersions: project.gameVersions,
        loaders: project.loaders,
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

class _MetadataItem extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? tooltip;
  const _MetadataItem({required this.icon, required this.text, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final color = LauncherColors.of(context).secondaryText;
    return Tooltip(
      message: tooltip ?? text,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

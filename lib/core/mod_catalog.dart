import 'dart:convert';
import 'package:xml/xml.dart';
import 'install_options.dart';
import 'models.dart';
import 'network.dart';

int compareComponentVersions(String first, String second) {
  final a = RegExp(
    r'\d+|[a-zA-Z]+',
  ).allMatches(first).map((m) => m[0]!).toList();
  final b = RegExp(
    r'\d+|[a-zA-Z]+',
  ).allMatches(second).map((m) => m[0]!).toList();
  for (var i = 0; i < a.length && i < b.length; i++) {
    final x = int.tryParse(a[i]);
    final y = int.tryParse(b[i]);
    final order = x != null && y != null
        ? x.compareTo(y)
        : a[i].compareTo(b[i]);
    if (order != 0) return order;
  }
  return a.length.compareTo(b.length);
}

class ModCatalog {
  final OfficialNetwork network;
  ModCatalog(this.network);
  Future<List<LoaderVersion>> loaders(
    ModLoader loader,
    String minecraft,
    CancellationToken token,
  ) async {
    if (loader == ModLoader.fabric) {
      final rows =
          await network.jsonValue(
                'https://meta.fabricmc.net/v2/versions/loader/${Uri.encodeComponent(minecraft)}',
                token: token,
              )
              as List<dynamic>;
      final results = rows
          .map(
            (row) => LoaderVersion(
              loader,
              row['loader']['version'] as String,
              coordinate: row['loader']['maven'] as String,
              stable: row['loader']['stable'] == true,
            ),
          )
          .toList();
      results.sort(
        (a, b) => a.stable != b.stable
            ? (a.stable ? -1 : 1)
            : compareComponentVersions(b.version, a.version),
      );
      return results;
    }
    final legacyNeo = loader == ModLoader.neoforge && minecraft == '1.20.1';
    final base = loader == ModLoader.forge
        ? 'https://maven.minecraftforge.net/net/minecraftforge/forge'
        : legacyNeo
        ? 'https://maven.neoforged.net/releases/net/neoforged/forge'
        : 'https://maven.neoforged.net/releases/net/neoforged/neoforge';
    final group = loader == ModLoader.forge
        ? 'net.minecraftforge:forge'
        : legacyNeo
        ? 'net.neoforged:forge'
        : 'net.neoforged:neoforge';
    final document = XmlDocument.parse(
      await network.text('$base/maven-metadata.xml', token: token),
    );
    final versions = document
        .findAllElements('version')
        .map((node) => node.innerText.trim());
    String prefix;
    if (loader == ModLoader.forge || legacyNeo) {
      prefix = '$minecraft-';
    } else if (minecraft.startsWith('1.')) {
      final short = minecraft.substring(2);
      prefix = '${short.contains('.') ? short : '$short.0'}.';
    } else {
      prefix =
          '${minecraft.split('.').length == 2 ? '$minecraft.0' : minecraft}.';
    }
    final results = versions
        .where((version) => version.startsWith(prefix))
        .map(
          (version) => LoaderVersion(
            loader,
            loader == ModLoader.forge || legacyNeo
                ? version.substring(minecraft.length + 1)
                : version,
            coordinate: '$group:$version',
            installerUrl:
                '$base/$version/${base.split('/').last}-$version-installer.jar',
            stable: !version.contains('beta') && !version.contains('alpha'),
          ),
        )
        .toList();
    results.sort((a, b) => compareComponentVersions(b.version, a.version));
    return results;
  }

  Future<List<OptiFineVersion>> optifine(
    String minecraft,
    CancellationToken token,
  ) async {
    final html = await network.text(
      'https://optifine.net/downloads',
      token: token,
    );
    final expression = RegExp(
      '(?:preview_)?OptiFine_${RegExp.escape(minecraft)}_HD_U_[A-Za-z0-9_.]+\\.jar',
    );
    return expression
        .allMatches(html)
        .map((match) => match[0]!)
        .toSet()
        .map(OptiFineVersion.new)
        .toList();
  }

  Future<String> optifineDownload(
    OptiFineVersion version,
    CancellationToken token,
  ) async {
    final html = await network.text(
      'https://optifine.net/adloadx?f=${Uri.encodeQueryComponent(version.fileName)}',
      token: token,
    );
    final links = RegExp(
      r'''(?:https://(?:www\.)?optifine\.net/)?downloadx\?[^"'\s<>]+''',
    ).allMatches(html);
    for (final match in links) {
      final uri = Uri.parse(
        'https://optifine.net/',
      ).resolve(match[0]!.replaceAll('&amp;', '&'));
      if (uri.queryParameters['f'] == version.fileName &&
          uri.queryParameters['x'] != null) {
        return uri.toString();
      }
    }
    throw StateError('OptiFine 官方下载页暂未提供下载链接，请重试或选择已下载的官方 JAR。');
  }

  Future<List<CompatibilityMod>> optifabric(
    String minecraft,
    CancellationToken token,
  ) async {
    final document = await network.json(
      'https://www.curseforge.com/api/v1/mods/322385/files?pageIndex=0&pageSize=50&sort=dateCreated&sortDescending=true',
      token: token,
    );
    final results = <CompatibilityMod>[];
    for (final raw in document['data'] as List<dynamic>? ?? []) {
      final file = raw as Json;
      if (!(file['gameVersions'] as List<dynamic>? ?? []).contains(minecraft)) {
        continue;
      }
      final id = file['id'] as int;
      final name = file['fileName'] as String;
      results.add(
        CompatibilityMod(
          version: name
              .replaceFirst('optifabric-', '')
              .replaceFirst('.jar', ''),
          fileName: name,
          url:
              'https://mediafilez.forgecdn.net/files/${id ~/ 1000}/${(id % 1000).toString().padLeft(3, '0')}/${Uri.encodeComponent(name)}',
          size: file['fileLength'] as int?,
        ),
      );
    }
    return results;
  }

  Future<Json> fabricProfile(
    String minecraft,
    String loader,
    CancellationToken token,
  ) => network.json(
    'https://meta.fabricmc.net/v2/versions/loader/${Uri.encodeComponent(minecraft)}/${Uri.encodeComponent(loader)}/profile/json',
    token: token,
  );
}

Json mergeVersionProfiles(Json vanilla, Json overlay) {
  final result = jsonDecode(jsonEncode(vanilla)) as Json;
  result.addAll(overlay);
  if (vanilla['arguments'] != null || overlay['arguments'] != null) {
    final base = vanilla['arguments'] as Json? ?? {};
    final extra = overlay['arguments'] as Json? ?? {};
    result['arguments'] = {
      for (final name in {'jvm', 'game'})
        name: [
          ...?(base[name] as List<dynamic>?),
          ...?(extra[name] as List<dynamic>?),
        ],
    };
  }
  if (overlay['minecraftArguments'] != null && overlay['arguments'] == null) {
    result.remove('arguments');
  }
  final libraries = <String, dynamic>{};
  for (final raw in [
    ...?(vanilla['libraries'] as List<dynamic>?),
    ...?(overlay['libraries'] as List<dynamic>?),
  ]) {
    final library = raw as Json;
    final parts = (library['name'] as String).split(':');
    final key = parts.length >= 3
        ? '${parts[0]}:${parts[1]}:${parts.length > 3 ? parts[3] : ''}'
        : library['name'] as String;
    libraries[key] = library;
  }
  result['libraries'] = libraries.values.toList();
  result.remove('inheritsFrom');
  return result;
}

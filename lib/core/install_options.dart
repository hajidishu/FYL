enum ModLoader { forge, neoforge, fabric, quilt }

extension ModLoaderName on ModLoader {
  String get label => switch (this) {
    ModLoader.forge => 'Forge',
    ModLoader.neoforge => 'NeoForge',
    ModLoader.fabric => 'Fabric',
    ModLoader.quilt => 'Quilt',
  };
}

class LoaderVersion {
  final ModLoader loader;
  final String version;
  final String coordinate;
  final String? installerUrl;
  final bool stable;
  const LoaderVersion(
    this.loader,
    this.version, {
    this.coordinate = '',
    this.installerUrl,
    this.stable = true,
  });
}

class OptiFineVersion {
  final String fileName;
  final String? localPath;
  const OptiFineVersion(this.fileName, {this.localPath});
  String get label => fileName
      .replaceFirst(RegExp(r'^(preview_)?OptiFine_'), '')
      .replaceFirst(RegExp(r'\.jar$'), '')
      .replaceAll('_', ' ');
}

class InstallOptions {
  // A single loader field makes mutually exclusive loader selections explicit.
  final LoaderVersion? loader;
  final OptiFineVersion? optifine;
  final CompatibilityMod? optifabric;
  const InstallOptions({this.loader, this.optifine, this.optifabric});
  Map<String, dynamic> toJson() => {
    if (loader != null)
      'loader': {
        'type': loader!.loader.name,
        'version': loader!.version,
        'coordinate': loader!.coordinate,
        'installerUrl': loader!.installerUrl,
      },
    if (optifine != null) 'optifine': optifine!.fileName,
    if (optifabric != null)
      'optifabric': {
        'version': optifabric!.version,
        'fileName': optifabric!.fileName,
        'url': optifabric!.url,
        'sha1': optifabric!.sha1,
        'size': optifabric!.size,
      },
  };
  factory InstallOptions.fromJson(Map<String, dynamic> j) {
    final l = j['loader'] as Map<String, dynamic>?;
    final f = j['optifabric'] as Map<String, dynamic>?;
    return InstallOptions(
      loader: l == null
          ? null
          : LoaderVersion(
              ModLoader.values.byName(l['type'] as String),
              l['version'] as String,
              coordinate: l['coordinate'] as String? ?? '',
              installerUrl: l['installerUrl'] as String?,
            ),
      optifine: j['optifine'] == null
          ? null
          : OptiFineVersion(j['optifine'] as String),
      optifabric: f == null
          ? null
          : CompatibilityMod(
              version: f['version'] as String,
              fileName: f['fileName'] as String,
              url: f['url'] as String,
              sha1: f['sha1'] as String?,
              size: f['size'] as int?,
            ),
    );
  }
  bool get isVanilla =>
      loader == null && optifine == null && optifabric == null;
  bool get fabricOptifine =>
      loader?.loader == ModLoader.fabric && optifine != null;
  String get summary => [
    if (loader != null) '${loader!.loader.label} ${loader!.version}',
    if (optifine != null) 'OptiFine',
    if (optifabric != null) 'OptiFabric ${optifabric!.version}',
  ].join(' · ');
  String? get validationError {
    if (loader?.loader == ModLoader.quilt && optifine != null) {
      return '暂不支持将 OptiFine 安装到 Quilt，请取消 OptiFine；光影可使用兼容的 Iris 版本。';
    }
    if (loader?.loader == ModLoader.neoforge && optifine != null) {
      return 'OptiFine 不支持直接安装到 NeoForge。请取消 OptiFine，或选择兼容的加载器；光影可考虑 Iris。';
    }
    if (fabricOptifine && optifabric == null) {
      return 'Fabric 与 OptiFine 同时安装时，请选择 OptiFabric 兼容模组。';
    }
    if (optifabric != null && !fabricOptifine) {
      return 'OptiFabric 需要同时选择 Fabric 和 OptiFine。';
    }
    return null;
  }
}

class CompatibilityMod {
  final String version;
  final String fileName;
  final String url;
  final String? sha1;
  final int? size;
  final String? localPath;
  const CompatibilityMod({
    required this.version,
    required this.fileName,
    required this.url,
    this.sha1,
    this.size,
    this.localPath,
  });
}

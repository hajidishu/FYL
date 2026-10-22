import 'models.dart';

enum MinecraftVersionGroup { release, preview, historical, aprilFools }

extension MinecraftVersionGroupLabel on MinecraftVersionGroup {
  String get label => switch (this) {
    MinecraftVersionGroup.release => '正式版',
    MinecraftVersionGroup.preview => '预览版',
    MinecraftVersionGroup.historical => '远古版',
    MinecraftVersionGroup.aprilFools => '愚人节版',
  };
}

extension MinecraftVersionGrouping on MinecraftVersion {
  MinecraftVersionGroup get group {
    const aprilFools = {
      '15w14a',
      '1.rv-pre1',
      '3d shareware v1.34',
      '20w14infinite',
      '20w14∞',
      '22w13oneblockatatime',
      '23w13a_or_b',
      '24w14potato',
      '25w14craftmine',
      '26w14a',
    };
    if (aprilFools.contains(id.toLowerCase())) {
      return MinecraftVersionGroup.aprilFools;
    }
    return switch (type) {
      'release' => MinecraftVersionGroup.release,
      'snapshot' => MinecraftVersionGroup.preview,
      _ => MinecraftVersionGroup.historical,
    };
  }
}

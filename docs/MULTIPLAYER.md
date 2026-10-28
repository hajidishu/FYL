# 实验性 Minecraft 联机

FYL 使用公共 STUN 辅助建立 P2P 直连：房主把同一份邀请发给朋友，朋友生成回应并发回，房主导入后建立连接。每位朋友分别连接房主，通过本机入口加入房主开放的 Minecraft Java 版局域网世界。

仅转发选定的 Minecraft 游戏端口，不创建系统虚拟网卡，也不接管其他应用的流量。游戏数据不经过中继服务器，部分网络环境可能无法建立直连。

此功能仍为实验性待办，默认运行、普通 Actions 构建和发布包均不包含联机入口。

## 编译

额外安装 Go 1.24+，并在 Flutter 命令中添加 `--dart-define=FYL_ENABLE_MULTIPLAYER=true`：

```sh
flutter run -d windows --dart-define=FYL_ENABLE_MULTIPLAYER=true
flutter build windows --release --dart-define=FYL_ENABLE_MULTIPLAYER=true
flutter build linux --release --dart-define=FYL_ENABLE_MULTIPLAYER=true
flutter build macos --release --dart-define=FYL_ENABLE_MULTIPLAYER=true
```

网络助手会随构建自动生成。手动使用 `tool/release.py package` 打包时，还需添加 `--enable-multiplayer`。

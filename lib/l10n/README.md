# FYL 界面翻译

`catalogs/` 中的 UTF-8 JSON 文件分别对应简体中文、繁体中文、英文、俄语、法语和德语。键是启动器文案的原文；`{p0}`、`{p1}` 等表示运行时填入的名称、版本、路径或数量。翻译可以调整参数顺序，但不能删除或改名。所有语言必须包含相同的键。

修改后重新生成编译使用的同步语言表：

```sh
python tool/generate_localizations.py
dart format lib/l10n/translations.g.dart
```

`python tool/generate_localizations.py --check` 只检查语言键、参数及生成文件是否同步，不启动应用程序。

`message_arguments.json` 仅标记需要进一步翻译的参数，例如嵌套的错误信息和组件类型。用户名、项目名、文件路径等参数不应标记。界面通过 `LText`、`LSelectableText` 和 `LTooltip` 显示启动器文案；用户内容、第三方描述及原始游戏日志继续使用 Flutter 原生文本组件。

新增启动小贴士时，仍在 `assets/launch_tips.json` 添加原文，再在语言文件中补充对应译文。抽取小贴士的逻辑和等概率选择规则保持不变。

# Sayso

A background macOS app for learning how native English speakers really say things. Select some text and press ⌃X X
(or open the panel and type): Sayso shows two native versions side by side — **Sharp** (articulate, exact, a little
dry) and **Chill** (relaxed, like texting a friend) — and highlights the 1–2 expressions worth learning.

- **Polish**: your own English, rewritten the way a native would say it, with grammar mistakes underlined (hover for
  the reason).
- **Reply**: someone else's message → a reply you could send. Add an optional note in Chinese or English
  ("say yes but I'm late", "委婉拒绝").
- **中 → En**: write it in Chinese, get what a native would actually say.

It uses the OpenAI API with your own key, stored in the Keychain.

## 安装 / 更新

需要 macOS 14 或更高版本。在「终端」里运行这一行（安装和以后更新都是它）：

```bash
curl -fsSL https://raw.githubusercontent.com/yufei-zhou/Sayso/main/install.sh | bash
```

第一次打开时：

1. 按提示在「系统设置 → 隐私与安全性」里允许 Sayso 使用 **辅助功能**（读取你选中的文字）和 **输入监控**（识别 ⌃X X 快捷键）。
2. 设置窗口会自动打开，填入你自己的 OpenAI API Key（只保存在本机钥匙串里）。

以后更新时，这些权限和 Key 都会保留。

## 怎么用

- 选中一段文字，连按两下 ⌃X（按住 control，按两下 X）。英文输入框里的文字进 Polish，别人的消息进 Reply，中文进 中→En。
- 不选文字直接按 ⌃X X：打开面板自己输入，↩ 生成，⇧↩ 换行。
- 鼠标移到某个回答上：复制，或"替换原文"直接写回你选中的那段。
- ⌘1 / ⌘2 / ⌘3 切换模式，⌘N 清空，⌘Y 历史记录，⌘, 设置，Esc 关闭。
- 快捷键可以在设置里重新录制（支持连按两下的组合，例如 ⌘C C）。
- 退出：在设置或历史窗口里按 ⌘Q。

## 卸载

```bash
pkill -x Sayso; rm -rf /Applications/Sayso.app ~/Library/Application\ Support/Sayso; defaults delete local.nano.Sayso
```

API Key 在「钥匙串访问」里，名称为 Sayso，可以一并删除。

## Development

```bash
./build.sh            # build build/Sayso.app (Apple silicon + Intel)
./build.sh install    # build, copy to /Applications and restart
./release.sh X.Y.Z "notes"   # publish a signed release that install.sh picks up
```

- Prompts live in `prompts/` and can also be edited in Settings › Prompts. `QUALITY.md` defines what a good answer is;
  `eval/` holds the test sets, the eval scripts and the results of every prompt version (see `eval/README.md`).
- `TESTING.md` explains how to test the app without the real API, the keyboard or the clipboard.

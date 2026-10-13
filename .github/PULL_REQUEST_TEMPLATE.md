<!--
先读 CONTRIBUTING.md。一个 PR 做一件事；以下按实际情况填，不适用的直接删掉小标题。
-->

## 变更内容

## 为什么

## 验证

<!-- 实际跑过的命令与观察到的结果。没验证的部分明确写"未验证"，以及为什么。 -->

## 检查项

- [ ] 行为/接口变更已更新对应插件的 `README.md` 与 `CHANGELOG.md`
- [ ] 新增文案走 `I18n.trFor()`，并在 `translations/zh_CN.json` 补齐中文键
- [ ] 新增设置项在 daemon 读取、设置页控件、翻译三处齐全
- [ ] 外部命令以 argv 传递，外部可控字符串已做校验
- [ ] `qmllint <Plugin>/*.qml` 无报错
- [ ] 有破坏性变更时已 bump `plugin.json` 的 `version`

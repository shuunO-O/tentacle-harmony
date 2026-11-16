# Tentacle Harmony

这是独立的鸿蒙客户端仓库。后端在 https://github.com/shuunO-O/tentacle。

- 鸿蒙构建与设备工具使用 `devecocli`（若环境未安装，Agent 需先按官方指南下载安装 DevEco CLI：https://developer.huawei.com/consumer/cn/doc/guidebook/aitech2026-3-1-0000002686528855 ）；逻辑检查运行 `node tests/check-chat.cjs`。
- 命令识别属于后端；客户端从 `/api/chat/commands` 读取候选，统一调用 `/api/chat/send`。
- 保留草稿、历史竞争保护、分段顺序和滚动阅读位置；不要恢复旧的本地命令清单。
- 本机 `build-profile.json5`、签名材料、依赖缓存和构建产物均忽略，不得提交。
- 测试使用虚构数据和模拟网络；不要读取手机或后端的私人消息。

# 架构与协议说明

本文档说明 Tentacle Harmony 客户端的模块结构、与 [tentacle](https://github.com/shuunO-O/tentacle) 后端对齐的接口契约，以及本地隔离测试覆盖范围。

---

## 目录分层

源码位于 `entry/src/main/ets/`：

| 目录 | 职责 | 主要文件 |
| --- | --- | --- |
| `pages/` | 应用主容器、侧边导航、全局轻提示、前后台切换恢复与连接编排 | `Index.ets` |
| `view/` | 各功能页面视图 | `ChatPage.ets`、`ConfigurationPage.ets`、`PluginsPage.ets`、`StatusPage.ets`、`SettingsPage.ets`、`FilesPage.ets`、`StatsPage.ets`、`GraphPage.ets`、`DedupPage.ets`、`SubagentsPage.ets`、`AdminPage.ets`、`TerminalPage.ets`、`ConnectPanel.ets` |
| `components/` | 可复用 UI 组件与分段渲染 | `AgentGroupItem.ets`、`BubbleItem.ets`、`MarkdownBody.ets`、`MediaAttachment.ets`、`MessagePartItem.ets`、`ToolCallItemView.ets`、`FileDownload.ets`、`GraphCanvas.ets`、`PhoneSettings.ets`、`SettingsExtras.ets`、`EditDialog.ets`、`Meters.ets`、`StatRow.ets`、`UiKit.ets` |
| `model/` | 数据结构、纯逻辑解析、导航/分组规则与状态模型 | `Types.ets`、`ChatHistory.ets`、`ChatCommands.ets`、`ConfigurationNavigation.ets`、`Management.ets`、`Plugins.ets`、`PhoneProtocol.ets`、`FileMarkers.ets`、`Markdown.ets`、`GraphSnapshot.ets`、`GraphScene.ets`、`GraphWheel.ets`、`GraphTextLayout.ets`、`UiToast.ets` |
| `service/` | 网络通信、断线同步恢复、文件传输、本地缓存与手机原生能力 | `TentacleApi.ets`、`ChatRecovery.ets`、`FileTransfer.ets`、`LocalCache.ets`、`PhoneIntegration.ets`、`PhoneNative.ets`、`WheelSound.ets` |

---

## 页面与后端接口对照

| 功能域 | 客户端模块 | 对应后端接口与说明 |
| --- | --- | --- |
| 聊天、命令、历史与同步 | `ChatPage`、`ChatStore`、`ChatRecovery` | `POST /api/chat/send`、`GET /api/chat/commands`、`POST /api/chat/stop`、`GET /api/chat/sync`、`GET /api/chat/history`、`/ws/chat` |
| 文件与多媒体 | `FilesPage`、`FileTransfer`、`MediaAttachment`、`FileDownload` | `POST /api/files/upload`、`GET /api/files`、`GET /api/files/{local_id}/content`、`GET /api/files/download`、`DELETE /api/files/{local_id}` |
| 系统配置中心 | `ConfigurationPage`、`ConfigurationNavigation`、`Management` | `GET/PUT /api/configuration`、`/preview`、`/structure`、`/restore`、`/discover-models`、`/environment`、`/apply`、`/restart` |
| 插件扩展与 MCP | `PluginsPage`、`Plugins` | `GET /api/plugins`、`POST /api/plugins/local/{id}/decision`、`DELETE /api/plugins/local/{id}`、`POST/DELETE /api/plugins/mcp/{id}`、`POST /api/plugins/mcp/{id}/reconnect`、`POST /api/plugins/env`、`POST /api/plugins/restart` |
| 状态与宿主维护 | `StatusPage` | `GET /api/status`、`GET/POST /api/maintenance`、WS `status.snapshot` / `maintenance.updated` |
| 统计与余额 | `StatsPage` | `GET /api/usage`、`GET /api/balance`（按供应商连接独立查询） |
| 记忆图谱与去重 | `GraphPage`、`GraphSnapshot`、`DedupPage` | `/api/neo4j/summary`、`/api/neo4j/graph`（后端兼容别名）、`/api/memory/dedup*`、WS `dedup.progress` |
| 子代理与终端 | `SubagentsPage`、`TerminalPage` | `GET /api/subagents`、`/api/subagents/{id}`、WS `subagent.updated`；`GET /api/terminal/history`、WS `terminal_data` |
| 记忆库与自改备份 | `AdminPage`、`SettingsExtras` | `/api/admin/messages`、`/sessions`、`/summaries`、`/goals`、`/tasks`、`/query`、`/backups`、`/backups/restore` |
| 设置与鉴权 | `SettingsPage`、`ConnectPanel`、`SettingsExtras` | `/api/auth/state`、`/enroll`、`/login`、`/set_password`、`/devices`、`/device_auth`、`/new_devices`、`GET/PUT /api/settings` |
| 鸿蒙手机联动 | `PhoneIntegration`、`PhoneNative`、`PhoneSettings` | `/api/plugins/ext/harmony/register`、`/state`、`/actions/{action_id}/receipt` |

---

## 核心协议与客户端不变量

### 1. 对话、命令与断线同步

- **统一发送与服务端命令**：所有用户输入统一通过 `POST /api/chat/send` 发送（`platform: "harmony"`，附带客户端生成的唯一 `request_id`）；斜杠命令候选由 `GET /api/chat/commands` 下发，不在客户端维护本地命令识别表。
- **回合终态与竞争保护**：
  - WebSocket `final` 只停止对应流式气泡的输入效果；只有与当前 `request_id` 匹配的 `round_finished` 或 HTTP `/api/chat/send` 终态才可结束发送锁定。
  - 重复回执只处理一次；迟到的旧 `final`、旧终态、心跳或后台回合不能关闭当前请求；网络超时或失败保留“结果未确认”状态，绝不自动重发。
- **历史顺序与阅读位置**：
  - 历史直接按后端返回行顺序与 `segments` 数组渲染（不按时间重排，不自行拆段）；分页加载更早记录使用归档 `id` 与 `has_more` 判断边界。
  - 保留输入草稿、已上传附件映射、历史请求代次竞争保护以及手动阅读滚动位置。
- **断线与回前台恢复（`ChatRecovery`）**：
  - WS 建连、重连与应用回前台调用 `GET /api/chat/sync` 拉取进程快照，恢复归档与在途回合后，仅放行同一 `chat_instance` 且 `chat_seq` 超出快照边界的缓冲事件；旧后端返回 `404`/`405` 时降级为历史刷新。

### 2. 配置管理（三层 v2 结构）

- 后端已全面采用「**供应商连接（`providers`）→ 模型（`models`）→ 角色（`roles`）**」三层结构，不再返回 `config_version` 或提供 `/api/configuration/migrate` 接口。
- `ConfigurationPage` 按 Web 四大分区（`models` / `memory` / `runtime` / `channels`）组织编辑项，在「模型与连接」直接展示三级实体连接树（`EntityTree`）与面包屑检查器（`Inspector` + `HierarchyBanner`），不再保留 v1 迁移回退分支。
- 写操作（字段修改、结构增删、目录导入、备份恢复）均须先预览差异并携带当前 `revision` 提交；编辑字段会使旧预览失效，受保护字段不可修改；`.env` 密钥值通过 `/api/configuration/environment` 只写录入，不在配置快照中明文回显。
- `plugins.items.*` 由 `PluginsPage` 统一管理，在 `ConfigurationPage` 中过滤隐藏。

### 3. 文件与媒体安全边界

- 图片与普通附件上传前计算 SHA-256，命中未删除缓存时复用已有 `local_id`；`LocalCache`（`filesDir/tentacle-cache-v1`）按当前服务器地址与凭据作用域隔离。
- 附件下载（`FileTransfer`）与音视频播放（`MediaAttachment`）均在请求头携带 Bearer Token 与设备 Cookie，不把认证凭据写入 URL；下载先流式写入临时文件，校验完整成功后再交给系统保存，失败或退出时释放句柄与临时文件。

### 4. 鸿蒙手机能力插件边界

- 手机联动通过后端内置 `harmony` 插件（`/api/plugins/ext/harmony/*`）接入；实况窗参数通过 `/api/chat/send` 的 `client_meta.live_view` 传递，对应模型工具名为 `p_harmony__phone_alarm`。
- 仅当服务端明确因插件关闭实况窗或手机会话凭证失效拒收且尚未进入模型回合时，客户端结束本机实况窗并去除 `client_meta.live_view` 补发一次；`DeviceAccessGate` 的 403 不触发降级重试。
- 闹钟执行先持久化回执账本再越过系统边界，只有系统返回成功才上报 `executed`，避免崩溃或重连后重复创建闹钟。

---

## 本地测试与构建检查

仓库提供完全基于虚构数据与模拟网络的隔离逻辑检查（不连接真实设备或生产服务器）：

```powershell
node tests/check-chat.cjs
```

`tests/check-chat.cjs` 会顺序执行各专项测试模块：
- `tests/check-chat.cjs`：命令路由、历史竞争、Markdown 流式渲染、滚动阅读位置与草稿/附件恢复
- `tests/check-chat-recovery.cjs`：`/api/chat/sync` 快照恢复、停止回合、序号边界与断线兜底
- `tests/check-management.cjs`：统计筛选、三层配置导航/预览/并发冲突/目录导入、设备门与文件下载生命周期
- `tests/check-plugins.cjs`：`PluginsPage`、`.env` 录入、`ConfigurationPage` 四分区/检索/创建、`/api/maintenance`、`DedupPage` 与 `SubagentsPage`
- `tests/check-phone.cjs`：手机注册、插件拒收降级、闹钟回执幂等与实况窗生命周期
- `tests/check-streaming-view.cjs`、`tests/check-cache.cjs`、`tests/check-local-cache.cjs`、`tests/check-graph-scene.cjs`：流式组件、缓存与图谱轮盘布局

代码规范与构建校验使用 `devecocli`：

```powershell
devecocli check lint
devecocli build
```

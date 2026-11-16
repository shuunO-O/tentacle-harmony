# Tentacle Harmony

Tentacle 的鸿蒙客户端（ArkTS / Stage 模型）。配套后端仓库：[shuunO-O/tentacle](https://github.com/shuunO-O/tentacle)。

## 主要功能

- **实时对话与中断恢复**：支持 Markdown 流式渲染、思考与工具调用折叠、输入草稿持久化、停止当前回合，以及通过 `/api/chat/sync` 在切后台或断线重连后恢复在途回合；所有输入统一发送到后端，命令候选由后端动态下发。
- **文件与多媒体**：支持图片、普通文件上传与音视频播放；支持直接引用“服务器已有文件”，并通过 SHA-256 指纹避免重复上传；图谱快照、上传映射与图片预览支持本地缓存（`filesDir/tentacle-cache-v1`）与手动清理。
- **知识图谱**：原生 Canvas 半圆关系轮盘，支持旋转浏览邻居、局部关系边合并展示、全量节点搜索与独立“节点详情”页签，以及可静音的本地 SoundPool 刻度音效。
- **系统与扩展管理**：统计与多供应商余额筛选、字段驱动的应用配置（含 `string_list` 与 `.env` 凭据安全录入）、插件与 MCP 服务管理、设备鉴权、文件管理、概念去重与只读子代理任务。功能对照见 [Web 适配说明](docs/WEB_PARITY_2026-10-22.md)。
- **手机能力（可选）**：支持系统代理提醒闹钟与回复实况窗调测（需后端启用内置 `harmony` 插件及对应的华为开放能力/签名配置）。

---

## 快速开始：构建、签名与安装

HarmonyOS 真机运行通常需要完成 **本地配置准备 → 依赖同步 → 调试签名 → 编译安装** 四个步骤。

### 1. 环境准备

- **DevEco Studio**：推荐 `6.1.1` 或兼容版本（项目 `modelVersion` 为 `6.1.1`，`targetSdkVersion` 为 `6.1.1(24)`）。
- **HarmonyOS SDK**：通过 DevEco Studio SDK Manager 安装对应版本 SDK 与工具链。
- **Node.js**（可选）：仅用于运行 `tests/` 下的本地隔离逻辑检查。
- **运行设备**：HarmonyOS 手机（真机需开启“开发者选项”及“USB 调试”/无线调试）或 DevEco Studio 模拟器。

### 2. 准备本地构建配置

仓库中不包含本机签名与环境配置，首次拉取代码后需从模板创建：

```powershell
Copy-Item build-profile.example.json5 build-profile.json5
```

> `build-profile.json5`、签名证书/Profile（`.p12`、`.p7b`、`.cer` 等）和构建产物均已列入 `.gitignore`，请勿提交到仓库。

### 3. 修改包名（真机安装建议）

默认模板 [`AppScope/app.json5`](AppScope/app.json5) 中的 `bundleName` 为占位值 `com.example.tentacleapp`。
如果要安装到真机或启用系统代理提醒、实况窗、Push Kit 等能力，建议先将 `bundleName` 修改为你自己的唯一包名（例如 `com.yourname.tentacle`）。

### 4. 配置签名并安装运行

#### 方式一：使用 DevEco Studio（推荐，最简单）

1. 用 **DevEco Studio** 打开本仓库根目录，等待 `ohpm` 依赖同步完成（若未自动同步，可在项目根目录执行 `ohpm install`）。
2. 通过数据线连接 HarmonyOS 真机，并在手机上信任当前电脑的调试授权。
3. 打开 **File → Project Structure → Project → Signing Configs**（或点击编辑器右上角的签名提示）。
4. 勾选 **Support HarmonyOS** 与 **Automatically generate signature**，登录你的华为开发者账号并点击 **Apply / OK**。
   DevEco Studio 会自动生成调试证书与 Profile，并将配置写入本地 `build-profile.json5`。
5. 在顶部设备栏选择你的真机或模拟器，点击 **Run 'entry'** 即可自动编译、签名并安装到设备。

#### 方式二：使用命令行构建与安装

在已配置好签名（`build-profile.json5` 中存在有效 `signingConfigs`）和 DevEco 工具链的终端中：

```powershell
# 1. 安装依赖（首次或依赖变更时）
ohpm install

# 2. 构建应用（使用 devecocli，或使用 hvigorw）
devecocli build
# 或：hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

编译完成后，已签名的 HAP 安装包通常位于：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

使用 `hdc` 安装到已连接的真机：

```powershell
hdc app install entry/build/default/outputs/default/entry-default-signed.hap
```

> 如果遇到签名校验失败（如设备未加入调试设备列表或包名冲突），请在 DevEco Studio 中重新执行一次 **Automatically generate signature**，或先卸载手机上的旧版同名应用后重试。

### 5. 连接 Tentacle 后端

1. 先部署并启动 [tentacle](https://github.com/shuunO-O/tentacle) 后端服务。
2. 在手机上打开 Tentacle Harmony，在连接面板输入后端地址（例如局域网 `http://192.168.x.x:8420` 或你的 HTTPS 域名）。
3. 按页面提示完成设备注册与鉴权即可开始使用。

---

## 手机能力说明（闹钟与实况窗，可选）

普通聊天、图谱浏览、文件收发与管理功能**无需**申请额外的华为开放能力即可正常使用。

如需使用设置页“手机能力”中的**代理提醒闹钟**与**回复实况窗**：

1. **后端要求**：Tentacle 后端主模型需启用内置插件 `plugins/bundled/harmony/`（提供 `/api/plugins/ext/harmony/*` 路由及 `p_harmony__phone_alarm` 工具）。
2. **权限与签名**：
   - 闹钟使用系统代理提醒（`ohos.permission.PUBLISH_AGENT_REMINDER`），需要对应的华为开放能力与签名 Profile；未开通时明确返回失败，不回退为不可靠的本地定时器。
   - 实况窗本地创建可在 AGC 添加调测设备（可在设置页获取并复制 Push Token）；应用在后台或被冻结期间的云端更新需要额外开通实况窗正式权益并配置 Push Kit 服务账号。
3. **行为边界**：只有系统明确返回成功时，闹钟工具才会向后端上报 `executed`；关闭“实况窗”会结束当前活动，关闭“闹钟”仅停止接收新的 Agent 闹钟，不会删除已设置的系统提醒。

---

## 本地测试与开发检查

项目提供不依赖真机和真实后端的隔离逻辑测试（使用虚构数据与模拟网络）：

```powershell
node tests/check-chat.cjs
```

- 默认自动查找 DevEco Studio 随附的 TypeScript 编译器；若安装路径不同，可通过环境变量 `TYPESCRIPT_MODULE` 指定。
- 若使用 `devecocli` 进行构建与设备调试，可执行 `devecocli build`（AI Agent 协作开发前需先安装 DevEco CLI，详见[华为开发者 DevEco CLI 指南](https://developer.huawei.com/consumer/cn/doc/guidebook/aitech2026-3-1-0000002686528855)）。

---

## 后端接口基线

当前客户端适配 `tentacle` 主分支提交 `be39c3b` 协议：

- `POST /api/chat/send`：统一发送聊天与命令（`platform: "harmony"`，含 `request_id`、`files` 与可选 `client_meta.live_view`）。
- `GET /api/chat/commands`：获取输入框命令候选。
- `POST /api/chat/stop`：携带当前回合 `round_id` / `request_id` 请求停止。
- `GET /api/chat/sync` / `GET /api/chat/history`：恢复在途回合快照与按消息顺序分页加载历史（旧后端不支持 `sync` 时自动降级）。
- `/ws/chat`：实时事件流与 `phone_action` 同步。
- `/api/plugins/*`、`/api/plugins/ext/harmony/*`：插件、MCP、`.env` 凭据及鸿蒙扩展能力接口。
- `/api/usage`、`/api/balance`、`/api/configuration` 等管理页 REST API。

---

## 开源许可

本项目基于 [MIT License](LICENSE) 开源。

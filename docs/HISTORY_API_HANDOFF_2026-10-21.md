# 鸿蒙接手：逐条历史消息接口（2026-10-21）

用户已确认本次只修改后端与 Web，鸿蒙仅留本文，客户端稍后独立修改。
后端实现：`codex/visible-message-history`，提交 `20f6f13`（未代表生产部署）。
后端仓库：https://github.com/shuunO-O/tentacle
客户端仓库：https://github.com/shuunO-O/tentacle-harmony

## 范围与当前状态

后端不改变数据库表结构、模型上下文和命令入口；保留现有 WS 事件名称和数据字段。
每次模型文字输出、每条确认成功的外发消息各写一条 raw_messages，正文为纯文本，
已有 platform 表示所属平台，同轮共享已有 round_id，自增 id 确定消息顺序。
本轮前半段文字不再被最后回复覆盖。

不做旧历史兼容，不批量迁移、清空或读取私人数据。
旧拼接内容不会再被后端识别为多条消息，只按原始正文处理。
不要在鸿蒙新增旧格式 fallback、版本探测或本地命令分流。

本文随代码提交并不代表生产后端已经部署；客户端适配和后端上线需协调。

## GET /api/chat/history?limit=50

limit 仍表示回合数，范围 1～200；一轮可含任意多条助手消息。
响应按 id 升序，最近 N 轮完整返回，不按 created_time 排序，不截断一轮。

```json
{
  "messages": [
    {"id": 101, "round_id": "round-example", "role": "user", "platform": "harmony",
     "content": "检查并通知", "created_time": 1792540800.0, "images": null},
    {"id": 102, "round_id": "round-example", "role": "assistant", "platform": "web",
     "content": "我先检查一下", "segments": ["我先检查一下"], "created_time": 1792540800.1, "images": null},
    {"id": 103, "round_id": "round-example", "role": "assistant", "platform": "qq",
     "content": "已通知", "segments": ["已通知"], "created_time": 1792540800.2, "images": null},
    {"id": 104, "round_id": "round-example", "role": "assistant", "platform": "web",
     "content": "检查完成\n\n第二段", "segments": ["检查完成", "第二段"],
     "created_time": 1792540800.3, "images": null}
  ],
  "has_more": false
}
```

- 所有 role 的 content 都是字符串，assistant 不再是包含 bubbles/final_text/final_segments 的对象。
- assistant.segments 总是数组。分段开启时后端按共用规则拆好，关闭时为 `[content]`。
  客户端直接按数组顺序展示，不自行按空行拆分。
- platform 继续使用现有含义：直接回复属于展示通道 web，外发记录使用 qq 等目标平台；
  输入来自 harmony 并不使直接回复变成外发消息。
- id 是归档后的标识，不是流式 token 序号；允许有间隔，不假设连续。
- 同一 round_id 的相邻助手行可放到同一个展示组，但气泡顺序须保持服务端顺序。
- has_more 用于显示“加载更早”，不再使用 messages.length 与 limit*2 比较。
- 心跳和子任务报告也带 round_id；宿主临时 NOTICE 仍不属于归档消息。

## 客户端需要修改的位置

1. `entry/src/main/ets/model/Types.ets`：历史消息 content 改为 string，增加 id、round_id，
   assistant 增加 segments；历史响应增加 has_more。删除旧的嵌套历史内容类型。
2. `entry/src/main/ets/view/ChatPage.ets::loadHistory`：按返回行顺序构建气泡，使用
   m.segments 和 m.platform；删除 hasSendBubbles、旧草稿判断及 finalBubbles 重建分支。
   保留历史请求竞争保护、页面可见性检查和滚动阅读位置保护。
3. 若进行分页，用 id 定位已归档消息/去重，使用 has_more 判断边界。
   不假设每轮只有一条 assistant；round_id 仅用于分组，不是排序码。

## WS 与命令

`message_delta`、`message_seg_end`、`message`、`tool_call`、`tool_result`、`final` 保持现有格式。
不添加临时消息 ID，不根据 REST 历史重建正在流式接收的回复。
send_message 隐藏工具卡时，后端可能使用已有 message_seg_end 收尾前一条流式文字；
沿用现有处理即可。发送失败不会生成灰显的已发送气泡。
命令继续 POST /api/chat/send，候选继续 GET /api/chat/commands。

## 合成验收用例

- 模型先说“我先检查一下”，调用普通工具，最后说“检查完成”：刷新后两句均保留。
- 直接回复 → QQ 外发成功 → 最终回复：实时与刷新后的三条消息顺序相同。
- 外发失败/没有结果：不显示已发送气泡，后续回复正常显示。
- 分段开/关、代码围栏内空行、同一轮多条助手记录：内容不丢失、不倒序。
- 正文包含 `[send_message][qq]...[/send_message]` 示例：只作为普通文字。
- 相同或回拨的时间戳：仍按 id 顺序显示；分页不重复、不截断回合。
- 保留草稿、历史加载竞争保护、REST 完成兜底和实时流式更新。

本次没有修改或构建、安装鸿蒙客户端。

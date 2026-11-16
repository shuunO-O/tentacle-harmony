# 回合完成通知与鸿蒙接手说明（2026-10-21）

本次修改后端与 Web；鸿蒙客户端只留接入说明，暂不修改、构建或安装。
代码提交不表示生产后端已部署，需要与客户端适配协调上线。

## 完成是什么意思

原来的 WS `final` 继续保留，用来停止打字效果。它只表示模型停止输出，不能用于确认保存成功。
新增 WS `round_finished`：后端完成上下文、逐条归档、用户回退点等宿主处理后，才报告 completed。
模型失败、保存失败、命令异常报告 failed；取消报告 cancelled；没有执行的后台回合报告 skipped。
工具、文件等可能已经产生部分效果，failed/cancelled 不代表自动回滚，也不要自动重发。

命令也产生相同终态，仍不调用主模型、不进入聊天归档。`stop_reason=command`，结果在 command 字段。
未知命令、错误参数等原有反馈仍是命令文本；completed 表示处理器执行并返回，不把文本内容解析成成功/失败。
心跳让路、等待用户输入、迭代上限保留各自 stop_reason（yielded、waiting_input、iteration_limit）；
completed 表示宿主正常结束本次处理，不保证模型完成了用户目标。

## 请求和回合标识

POST `/api/chat/send` 可额外提交 `request_id`：1～128 字符，每次新发送生成一个客户端标识。
例如 `{"text":"你好","platform":"harmony","request_id":"client-request-123"}`。
`/api/chat/command` 兼容入口也接受此字段。识别仍由后端统一完成，客户端不维护命令逻辑。

后端在进入 run_round 时生成独立 round_id，复用它作为本轮归档已有 round_id，不改数据库结构。
命令虽然不归档，也会分配自己的 round_id。心跳、子任务结果的 request_id 通常为 null。
request_id 只用于关联，既不是鉴权凭证，也不是幂等键；本次不提供状态查询、自动重试或请求去重。
进入回合前的鉴权、空输入、缺失附件、重启拒绝等校验错误可没有 round。

## HTTP 和 WebSocket

HTTP 成功响应继续含 ok、total_tokens，新增 round。命令保留顶层 command，旧命令接口保留 text。
模型错误或保存失败返回 HTTP 500、ok=false、detail 和相同 round；输入处理 ValueError 为 400。

```json
{
  "ok": true,
  "total_tokens": 120,
  "round": {
    "round_id": "server-round-abc",
    "request_id": "client-request-123",
    "source": "user",
    "platform": "harmony",
    "status": "completed",
    "stop_reason": "complete",
    "error": null
  }
}
```

相应 WS 事件为 `{"type":"round_finished","data":上述round对象,"round":关联信息}`。
其 data 与 HTTP 的 round 相同。命令终态额外含
`command: {"text":"命令反馈","refresh_history":true}`，即使 HTTP 回执迟到也能收尾。

本轮产生的 message_delta、message、thinking、tool_call、final、error 等原有事件名和 data 不变，
只增加顶层 `round: {round_id, request_id, source, platform}`。非回合事件如 hello、设置、独立终端输出可以没有它。
平台仍表示输入渠道；source 表示 user/heartbeat/subagent，不要由平台或消息文本猜测来源。
不添加流式增量序号，不改变增量顺序。

## 鸿蒙接入要点

1. 发送前记录新的 request_id，与 HTTP 请求一起提交；将事件的 round 元数据及终态映射到类型定义。
2. 收到 final/error 只结束对应输出气泡。不能因任意 final 或心跳通知解除自己的 sending。
3. 仅在终态 request_id 等于当前请求时解除该请求发送状态。HTTP 和 WS 任一路先返回均可，重复到达只处理一次。
4. 命令反馈也只处理一次；保留现有历史刷新、防竞态、草稿、滚动与 REST 补救逻辑。
5. 迟到的旧 final、旧终态或 HTTP finally 不能关闭新回合的气泡、解除新请求的发送状态。
6. 无 WS 时用 HTTP round 收尾；网络错误且没有已收到的终态时，只能报告连接错误、结果未确认。
   这不证明服务端失败，不自动重发。HTTP 已失败后到达的旧事件也不能影响新的请求。

只用合成资料验收：final 后延迟保存、保存失败、模型错误、慢命令、命令/心跳交错、WS 缺失、
HTTP/WS 重复或迟到回执，以及两个客户端同时发送。不要读取真实历史或启动真实模型对话。

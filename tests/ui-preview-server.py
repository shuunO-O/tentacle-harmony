"""Synthetic, read-only UI fixture server. Never connects to a real Tentacle backend."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def field(path, label, value, group, kind="string", **options):
    return dict(path=path, label=label, value=value, active=value, default=value, group=group, kind=kind,
                effect="round", source="explicit", choices=[], nullable=False, inheritable=False,
                protected=False, pending=False, minimum=None, maximum=None, help="", **options)


providers = [dict(id="cloud", label="云端连接", type="openai_compatible", references={}),
             dict(id="local", label="本地连接", type="openai_compatible", references={})]
models = [dict(id="flash", label="日常对话", name="demo-flash", provider="cloud", references=[]),
          dict(id="reasoning", label="深度推理", name="demo-reasoning", provider="cloud", references=[]),
          dict(id="offline", label="离线模型", name="demo-local", provider="local", references=[])]
roles = [dict(id=key, label=key, model="flash" if key in ("chat", "compress", "subconscious") else "reasoning", references=[])
         for key in ("chat", "subagent", "memory_extractor", "compress", "subconscious")]
fields = []
for p in providers:
    prefix = f"providers.{p['id']}."
    group = "连接 · " + p["id"]
    fields += [field(prefix + "label", "显示名称", p["label"], group),
               field(prefix + "type", "连接类型", p["type"], group),
               field(prefix + "base_url", "API 地址", "https://example.invalid/v1", group),
               field(prefix + "api_key_env", "密钥环境变量", "DEMO_API_KEY", group),
               field(prefix + "proxy", "代理", "", group)]
for m in models:
    prefix = f"models.{m['id']}."
    group = "模型 · " + m["id"]
    fields += [field(prefix + "label", "显示名称", m["label"], group),
               field(prefix + "provider", "供应商连接", m["provider"], group),
               field(prefix + "name", "远端模型名称", m["name"], group),
               field(prefix + "defaults.temperature", "温度", 0.7, group, "number")]
for r in roles:
    prefix = f"roles.{r['id']}."
    group = "角色 · " + r["id"]
    fields += [field(prefix + "model", "使用模型", r["model"], group),
               field(prefix + "max_iterations", "最大执行轮数", 20, group, "integer"),
               field(prefix + "temperature", "温度", 0.7, group, "number"),
               field(prefix + "timeout", "请求超时", 60, group, "integer"),
               field(prefix + "tools.enabled", "可用工具", ["file_read"], group, "tools")]
fields += [field("heartbeat.interval_minutes", "心跳间隔（分钟）", 30, "心跳", "number"),
           field("heartbeat.enabled", "启用心跳", True, "心跳", "boolean"),
           field("web.enabled", "启用网页工具", True, "公开网页工具", "boolean"),
           field("features.subagents", "启用子代理", True, "功能开关", "boolean"),
           field("service.port", "服务端口", 8080, "服务", "integer")]
snapshot = dict(revision="a" * 64, config_version=2, fields=fields,
                entities=dict(providers=providers, models=models, roles=roles),
                provider_types=dict(openai_compatible=dict(label="OpenAI 兼容", auth="api_key", protocols=["chat", "responses"], base_url="https://example.invalid/v1", api_style="chat")),
                tools={r["id"]: ["file_read", "web_search", "schedule"] for r in roles},
                connection_status={p["id"]: dict(auth="api_key", configured=True) for p in providers},
                history=[], active_model=dict(name="demo-flash", provider_id="cloud", model_id="flash", api_style="chat"),
                active_role="chat", applying=False, error=None, restart_required=False, restart=dict(available=True, state="idle"))
file_records = [dict(local_id="sample-report", filename="项目报告.pdf", mime="application/pdf", path="data/files/demo.pdf", size=24576),
                dict(local_id="sample-note", filename="灵感笔记.txt", mime="text/plain", path="data/files/demo.txt", size=4096)]
plugins_snapshot = dict(
    revision="b" * 64,
    plugins=[
        dict(
            id="harmony", kind="local", enabled=True, trusted=True, bundled=True,
            saved_enabled=True, saved_trusted=True, status="active", error=None,
            manifest=dict(
                id="harmony", name="鸿蒙手机联动", version="1.0.0",
                description="接入 Tentacle Harmony 客户端：设备注册授权、一次性闹钟队列与回执、实况窗同步与华为云推送。",
                permissions=["tools:register", "web:routes", "hooks:mutate", "fs:plugin_data", "network:outbound"],
                optional_env=["HUAWEI_PUSH_CREDENTIALS_FILE", "HUAWEI_PUSH_PROJECT_ID"],
                config_schema=dict(
                    action_wait_seconds=dict(key="action_wait_seconds", label="闹钟回执等待超时（秒）", type="number", default=12),
                    allow_alarms=dict(key="allow_alarms", label="允许向手机下发闹钟", type="boolean", default=True),
                    allow_live_view=dict(key="allow_live_view", label="允许实况窗与推送同步", type="boolean", default=True),
                ),
            ),
            permission_details=[
                dict(permission="tools:register", level="low", summary="注册工具到模型工具表"),
                dict(permission="web:routes", level="high", summary="挂载受设备与密码鉴权保护的后端 API 子路由"),
            ],
            config=dict(action_wait_seconds=12, allow_alarms=True, allow_live_view=True),
            saved_config=dict(action_wait_seconds=12, allow_alarms=True, allow_live_view=True),
            disabled_tools=[], saved_disabled_tools=[],
            tools=[dict(raw_name="phone_alarm", name="p_harmony__phone_alarm", description="在当前鸿蒙手机设置一次性闹钟", enabled=True)],
            commands=[], hooks=[], skills=[], channels=[], routes=[], background_tasks=0,
            missing_env=[], env_vars=["HUAWEI_PUSH_CREDENTIALS_FILE", "HUAWEI_PUSH_PROJECT_ID"],
            env_status=dict(HUAWEI_PUSH_CREDENTIALS_FILE=False, HUAWEI_PUSH_PROJECT_ID=False),
            has_prompt=False, pending_restart=False,
        )
    ],
    mcp_servers=[],
    permission_catalog={},
    restart_required=False,
    restart=dict(available=True, state="idle"),
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        route = urlsplit(self.path).path
        replies = {
            "/api/auth/state": dict(device_auth=False, device_ok=True, has_password=False, freeze=False),
            "/api/settings": dict(agent_name="Tentacle", show_reasoning=False, split_messages=True),
            "/api/chat/history": dict(messages=[], has_more=False),
            "/api/chat/commands": dict(commands=[]),
            "/api/configuration": snapshot,
            "/api/plugins": plugins_snapshot,
            "/api/files": dict(files=file_records),
            "/api/admin/messages": dict(columns=["id", "role", "content"], rows=[], total=0, row_count=0, truncated=False),
        }
        if route not in replies:
            self.send_error(404)
            return
        payload = json.dumps(replies[route], ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    print("Synthetic UI preview: http://127.0.0.1:8856", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8856), Handler).serve_forever()

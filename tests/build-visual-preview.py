"""Build a temporary native UI preview using only fictional backend data.

Source files are restored even if the build fails. Rebuild normally before shipping.
This script must be run outside the sandbox, like devecocli build.
"""
import json
from pathlib import Path
import runpy
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
fixtures = runpy.run_path(str(ROOT / "tests/ui-preview-server.py"))
responses = {
    "/api/settings": dict(agent_name="Tentacle", show_reasoning=False, split_messages=True),
    "/api/chat/history": dict(messages=[], has_more=False),
    "/api/chat/commands": dict(commands=[]),
    "/api/configuration": fixtures["snapshot"],
    "/api/plugins": fixtures["plugins_snapshot"],
    "/api/files": dict(files=fixtures["file_records"]),
    "/api/admin/messages": dict(columns=["id", "role", "content"], rows=[], total=0, row_count=0, truncated=False),
}
api = ROOT / "entry/src/main/ets/service/TentacleApi.ets"
index = ROOT / "entry/src/main/ets/pages/Index.ets"
originals = {p: p.read_bytes() for p in (api, index)}
try:
    source = api.read_text(encoding="utf-8")
    marker = "    return new Promise<T>((resolve, reject) => {"
    assert source.count(marker) == 1
    values = {key: json.dumps(value, ensure_ascii=False) for key, value in responses.items()}
    inject = ("    // Temporary synthetic preview. This block is never shipped.\n"
              "    if (path.startsWith('/')) {\n"
              "      const fixtures: Record<string, string> = " + json.dumps(values, ensure_ascii=False) + ";\n"
              "      const reply = fixtures[path.split('?')[0]];\n"
              "      return reply === undefined ? Promise.reject(new Error('Synthetic preview: unsupported route')) : Promise.resolve(JSON.parse(reply) as T);\n"
              "    }\n")
    source = source.replace(marker, inject + marker)
    source = source.replace("  connectWs(): void {", "  connectWs(): void {\n    if (this.serverUrl.length >= 0) { return; } // No real sockets in preview.")
    api.write_text(source, encoding="utf-8", newline="")
    page = index.read_text(encoding="utf-8")
    assert "@State currentView: string = 'chat';" in page
    page = page.replace("@State currentView: string = 'chat';", "@State currentView: string = 'configuration';")
    page = page.replace("this.tryAutoConnect();", "this.tryAutoConnect();")
    # autoConnect needs a URL on a fresh device; init reads preferences but does not overwrite them.
    page = page.replace("    if (!api.hasSavedServer()) {", "    if (false) {")
    # Bypass hasSavedServer's guard in autoConnect without writing settings or credentials.
    source = api.read_text(encoding="utf-8").replace("    if (this.serverUrl.length === 0) {\n      throw new Error('未配置服务器');", "    if (false) {\n      throw new Error('未配置服务器');")
    api.write_text(source, encoding="utf-8", newline="")
    index.write_text(page, encoding="utf-8", newline="")
    result = subprocess.run([shutil.which("devecocli"), "build"], cwd=ROOT, check=False)
    if result.returncode:
        raise SystemExit(result.returncode)
    output = ROOT / ".hvigor/visual-preview"
    output.mkdir(exist_ok=True)
    shutil.copy2(ROOT / "entry/build/default/outputs/default/entry-default-signed.hap", output / "entry-preview-signed.hap")
    print("Synthetic preview built; workspace sources restored in finally.")
finally:
    for filename, content in originals.items():
        filename.write_bytes(content)

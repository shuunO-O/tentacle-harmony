import { TentacleApi } from '../service/TentacleApi';
import { ConfigValue } from '../model/Management';
import {
  LocalPluginItem,
  McpServerConfig,
  McpServerItem,
  PermissionDetail,
  PluginConfigSchemaField,
  PluginDecisionPayload,
  PluginToolRecord,
  PluginsSnapshot,
  clonePluginConfig,
  formatKeyValueLines,
  formatStringListLines,
  parseKeyValueLines,
  parseStringListLines,
  permissionRiskLabel,
  pluginStatusLabel,
  hasLocalPluginDetails,
  pluginSummaryText,
  pluginSchemaFields,
  schemaFieldChoices,
  isPluginEnvReady,
  readPluginDraftValue,
  readPluginNumericText,
  isPluginToolDisabled,
} from '../model/Plugins';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle, StatusPill } from '../components/UiKit';

/** Native Plugins & MCP management page mirroring WebUI /plugins. */
@Component
export struct PluginsPage {
  @State snapshot: PluginsSnapshot | null = null;
  @State loading: boolean = false;
  @State busyKey: string = '';
  @State tab: string = 'local';
  @State message: string = '';
  @State expandedPlugins: string[] = [];
  @State localDrafts: Record<string, Record<string, ConfigValue>> = {};
  @State localNumericInputs: Record<string, Record<string, string>> = {};
  @State disabledDrafts: Record<string, string[]> = {};
  @State envTargetName: string = '';
  @State envSecretValue: string = '';
  @State mcpEditing: boolean = false;
  @State mcpIsEdit: boolean = false;
  @State mcpId: string = '';
  @State mcpEnabled: boolean = true;
  @State mcpTransport: string = 'stdio';
  @State mcpCommand: string = '';
  @State mcpArgsText: string = '';
  @State mcpCwd: string = '';
  @State mcpEnvText: string = '';
  @State mcpEnvSecretsText: string = '';
  @State mcpUrl: string = '';
  @State mcpAuthBearerEnv: string = '';
  @State mcpHeadersText: string = '';
  @State mcpHeaderSecretsText: string = '';
  @State mcpTimeoutSeconds: string = '30';
  @State mcpDisabledToolsText: string = '';
  private visible: boolean = false;
  private timer: number = -1;
  private generation: number = 0;

  aboutToAppear(): void { this.visible = true; this.load(); }

  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private scheduleRestartPoll(data: PluginsSnapshot): void {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    if ((data.restart?.state === 'waiting' || data.restart?.state === 'restarting') && this.visible) {
      this.timer = setTimeout(() => this.load(), 2000);
    }
  }

  private applySnapshot(data: PluginsSnapshot, resetAll: boolean = true, updatedPluginId: string = ''): void {
    this.snapshot = data;
    const nextDrafts: Record<string, Record<string, ConfigValue>> = {};
    const nextNums: Record<string, Record<string, string>> = {};
    const nextDisabled: Record<string, string[]> = {};
    const list = data.plugins ?? [];
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      const keepExisting = !resetAll && item.id !== updatedPluginId && this.localDrafts[item.id] !== undefined;
      if (keepExisting) {
        nextDrafts[item.id] = this.localDrafts[item.id];
        nextNums[item.id] = this.localNumericInputs[item.id] ?? {};
        nextDisabled[item.id] = this.disabledDrafts[item.id] ?? [];
      } else {
        const cfg = clonePluginConfig(item.saved_config ?? item.config);
        nextDrafts[item.id] = cfg;
        const numMap: Record<string, string> = {};
        const schema = item.manifest?.config_schema;
        if (schema) {
          const keys = Object.keys(schema);
          for (let k = 0; k < keys.length; k++) {
            const key = keys[k];
            const spec = schema[key];
            if (spec.type === 'integer' || spec.type === 'number') {
              const rawVal = cfg[key] !== undefined ? cfg[key] : spec.default;
              numMap[key] = rawVal === null || rawVal === undefined ? '' : String(rawVal);
            }
          }
        }
        nextNums[item.id] = numMap;
        const disabled = item.saved_disabled_tools ?? item.disabled_tools ?? [];
        nextDisabled[item.id] = disabled.slice();
      }
    }
    this.localDrafts = nextDrafts;
    this.localNumericInputs = nextNums;
    this.disabledDrafts = nextDisabled;
    this.scheduleRestartPoll(data);
  }

  async load(): Promise<void> {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    const seq = ++this.generation;
    this.loading = true;
    try {
      const data = await TentacleApi.getInstance().getPlugins();
      if (seq !== this.generation || !this.visible) { return; }
      this.applySnapshot(data, true);
      if (data.restart?.state === 'waiting' || data.restart?.state === 'restarting') {
        this.message = '主服务正在等待重启…';
      }
    } catch (e) {
      if (seq === this.generation) { this.message = (e as Error).message; }
    } finally {
      if (seq === this.generation) { this.loading = false; }
    }
  }

  private toggleExpanded(id: string): void {
    this.expandedPlugins = this.expandedPlugins.includes(id)
      ? this.expandedPlugins.filter((item: string) => item !== id)
      : this.expandedPlugins.concat([id]);
  }

  private hasPluginDetails(plugin: LocalPluginItem): boolean {
    return hasLocalPluginDetails(plugin);
  }

  private pluginSummary(plugin: LocalPluginItem): string {
    return pluginSummaryText(plugin);
  }

  private schemaFields(plugin: LocalPluginItem): PluginConfigSchemaField[] {
    return pluginSchemaFields(plugin);
  }

  private draftValue(pluginId: string, field: PluginConfigSchemaField): ConfigValue {
    return readPluginDraftValue(this.localDrafts, pluginId, field);
  }

  private numericText(pluginId: string, field: PluginConfigSchemaField): string {
    return readPluginNumericText(this.localNumericInputs, this.localDrafts, pluginId, field);
  }

  private setLocalConfigValue(pluginId: string, key: string, value: ConfigValue): void {
    const nextAll: Record<string, Record<string, ConfigValue>> = {};
    const ids = Object.keys(this.localDrafts);
    for (let i = 0; i < ids.length; i++) {
      nextAll[ids[i]] = this.localDrafts[ids[i]];
    }
    const nextPlugin = clonePluginConfig(this.localDrafts[pluginId]);
    nextPlugin[key] = value;
    nextAll[pluginId] = nextPlugin;
    this.localDrafts = nextAll;
  }

  private setLocalNumericInput(pluginId: string, key: string, raw: string): void {
    const nextAll: Record<string, Record<string, string>> = {};
    const ids = Object.keys(this.localNumericInputs);
    for (let i = 0; i < ids.length; i++) {
      nextAll[ids[i]] = this.localNumericInputs[ids[i]];
    }
    const cur = this.localNumericInputs[pluginId] ?? {};
    const nextPlugin: Record<string, string> = {};
    const keys = Object.keys(cur);
    for (let i = 0; i < keys.length; i++) {
      nextPlugin[keys[i]] = cur[keys[i]];
    }
    nextPlugin[key] = raw;
    nextAll[pluginId] = nextPlugin;
    this.localNumericInputs = nextAll;
  }

  private isToolDisabled(pluginId: string, tool: PluginToolRecord): boolean {
    return isPluginToolDisabled(this.disabledDrafts, pluginId, tool);
  }

  private toggleLocalTool(pluginId: string, tool: PluginToolRecord, enableTool: boolean): void {
    const current = this.disabledDrafts[pluginId] ?? [];
    const nextList = enableTool
      ? current.filter((x: string) => x !== tool.raw_name && x !== tool.name)
      : (current.includes(tool.raw_name) ? current.slice() : current.concat([tool.raw_name]));
    const nextAll: Record<string, string[]> = {};
    const ids = Object.keys(this.disabledDrafts);
    for (let i = 0; i < ids.length; i++) {
      nextAll[ids[i]] = this.disabledDrafts[ids[i]];
    }
    nextAll[pluginId] = nextList;
    this.disabledDrafts = nextAll;
  }

  private buildResolvedLocalConfig(plugin: LocalPluginItem): Record<string, ConfigValue> {
    const cfg = clonePluginConfig(this.localDrafts[plugin.id]);
    const fields = this.schemaFields(plugin);
    const numMap = this.localNumericInputs[plugin.id] ?? {};
    for (let i = 0; i < fields.length; i++) {
      const field = fields[i];
      if (field.type === 'integer' || field.type === 'number') {
        const rawText = numMap[field.key] !== undefined ? numMap[field.key].trim() :
          (cfg[field.key] === null || cfg[field.key] === undefined ? '' : String(cfg[field.key]));
        if (rawText.length === 0) {
          if (field.nullable) { cfg[field.key] = null; }
          else { throw new Error(field.label + '不能为空'); }
        } else {
          const parsed = Number(rawText);
          if (!Number.isFinite(parsed) || (field.type === 'integer' && !Number.isInteger(parsed))) {
            throw new Error(field.label + (field.type === 'integer' ? '需要整数' : '需要有效数值'));
          }
          cfg[field.key] = parsed;
        }
      }
    }
    return cfg;
  }

  async decideLocal(plugin: LocalPluginItem, enabled: boolean): Promise<void> {
    if (this.snapshot === null || this.busyKey.length > 0) { return; }
    this.busyKey = 'local:' + plugin.id;
    this.message = '';
    try {
      const resolvedCfg = this.buildResolvedLocalConfig(plugin);
      const body: PluginDecisionPayload = {
        revision: this.snapshot.revision,
        enabled: enabled,
        trusted: enabled ? true : (plugin.saved_trusted ?? plugin.trusted),
        config: resolvedCfg,
        disabled_tools: (this.disabledDrafts[plugin.id] ?? []).slice(),
      };
      const updated = await TentacleApi.getInstance().decideLocalPlugin(plugin.id, body);
      this.applySnapshot(updated, false, plugin.id);
      this.message = enabled ? '已保存并批准启用 ' + plugin.id + '（需重启生效）' : '已保存 ' + plugin.id + '（需重启生效）';
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busyKey = '';
    }
  }

  async deleteLocal(pluginId: string): Promise<void> {
    if (this.snapshot === null || this.busyKey.length > 0) { return; }
    this.busyKey = 'del-local:' + pluginId;
    this.message = '';
    try {
      const updated = await TentacleApi.getInstance().deleteLocalPlugin(pluginId, this.snapshot.revision, true);
      this.applySnapshot(updated, false, pluginId);
      this.message = '已移除插件 ' + pluginId;
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busyKey = '';
    }
  }

  private confirmDeleteLocal(plugin: LocalPluginItem): void {
    AlertDialog.show({
      message: '确定卸载并删除本地插件「' + plugin.id + '」？',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => { this.deleteLocal(plugin.id); } },
    });
  }

  openEnvModal(name: string): void {
    this.envTargetName = name;
    this.envSecretValue = '';
    this.message = '';
  }

  cancelEnvModal(): void {
    this.envTargetName = '';
    this.envSecretValue = '';
  }

  async saveEnvSecret(): Promise<void> {
    if (!this.envTargetName || this.busyKey.length > 0) { return; }
    if (!this.envSecretValue.trim()) {
      this.message = '请输入有效的环境变量值';
      return;
    }
    const name = this.envTargetName;
    const value = this.envSecretValue;
    this.envSecretValue = '';
    this.busyKey = 'env:' + name;
    this.message = '';
    let savedOk = false;
    try {
      await TentacleApi.getInstance().writePluginEnv(name, value);
      this.cancelEnvModal();
      savedOk = true;
      this.message = '已将 ' + name + ' 安全写入 .env';
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busyKey = '';
    }
    if (savedOk) { await this.load(); }
  }

  openNewMcp(): void {
    this.mcpIsEdit = false;
    this.mcpId = '';
    this.mcpEnabled = true;
    this.mcpTransport = 'stdio';
    this.mcpCommand = '';
    this.mcpArgsText = '';
    this.mcpCwd = '';
    this.mcpEnvText = '';
    this.mcpEnvSecretsText = '';
    this.mcpUrl = '';
    this.mcpAuthBearerEnv = '';
    this.mcpHeadersText = '';
    this.mcpHeaderSecretsText = '';
    this.mcpTimeoutSeconds = '30';
    this.mcpDisabledToolsText = '';
    this.mcpEditing = true;
    this.message = '';
  }

  openEditMcp(srv: McpServerItem): void {
    const raw = srv.saved_config ?? srv.mcp_config;
    this.mcpIsEdit = true;
    this.mcpId = srv.id;
    this.mcpEnabled = raw ? raw.enabled : srv.enabled;
    this.mcpTransport = raw?.transport === 'streamable_http' ? 'streamable_http' : 'stdio';
    this.mcpCommand = raw?.command ?? '';
    this.mcpArgsText = Array.isArray(raw?.args) ? (raw?.args as string[]).join('\n') : '';
    this.mcpCwd = raw?.cwd ?? '';
    this.mcpEnvText = formatKeyValueLines(raw?.env);
    this.mcpEnvSecretsText = formatKeyValueLines(raw?.env_secrets);
    this.mcpUrl = raw?.url ?? '';
    this.mcpAuthBearerEnv = raw?.auth_bearer_env ?? '';
    this.mcpHeadersText = formatKeyValueLines(raw?.headers);
    this.mcpHeaderSecretsText = formatKeyValueLines(raw?.header_secrets);
    this.mcpTimeoutSeconds = raw?.timeout_seconds !== undefined ? String(raw.timeout_seconds) : '30';
    this.mcpDisabledToolsText = Array.isArray(raw?.disabled_tools) ? (raw?.disabled_tools as string[]).join(', ') : '';
    this.mcpEditing = true;
    this.message = '';
  }

  cancelMcp(): void { this.mcpEditing = false; }

  private parseDisabledToolsInput(raw: string): string[] {
    const parts = raw.split(/[,\n]/);
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const trimmed = parts[i].trim();
      if (trimmed.length > 0 && !out.includes(trimmed)) { out.push(trimmed); }
    }
    return out;
  }

  private buildMcpPayload(): McpServerConfig {
    const timeout = Number(this.mcpTimeoutSeconds.trim() || '30');
    if (!Number.isFinite(timeout) || timeout < 0.5 || timeout > 600) {
      throw new Error('超时秒数须在 0.5 到 600 之间');
    }
    const disabledTools = this.parseDisabledToolsInput(this.mcpDisabledToolsText);
    if (this.mcpTransport === 'stdio') {
      const cfg: McpServerConfig = {
        enabled: this.mcpEnabled,
        trusted: true,
        transport: 'stdio',
        command: this.mcpCommand.trim(),
        args: parseStringListLines(this.mcpArgsText),
        env: parseKeyValueLines(this.mcpEnvText),
        env_secrets: parseKeyValueLines(this.mcpEnvSecretsText),
        timeout_seconds: timeout,
        disabled_tools: disabledTools,
      };
      if (this.mcpCwd.trim().length > 0) { cfg.cwd = this.mcpCwd.trim(); }
      return cfg;
    }
    const httpCfg: McpServerConfig = {
      enabled: this.mcpEnabled,
      trusted: true,
      transport: 'streamable_http',
      url: this.mcpUrl.trim(),
      headers: parseKeyValueLines(this.mcpHeadersText),
      header_secrets: parseKeyValueLines(this.mcpHeaderSecretsText),
      timeout_seconds: timeout,
      disabled_tools: disabledTools,
    };
    if (this.mcpAuthBearerEnv.trim().length > 0) { httpCfg.auth_bearer_env = this.mcpAuthBearerEnv.trim(); }
    return httpCfg;
  }

  async saveMcp(): Promise<void> {
    if (this.snapshot === null || this.busyKey.length > 0) { return; }
    const serverId = this.mcpId.trim();
    if (!serverId) {
      this.message = '请填写 MCP 服务 ID';
      return;
    }
    this.busyKey = 'mcp-save:' + serverId;
    this.message = '';
    try {
      const configPayload = this.buildMcpPayload();
      const updated = await TentacleApi.getInstance().upsertMcpServer(serverId, this.snapshot.revision, configPayload);
      this.applySnapshot(updated, false);
      this.mcpEditing = false;
      this.message = 'MCP 服务 ' + serverId + ' 已保存，可点击「立即重连」使其立即生效';
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busyKey = '';
    }
  }

  async toggleMcp(srv: McpServerItem, enabled: boolean): Promise<void> {
    if (this.snapshot === null || this.busyKey.length > 0) { return; }
    const raw = srv.saved_config ?? srv.mcp_config;
    const nextCfg: McpServerConfig = {
      enabled: enabled,
      trusted: true,
      transport: raw?.transport ?? srv.transport ?? 'stdio',
      command: raw?.command,
      args: raw?.args ? raw.args.slice() : undefined,
      cwd: raw?.cwd,
      env: raw?.env,
      env_secrets: raw?.env_secrets,
      url: raw?.url,
      headers: raw?.headers,
      header_secrets: raw?.header_secrets,
      auth_bearer_env: raw?.auth_bearer_env,
      timeout_seconds: raw?.timeout_seconds,
      disabled_tools: raw?.disabled_tools ? raw.disabled_tools.slice() : undefined,
    };
    this.busyKey = 'mcp-toggle:' + srv.id;
    this.message = '';
    try {
      const updated = await TentacleApi.getInstance().upsertMcpServer(srv.id, this.snapshot.revision, nextCfg);
      this.applySnapshot(updated, false);
      const reconnected = await TentacleApi.getInstance().reconnectMcpServer(srv.id);
      this.applySnapshot(reconnected, false);
      this.message = enabled ? 'MCP 服务 ' + srv.id + ' 已连接' : 'MCP 服务 ' + srv.id + ' 已停用';
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busyKey = '';
    }
  }

  async reconnectMcp(serverId: string): Promise<void> {
    if (this.busyKey.length > 0) { return; }
    this.busyKey = 'mcp-reconn:' + serverId;
    this.message = '';
    try {
      const updated = await TentacleApi.getInstance().reconnectMcpServer(serverId);
      this.applySnapshot(updated, false);
      this.message = 'MCP 服务 ' + serverId + ' 重连完成';
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busyKey = '';
    }
  }

  async deleteMcp(serverId: string): Promise<void> {
    if (this.snapshot === null || this.busyKey.length > 0) { return; }
    this.busyKey = 'mcp-del:' + serverId;
    this.message = '';
    try {
      const updated = await TentacleApi.getInstance().deleteMcpServer(serverId, this.snapshot.revision);
      this.applySnapshot(updated, false);
      this.message = '已删除 MCP 服务 ' + serverId;
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busyKey = '';
    }
  }

  private confirmDeleteMcp(srv: McpServerItem): void {
    AlertDialog.show({
      message: '确定删除 MCP 服务「' + srv.id + '」？',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => { this.deleteMcp(srv.id); } },
    });
  }

  async performRestart(): Promise<void> {
    if (this.snapshot === null || this.busyKey.length > 0) { return; }
    this.busyKey = 'restart';
    this.message = '';
    let requested = false;
    try {
      await TentacleApi.getInstance().restartAfterPluginChange(this.snapshot.revision);
      this.message = '重启指令已触发，服务恢复后将自动重新连接';
      requested = true;
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busyKey = '';
    }
    if (requested) { await this.load(); }
  }

  private confirmRestart(): void {
    AlertDialog.show({
      message: '重启后端应用以使插件或环境变量变更生效？服务会等待当前对话完成，期间可能暂时断开连接。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '重启', action: () => { this.performRestart(); } },
    });
  }

  private schemaChoices(field: PluginConfigSchemaField): string[] {
    return schemaFieldChoices(field);
  }

  private selectOptions(values: string[]): SelectOption[] {
    return values.map((v: string): SelectOption => ({ value: v }));
  }

  private envReady(envStatus: Record<string, boolean> | undefined, missingEnv: string[] | undefined, varName: string): boolean {
    return isPluginEnvReady(envStatus, missingEnv, varName);
  }

  @Builder
  EnvEditorPanel() {
    AppCard() {
      Column({ space: 12 }) {
        SectionTitle({ title: '安全录入环境变量：' + this.envTargetName })
        Text('值仅写入本地 .env 文件并同步当前环境变量，绝不写入 config.yaml 或回显到界面。')
          .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        TextInput({ text: this.envSecretValue, placeholder: '请输入密钥值（提交后不回显）' })
          .type(InputType.Password)
          .fontSize(14).fontColor($r('app.color.tentacle_text'))
          .backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).width('100%')
          .onChange((v: string) => this.envSecretValue = v)
        Row({ space: 8 }) {
          ActionButton({ label: '取消', tone: 'secondary', compact: true, isEnabled: this.busyKey.length === 0,
            onTap: () => { this.cancelEnvModal(); } })
          ActionButton({ label: '保存到 .env', tone: 'primary', compact: true,
            isEnabled: this.busyKey.length === 0 && this.envSecretValue.trim().length > 0,
            onTap: () => { this.saveEnvSecret(); } })
        }.width('100%')
      }.width('100%')
    }
  }

  @Builder
  McpEditorPanel() {
    AppCard() {
      Column({ space: 10 }) {
        SectionTitle({ title: this.mcpIsEdit ? '编辑 MCP 服务：' + this.mcpId : '添加 MCP 服务' })
        Text('支持 stdio 子进程与 Streamable HTTP。敏感凭据请引用 .env 变量名。')
          .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        Text('服务 ID').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        TextInput({ text: this.mcpId, placeholder: '如 github / filesystem' })
          .enabled(!this.mcpIsEdit && this.busyKey.length === 0)
          .fontSize(14).fontColor($r('app.color.tentacle_text'))
          .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
          .onChange((v: string) => this.mcpId = v)
        Text('传输类型').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        Select([{ value: 'stdio' }, { value: 'streamable_http' }])
          .value(this.mcpTransport)
          .font({ size: 14 }).fontColor($r('app.color.tentacle_text'))
          .backgroundColor($r('app.color.tentacle_bg_input')).width('100%')
          .onSelect((i: number) => { this.mcpTransport = i === 1 ? 'streamable_http' : 'stdio'; })

        if (this.mcpTransport === 'stdio') {
          Text('启动命令 (command)').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextInput({ text: this.mcpCommand, placeholder: '如 npx / uvx / python' })
            .fontSize(14).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
            .onChange((v: string) => this.mcpCommand = v)
          Text('参数（每行一个）').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextArea({ text: this.mcpArgsText, placeholder: '-y\n@modelcontextprotocol/server-filesystem' })
            .fontSize(13).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).height(84).width('100%')
            .onChange((v: string) => this.mcpArgsText = v)
          Text('工作目录 cwd（可选）').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextInput({ text: this.mcpCwd, placeholder: '留空使用默认工作目录' })
            .fontSize(14).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
            .onChange((v: string) => this.mcpCwd = v)
          Text('密钥环境变量映射（TARGET_VAR=HOST_ENV_VAR，每行一个）')
            .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextArea({ text: this.mcpEnvSecretsText, placeholder: 'GITHUB_PERSONAL_ACCESS_TOKEN=GITHUB_TOKEN' })
            .fontSize(13).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).height(76).width('100%')
            .onChange((v: string) => this.mcpEnvSecretsText = v)
          Text('普通环境变量（KEY=VALUE，每行一个，可选）')
            .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextArea({ text: this.mcpEnvText, placeholder: 'KEY=VALUE' })
            .fontSize(13).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).height(76).width('100%')
            .onChange((v: string) => this.mcpEnvText = v)
        } else {
          Text('服务 URL').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextInput({ text: this.mcpUrl, placeholder: 'https://example.com/mcp' })
            .fontSize(14).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
            .onChange((v: string) => this.mcpUrl = v)
          Text('Bearer Token 环境变量名（可选）').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextInput({ text: this.mcpAuthBearerEnv, placeholder: '如 MCP_API_TOKEN' })
            .fontSize(14).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
            .onChange((v: string) => this.mcpAuthBearerEnv = v)
          Text('密钥 HTTP 头映射（Header=HOST_ENV_VAR，每行一个）')
            .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextArea({ text: this.mcpHeaderSecretsText, placeholder: 'X-API-Key=HOST_KEY_ENV' })
            .fontSize(13).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).height(76).width('100%')
            .onChange((v: string) => this.mcpHeaderSecretsText = v)
          Text('普通 HTTP 头（Header=VALUE，每行一个，可选）')
            .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          TextArea({ text: this.mcpHeadersText, placeholder: 'X-Client=tentacle' })
            .fontSize(13).fontColor($r('app.color.tentacle_text'))
            .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).height(76).width('100%')
            .onChange((v: string) => this.mcpHeadersText = v)
        }

        Text('超时秒数').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        TextInput({ text: this.mcpTimeoutSeconds, placeholder: '30' })
          .fontSize(14).fontColor($r('app.color.tentacle_text'))
          .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
          .onChange((v: string) => this.mcpTimeoutSeconds = v)
        Text('禁用工具（逗号或换行分隔，可选）').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        TextInput({ text: this.mcpDisabledToolsText, placeholder: 'tool_a, tool_b' })
          .fontSize(14).fontColor($r('app.color.tentacle_text'))
          .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
          .onChange((v: string) => this.mcpDisabledToolsText = v)
        Row() {
          Text('保存后立即标记为启用').fontSize(13).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.mcpEnabled })
            .selectedColor($r('app.color.tentacle_accent'))
            .onChange((on: boolean) => this.mcpEnabled = on)
        }.width('100%')
        Row({ space: 8 }) {
          ActionButton({ label: '取消', tone: 'secondary', compact: true, isEnabled: this.busyKey.length === 0,
            onTap: () => { this.cancelMcp(); } })
          ActionButton({ label: '保存 MCP 配置', tone: 'primary', compact: true, isEnabled: this.busyKey.length === 0,
            onTap: () => { this.saveMcp(); } })
        }.width('100%')
      }.width('100%')
    }
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text(this.snapshot === null ? '正在加载插件列表…'
          : '本地 ' + this.snapshot.plugins.length.toString() + ' · MCP ' + this.snapshot.mcp_servers.length.toString())
          .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).layoutWeight(1)
        if (this.snapshot?.restart_required && this.snapshot?.restart?.available !== false) {
          ActionButton({ label: '重启应用…', tone: 'primary', compact: true, isEnabled: this.busyKey.length === 0,
            onTap: () => { this.confirmRestart(); } })
        }
        ActionButton({
          label: this.loading ? '刷新中…' : '刷新',
          tone: 'secondary',
          compact: true,
          isEnabled: !this.loading && this.busyKey.length === 0,
          onTap: () => { this.load(); }
        })
      }.width('100%').padding({ left: 14, right: 14, top: 4, bottom: 8 })

      if (this.snapshot?.restart_required) {
        Text('检测到本地插件开关、配置或环境变量有未生效改动；本地插件与环境变更需重启主进程生效（MCP 支持立即重连）。')
          .fontSize(11).fontColor($r('app.color.tentacle_accent')).width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 8 })
          .backgroundColor($r('app.color.tentacle_accent_soft'))
      }

      Row() {
        ForEach(['local', 'mcp'], (key: string) => {
          Column({ space: 10 }) {
            Text(key === 'local'
              ? '本地插件 (' + (this.snapshot?.plugins.length ?? 0).toString() + ')'
              : 'MCP 服务 (' + (this.snapshot?.mcp_servers.length ?? 0).toString() + ')')
              .fontSize(13)
              .fontWeight(this.tab === key ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.tab === key ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text_dim'))
            Column().height(2).width('100%')
              .backgroundColor(this.tab === key ? $r('app.color.tentacle_accent') : Color.Transparent)
          }.layoutWeight(1).onClick(() => {
            if (!this.envTargetName && !this.mcpEditing) { this.tab = key; }
          })
        }, (key: string) => key)
      }.width('100%').padding({ left: 18, right: 18 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.message) {
            FeedbackBanner({ text: this.message, tone: 'info' })
          }
          if (this.snapshot === null) {
            LoadingProgress().width(28).height(28).color($r('app.color.tentacle_accent')).margin({ top: 36 })
          } else if (this.envTargetName) {
            this.EnvEditorPanel()
          } else if (this.mcpEditing) {
            this.McpEditorPanel()
          } else if (this.tab === 'local') {
            if (this.snapshot.plugins.length === 0) {
              AppCard() {
                Column({ space: 6 }) {
                  Text('当前尚未安装本地插件').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text'))
                  Text('可通过主 Agent 工具暂存插件，或将包含 manifest.yaml 的插件目录放入 TENTACLE_HOME/plugins/。')
                    .fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
                }.width('100%').alignItems(HorizontalAlign.Start)
              }
            } else {
              ForEach(this.snapshot.plugins, (plugin: LocalPluginItem) => {
                LocalPluginCardView({
                  plugin: plugin,
                  expanded: this.expandedPlugins.includes(plugin.id),
                  busy: this.busyKey.length > 0,
                  localDrafts: $localDrafts,
                  localNumericInputs: $localNumericInputs,
                  disabledDrafts: $disabledDrafts,
                  onDecide: (p: LocalPluginItem, en: boolean) => { this.decideLocal(p, en); },
                  onToggleExpand: (id: string) => { this.toggleExpanded(id); },
                  onDelete: (p: LocalPluginItem) => { this.confirmDeleteLocal(p); },
                  onOpenEnv: (name: string) => { this.openEnvModal(name); },
                  onSetConfig: (id: string, key: string, v: ConfigValue) => { this.setLocalConfigValue(id, key, v); },
                  onSetNumeric: (id: string, key: string, raw: string) => { this.setLocalNumericInput(id, key, raw); },
                  onToggleTool: (id: string, t: PluginToolRecord, on: boolean) => { this.toggleLocalTool(id, t, on); }
                })
              }, (plugin: LocalPluginItem) => plugin.id)
            }
          } else {
            Row() {
              Blank()
              ActionButton({ label: '添加 MCP 服务', tone: 'primary', compact: true, isEnabled: this.busyKey.length === 0,
                onTap: () => { this.openNewMcp(); } })
            }.width('100%')
            if (this.snapshot.mcp_servers.length === 0) {
              AppCard() {
                Column({ space: 6 }) {
                  Text('当前尚未配置外部 MCP 服务').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text'))
                  Text('点击右上角「添加 MCP 服务」，可通过 stdio 或 Streamable HTTP 挂载外部工具集。')
                    .fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
                }.width('100%').alignItems(HorizontalAlign.Start)
              }
            } else {
              ForEach(this.snapshot.mcp_servers, (srv: McpServerItem) => {
                McpServerCardView({
                  srv: srv,
                  busy: this.busyKey.length > 0,
                  onToggle: (s: McpServerItem, on: boolean) => { this.toggleMcp(s, on); },
                  onReconnect: (id: string) => { this.reconnectMcp(id); },
                  onEdit: (s: McpServerItem) => { this.openEditMcp(s); },
                  onDelete: (s: McpServerItem) => { this.confirmDeleteMcp(s); },
                  onOpenEnv: (name: string) => { this.openEnvModal(name); }
                })
              }, (srv: McpServerItem) => srv.id)
            }
          }
        }.width('100%').padding({ left: 18, right: 18, top: 14, bottom: 24 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor($r('app.color.tentacle_bg'))
  }
}

@Component
struct PluginEnvVarList {
  @Prop envVars: string[] = [];
  @Prop envStatus: Record<string, boolean> | undefined = undefined;
  @Prop missingEnv: string[] | undefined = undefined;
  @Prop busy: boolean = false;
  onOpenEnv: (varName: string) => void = () => {};

  build() {
    Column({ space: 8 }) {
      Text('环境变量 / 凭据（只写入 .env，不进对话与日志）')
        .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
      ForEach(this.envVars, (varName: string) => {
        Row({ space: 8 }) {
          Text(varName).fontSize(12).fontFamily('monospace').fontColor($r('app.color.tentacle_text')).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          StatusPill({
            label: isPluginEnvReady(this.envStatus, this.missingEnv, varName) ? '已配置' : '缺失',
            tone: isPluginEnvReady(this.envStatus, this.missingEnv, varName) ? 'ok' : 'danger'
          })
          ActionButton({
            label: isPluginEnvReady(this.envStatus, this.missingEnv, varName) ? '更新' : '录入',
            tone: 'secondary',
            compact: true,
            isEnabled: !this.busy,
            onTap: () => { this.onOpenEnv(varName); }
          })
        }.width('100%').padding(8).backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10)
      }, (varName: string) => varName)
    }.width('100%').padding(10).backgroundColor($r('app.color.tentacle_bg_elevated')).borderRadius(12)
  }
}

@Component
struct LocalPluginCardView {
  @Prop plugin: LocalPluginItem = { id: '', kind: 'local', enabled: false, trusted: false, status: 'disabled' };
  @Prop expanded: boolean = false;
  @Prop busy: boolean = false;
  @Link localDrafts: Record<string, Record<string, ConfigValue>>;
  @Link localNumericInputs: Record<string, Record<string, string>>;
  @Link disabledDrafts: Record<string, string[]>;
  onDecide: (plugin: LocalPluginItem, enabled: boolean) => void = () => {};
  onToggleExpand: (id: string) => void = () => {};
  onDelete: (plugin: LocalPluginItem) => void = () => {};
  onOpenEnv: (name: string) => void = () => {};
  onSetConfig: (id: string, key: string, v: ConfigValue) => void = () => {};
  onSetNumeric: (id: string, key: string, raw: string) => void = () => {};
  onToggleTool: (id: string, tool: PluginToolRecord, enableTool: boolean) => void = () => {};

  private selectOptions(values: string[]): SelectOption[] {
    return values.map((v: string): SelectOption => ({ value: v }));
  }

  build() {
    AppCard() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text(this.plugin.manifest?.name || this.plugin.id)
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
            Text(this.plugin.id + '@' + (this.plugin.manifest?.version || '?'))
              .fontSize(11).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint')).width('100%')
          }.layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.plugin.saved_enabled ?? this.plugin.enabled })
            .selectedColor($r('app.color.tentacle_accent'))
            .enabled(!this.busy)
            .onChange((on: boolean) => {
              const cur = this.plugin.saved_enabled ?? this.plugin.enabled;
              if (on !== cur && !this.busy) { this.onDecide(this.plugin, on); }
            })
        }.width('100%')

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          if (this.plugin.bundled) {
            Row() { StatusPill({ label: '内置插件', tone: 'accent' }) }.margin({ right: 6, bottom: 4 })
          }
          Row() {
            StatusPill({
              label: pluginStatusLabel(this.plugin.status),
              tone: this.plugin.status === 'active' ? 'ok' : this.plugin.status === 'degraded' ? 'danger' : 'accent'
            })
          }.margin({ right: 6, bottom: 4 })
          if ((this.plugin.missing_env?.length ?? 0) > 0) {
            Row() {
              StatusPill({ label: '缺失凭据 (' + (this.plugin.missing_env?.length ?? 0).toString() + ')', tone: 'danger' })
            }.margin({ right: 6, bottom: 4 })
          }
          if (this.plugin.pending_restart) {
            Row() { StatusPill({ label: '待重启生效', tone: 'accent' }) }.margin({ right: 6, bottom: 4 })
          }
        }.width('100%')

        if (this.plugin.manifest?.description) {
          Text(this.plugin.manifest.description).fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        }
        if (!this.expanded && pluginSummaryText(this.plugin).length > 0) {
          Text(pluginSummaryText(this.plugin)).fontSize(11).fontColor($r('app.color.tentacle_text_faint')).width('100%')
        }

        Row({ space: 8 }) {
          if (this.plugin.status === 'pending') {
            ActionButton({ label: '批准并启用', tone: 'primary', compact: true, isEnabled: !this.busy,
              onTap: () => { this.onDecide(this.plugin, true); } })
          }
          if (hasLocalPluginDetails(this.plugin)) {
            ActionButton({ label: this.expanded ? '收起配置' : '展开配置', tone: 'secondary', compact: true,
              isEnabled: !this.busy, onTap: () => { this.onToggleExpand(this.plugin.id); } })
          }
          if (!this.plugin.bundled) {
            ActionButton({ label: '卸载', tone: 'danger', compact: true, isEnabled: !this.busy,
              onTap: () => { this.onDelete(this.plugin); } })
          }
        }.width('100%')

        if (this.plugin.error) {
          Text(this.plugin.error).fontSize(12).fontColor($r('app.color.tentacle_danger'))
            .width('100%').padding(8).backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(8)
        }

        if (this.expanded) {
          Divider().color($r('app.color.tentacle_border'))
          if ((this.plugin.permission_details?.length ?? 0) > 0) {
            Column({ space: 6 }) {
              Text('申请权限 (' + (this.plugin.permission_details?.length ?? 0).toString() + ')')
                .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
              ForEach(this.plugin.permission_details ?? [], (perm: PermissionDetail) => {
                Row({ space: 6 }) {
                  StatusPill({
                    label: permissionRiskLabel(perm.level),
                    tone: perm.level === 'high' ? 'danger' : perm.level === 'medium' ? 'accent' : 'default'
                  })
                  Text(perm.permission + ' · ' + perm.summary)
                    .fontSize(11).fontColor($r('app.color.tentacle_text_dim')).layoutWeight(1)
                }.width('100%')
              }, (perm: PermissionDetail) => perm.permission)
            }.width('100%').padding(10).backgroundColor($r('app.color.tentacle_bg_elevated')).borderRadius(12)
          }

          if ((this.plugin.env_vars?.length ?? 0) > 0) {
            PluginEnvVarList({
              envVars: this.plugin.env_vars ?? [],
              envStatus: this.plugin.env_status,
              missingEnv: this.plugin.missing_env,
              busy: this.busy,
              onOpenEnv: (name: string) => { this.onOpenEnv(name); }
            })
          }

          if (pluginSchemaFields(this.plugin).length > 0) {
            Column({ space: 10 }) {
              Text('插件配置项').fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
              ForEach(pluginSchemaFields(this.plugin), (field: PluginConfigSchemaField) => {
                Column({ space: 6 }) {
                  Row({ space: 6 }) {
                    Text(field.label).fontSize(13).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
                    Text(field.key).fontSize(10).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint'))
                  }.width('100%')
                  if (field.type === 'boolean') {
                    Toggle({
                      type: ToggleType.Switch,
                      isOn: readPluginDraftValue(this.localDrafts, this.plugin.id, field) === true
                    })
                      .selectedColor($r('app.color.tentacle_accent'))
                      .enabled(!this.busy)
                      .onChange((on: boolean) => {
                        if (on !== (readPluginDraftValue(this.localDrafts, this.plugin.id, field) === true)) {
                          this.onSetConfig(this.plugin.id, field.key, on);
                        }
                      })
                  } else if (schemaFieldChoices(field).length > 0) {
                    Select(this.selectOptions(schemaFieldChoices(field)))
                      .value(String(readPluginDraftValue(this.localDrafts, this.plugin.id, field) ?? ''))
                      .font({ size: 13 }).fontColor($r('app.color.tentacle_text'))
                      .backgroundColor($r('app.color.tentacle_bg_input')).width('100%')
                      .enabled(!this.busy)
                      .onSelect((idx: number) => {
                        const raw = schemaFieldChoices(field)[idx];
                        if (raw === undefined || raw === String(readPluginDraftValue(this.localDrafts, this.plugin.id, field) ?? '')) {
                          return;
                        }
                        const parsed: ConfigValue = (field.type === 'integer' || field.type === 'number') && raw !== ''
                          ? Number(raw) : raw;
                        this.onSetConfig(this.plugin.id, field.key, parsed);
                      })
                  } else if (field.type === 'string_list') {
                    TextArea({
                      text: formatStringListLines(readPluginDraftValue(this.localDrafts, this.plugin.id, field)),
                      placeholder: '每行填写一项'
                    })
                      .fontSize(13).fontColor($r('app.color.tentacle_text'))
                      .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).height(84).width('100%')
                      .enabled(!this.busy)
                      .onChange((v: string) => {
                        const cur = readPluginDraftValue(this.localDrafts, this.plugin.id, field);
                        if (v === formatStringListLines(cur)) { return; }
                        const parsed = parseStringListLines(v);
                        if (JSON.stringify(parsed) !== JSON.stringify(Array.isArray(cur) ? cur : [])) {
                          this.onSetConfig(this.plugin.id, field.key, parsed);
                        }
                      })
                  } else if (field.type === 'integer' || field.type === 'number') {
                    TextInput({
                      text: readPluginNumericText(this.localNumericInputs, this.localDrafts, this.plugin.id, field),
                      placeholder: field.help || ''
                    })
                      .fontSize(13).fontColor($r('app.color.tentacle_text'))
                      .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
                      .enabled(!this.busy)
                      .onChange((v: string) => {
                        if (v !== readPluginNumericText(this.localNumericInputs, this.localDrafts, this.plugin.id, field)) {
                          this.onSetNumeric(this.plugin.id, field.key, v);
                        }
                      })
                  } else if (field.multiline) {
                    TextArea({
                      text: String(readPluginDraftValue(this.localDrafts, this.plugin.id, field) ?? ''),
                      placeholder: field.help || ''
                    })
                      .fontSize(13).fontColor($r('app.color.tentacle_text'))
                      .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).height(84).width('100%')
                      .enabled(!this.busy)
                      .onChange((v: string) => {
                        if (v !== String(readPluginDraftValue(this.localDrafts, this.plugin.id, field) ?? '')) {
                          this.onSetConfig(this.plugin.id, field.key, v);
                        }
                      })
                  } else {
                    TextInput({
                      text: String(readPluginDraftValue(this.localDrafts, this.plugin.id, field) ?? ''),
                      placeholder: field.help || ''
                    })
                      .fontSize(13).fontColor($r('app.color.tentacle_text'))
                      .backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10).width('100%')
                      .enabled(!this.busy)
                      .onChange((v: string) => {
                        if (v !== String(readPluginDraftValue(this.localDrafts, this.plugin.id, field) ?? '')) {
                          this.onSetConfig(this.plugin.id, field.key, v);
                        }
                      })
                  }
                  if (field.help) {
                    Text(field.help).fontSize(11).fontColor($r('app.color.tentacle_text_faint')).width('100%')
                  }
                }.width('100%').alignItems(HorizontalAlign.Start)
              }, (field: PluginConfigSchemaField) => field.key)
            }.width('100%').padding(10).backgroundColor($r('app.color.tentacle_bg_elevated')).borderRadius(12)
          }

          if ((this.plugin.tools?.length ?? 0) > 0) {
            Column({ space: 6 }) {
              Text('注册工具 (' + (this.plugin.tools?.length ?? 0).toString() + ')')
                .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
              ForEach(this.plugin.tools ?? [], (tool: PluginToolRecord) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(tool.name).fontSize(12).fontFamily('monospace').fontColor($r('app.color.tentacle_text')).width('100%')
                    if (tool.description) {
                      Text(tool.description).fontSize(11).fontColor($r('app.color.tentacle_text_faint')).maxLines(2).width('100%')
                    }
                  }.layoutWeight(1)
                  Toggle({ type: ToggleType.Checkbox, isOn: !isPluginToolDisabled(this.disabledDrafts, this.plugin.id, tool) })
                    .selectedColor($r('app.color.tentacle_accent'))
                    .enabled(!this.busy)
                    .onChange((on: boolean) => {
                      if (on !== !isPluginToolDisabled(this.disabledDrafts, this.plugin.id, tool)) {
                        this.onToggleTool(this.plugin.id, tool, on);
                      }
                    })
                }.width('100%').padding({ top: 4, bottom: 4 })
              }, (tool: PluginToolRecord) => tool.name)
            }.width('100%').padding(10).backgroundColor($r('app.color.tentacle_bg_elevated')).borderRadius(12)
          }

          if ((this.plugin.commands?.length ?? 0) > 0) {
            Text('命令: ' + (this.plugin.commands ?? []).map((c: string) => '/' + c).join(', '))
              .fontSize(11).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          }
          if ((this.plugin.skills?.length ?? 0) > 0) {
            Text('Skills: ' + (this.plugin.skills ?? []).join(', '))
              .fontSize(11).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          }
          if ((this.plugin.channels?.length ?? 0) > 0) {
            Text('通道: ' + (this.plugin.channels ?? []).join(', '))
              .fontSize(11).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          }
          if ((this.plugin.routes?.length ?? 0) > 0) {
            Text('路由: ' + (this.plugin.routes ?? []).join(', '))
              .fontSize(11).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          }

          ActionButton({
            label: '保存配置',
            tone: 'primary',
            compact: true,
            isEnabled: !this.busy,
            onTap: () => { this.onDecide(this.plugin, this.plugin.saved_enabled ?? this.plugin.enabled); }
          })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}

@Component
struct McpServerCardView {
  @Prop srv: McpServerItem = { id: '', kind: 'mcp', enabled: false, trusted: false, status: 'disabled' };
  @Prop busy: boolean = false;
  onToggle: (srv: McpServerItem, enabled: boolean) => void = () => {};
  onReconnect: (id: string) => void = () => {};
  onEdit: (srv: McpServerItem) => void = () => {};
  onDelete: (srv: McpServerItem) => void = () => {};
  onOpenEnv: (name: string) => void = () => {};

  build() {
    AppCard() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text(this.srv.id).fontSize(15).fontFamily('monospace').fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.tentacle_text')).width('100%')
            Row({ space: 6 }) {
              StatusPill({ label: this.srv.transport || 'stdio', tone: 'default' })
              StatusPill({
                label: pluginStatusLabel(this.srv.status),
                tone: this.srv.status === 'active' ? 'ok' : this.srv.status === 'degraded' ? 'danger' : 'accent'
              })
              if (this.srv.pending_restart) { StatusPill({ label: '待重启生效', tone: 'accent' }) }
            }.width('100%')
          }.layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.srv.enabled })
            .selectedColor($r('app.color.tentacle_accent'))
            .enabled(!this.busy)
            .onChange((on: boolean) => {
              if (on !== this.srv.enabled && !this.busy) { this.onToggle(this.srv, on); }
            })
        }.width('100%')

        Row({ space: 8 }) {
          ActionButton({ label: '立即重连', tone: 'secondary', compact: true, isEnabled: !this.busy,
            onTap: () => { this.onReconnect(this.srv.id); } })
          ActionButton({ label: '编辑', tone: 'secondary', compact: true, isEnabled: !this.busy,
            onTap: () => { this.onEdit(this.srv); } })
          ActionButton({ label: '删除', tone: 'danger', compact: true, isEnabled: !this.busy,
            onTap: () => { this.onDelete(this.srv); } })
        }.width('100%')

        if (this.srv.error) {
          Text(this.srv.error).fontSize(12).fontColor($r('app.color.tentacle_danger'))
            .width('100%').padding(8).backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(8)
        }

        if ((this.srv.env_vars?.length ?? 0) > 0) {
          PluginEnvVarList({
            envVars: this.srv.env_vars ?? [],
            envStatus: this.srv.env_status,
            missingEnv: this.srv.missing_env,
            busy: this.busy,
            onOpenEnv: (name: string) => { this.onOpenEnv(name); }
          })
        }

        if ((this.srv.tools?.length ?? 0) > 0) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.srv.tools ?? [], (t: PluginToolRecord) => {
              Row() {
                StatusPill({ label: t.name, tone: t.enabled ? 'accent' : 'default' })
              }.margin({ right: 6, bottom: 4 })
            }, (t: PluginToolRecord) => t.name)
          }.width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}

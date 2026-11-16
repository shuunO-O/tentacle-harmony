import { ConfigValue, RestartState } from './Management';

export interface PermissionDetail {
  permission: string;
  level: string;
  summary: string;
}

export interface PluginConfigSchemaField {
  key: string;
  label: string;
  type: string;
  default?: ConfigValue;
  required?: boolean;
  choices?: ConfigValue[] | null;
  minimum?: number | null;
  maximum?: number | null;
  multiline?: boolean;
  nullable?: boolean;
  help?: string;
}

export interface PluginToolRecord {
  raw_name: string;
  name: string;
  description?: string;
  enabled: boolean;
}

export interface PluginManifestInfo {
  id: string;
  name: string;
  version: string;
  description?: string;
  author?: string;
  permissions?: string[];
  requires_env?: string[];
  optional_env?: string[];
  config_schema?: Record<string, PluginConfigSchemaField>;
}

export interface LocalPluginItem {
  id: string;
  kind: string;
  enabled: boolean;
  trusted: boolean;
  bundled?: boolean;
  saved_enabled?: boolean;
  saved_trusted?: boolean;
  status: string;
  error?: string | null;
  manifest?: PluginManifestInfo | null;
  permission_details?: PermissionDetail[];
  config?: Record<string, ConfigValue>;
  saved_config?: Record<string, ConfigValue>;
  disabled_tools?: string[];
  saved_disabled_tools?: string[];
  tools?: PluginToolRecord[];
  commands?: string[];
  hooks?: string[];
  skills?: string[];
  channels?: string[];
  routes?: string[];
  background_tasks?: number;
  missing_env?: string[];
  env_vars?: string[];
  env_status?: Record<string, boolean>;
  has_prompt?: boolean;
  pending_restart?: boolean;
}

export interface McpServerConfig {
  enabled: boolean;
  trusted: boolean;
  transport: string;
  command?: string;
  args?: string[];
  cwd?: string | null;
  env?: Record<string, string>;
  env_secrets?: Record<string, string>;
  url?: string;
  headers?: Record<string, string>;
  header_secrets?: Record<string, string>;
  auth_bearer_env?: string | null;
  timeout_seconds?: number;
  disabled_tools?: string[];
}

export interface McpServerItem {
  id: string;
  kind: string;
  enabled: boolean;
  trusted: boolean;
  status: string;
  error?: string | null;
  transport?: string | null;
  tools?: PluginToolRecord[];
  disabled_tools?: string[];
  missing_env?: string[];
  env_vars?: string[];
  env_status?: Record<string, boolean>;
  mcp_config?: McpServerConfig | null;
  saved_config?: McpServerConfig | null;
  pending_restart?: boolean;
}

export interface PermissionMeta {
  level: string;
  summary: string;
}

export interface PluginsSnapshot {
  revision: string;
  plugins: LocalPluginItem[];
  mcp_servers: McpServerItem[];
  permission_catalog: Record<string, PermissionMeta>;
  restart_required: boolean;
  restart: RestartState;
}

export interface PluginDecisionPayload {
  revision: string;
  enabled: boolean;
  trusted: boolean;
  config: Record<string, ConfigValue>;
  disabled_tools: string[];
}

export interface PluginEnvWriteResult {
  ok: boolean;
  name: string;
  configured: boolean;
}

export function pluginStatusLabel(status: string): string {
  const labels: Record<string, string> = {
    'active': '运行中',
    'pending': '待审核启用',
    'disabled': '已停用',
    'degraded': '异常降级',
  };
  return labels[status] ?? (status || '未知');
}

export function permissionRiskLabel(level: string): string {
  if (level === 'high') { return '高风险'; }
  if (level === 'medium') { return '中风险'; }
  return '低风险';
}

export function parseKeyValueLines(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  const lines = raw.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (!trimmed) { continue; }
    const idx = trimmed.indexOf('=');
    if (idx <= 0) {
      throw new Error('格式应为 KEY=VALUE：' + trimmed);
    }
    const k = trimmed.substring(0, idx).trim();
    const v = trimmed.substring(idx + 1).trim();
    out[k] = v;
  }
  return out;
}

export function formatKeyValueLines(obj?: Record<string, string> | null): string {
  if (!obj) { return ''; }
  const keys = Object.keys(obj);
  const lines: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    lines.push(key + '=' + (obj[key] ?? ''));
  }
  return lines.join('\n');
}

export function parseStringListLines(raw: string): string[] {
  const lines = raw.split(/\r?\n/);
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (trimmed.length > 0) { out.push(trimmed); }
  }
  return out;
}

export function formatStringListLines(value: ConfigValue | undefined): string {
  if (!Array.isArray(value)) { return ''; }
  const list = value as string[];
  return list.join('\n');
}

export function clonePluginConfig(src?: Record<string, ConfigValue> | null): Record<string, ConfigValue> {
  const out: Record<string, ConfigValue> = {};
  if (!src) { return out; }
  const keys = Object.keys(src);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const val = src[key];
    out[key] = Array.isArray(val) ? (val as string[]).slice() : val;
  }
  return out;
}

/** Parse qualified plugin/MCP tool names (p_<id>__<tool> / mcp_<id>__<tool>) into a compact source label. */
export function parseToolSourceBadge(toolName: string): string {
  if (toolName.startsWith('p_')) {
    const sep = toolName.indexOf('__', 2);
    if (sep > 2) {
      return '插件 · ' + toolName.substring(2, sep);
    }
  } else if (toolName.startsWith('mcp_')) {
    const sep = toolName.indexOf('__', 4);
    if (sep > 4) {
      return 'MCP · ' + toolName.substring(4, sep);
    }
  }
  return '';
}

export function hasLocalPluginDetails(plugin: LocalPluginItem): boolean {
  const schemaCount = plugin.manifest?.config_schema ? Object.keys(plugin.manifest.config_schema).length : 0;
  return schemaCount > 0 ||
    (plugin.permission_details?.length ?? 0) > 0 ||
    (plugin.tools?.length ?? 0) > 0 ||
    (plugin.env_vars?.length ?? 0) > 0 ||
    (plugin.commands?.length ?? 0) > 0 ||
    (plugin.skills?.length ?? 0) > 0 ||
    (plugin.channels?.length ?? 0) > 0 ||
    (plugin.routes?.length ?? 0) > 0;
}

export function pluginSummaryText(plugin: LocalPluginItem): string {
  const parts: string[] = [];
  const permCount = plugin.permission_details?.length ?? 0;
  const toolCount = plugin.tools?.length ?? 0;
  const schemaCount = plugin.manifest?.config_schema ? Object.keys(plugin.manifest.config_schema).length : 0;
  const envCount = plugin.env_vars?.length ?? 0;
  const skillCount = plugin.skills?.length ?? 0;
  if (permCount > 0) { parts.push('权限 ' + permCount.toString()); }
  if (toolCount > 0) { parts.push('工具 ' + toolCount.toString()); }
  if (schemaCount > 0) { parts.push('配置项 ' + schemaCount.toString()); }
  if (envCount > 0) { parts.push('环境变量 ' + envCount.toString()); }
  if (skillCount > 0) { parts.push('Skills ' + skillCount.toString()); }
  return parts.join(' · ');
}

export function pluginSchemaFields(plugin: LocalPluginItem): PluginConfigSchemaField[] {
  const schema = plugin.manifest?.config_schema;
  if (!schema) { return []; }
  const keys = Object.keys(schema);
  const out: PluginConfigSchemaField[] = [];
  for (let i = 0; i < keys.length; i++) {
    out.push(schema[keys[i]]);
  }
  return out;
}

export function schemaFieldChoices(field: PluginConfigSchemaField): string[] {
  if (!Array.isArray(field.choices)) { return []; }
  return field.choices.map((item: ConfigValue) => String(item));
}

export function isPluginEnvReady(envStatus: Record<string, boolean> | undefined, missingEnv: string[] | undefined, varName: string): boolean {
  if (envStatus && envStatus[varName] !== undefined) { return envStatus[varName]; }
  return !(missingEnv ?? []).includes(varName);
}

export function readPluginDraftValue(localDrafts: Record<string, Record<string, ConfigValue>>, pluginId: string,
  field: PluginConfigSchemaField): ConfigValue {
  const map = localDrafts[pluginId];
  if (map && map[field.key] !== undefined) { return map[field.key]; }
  return field.default !== undefined ? field.default : '';
}

export function readPluginNumericText(localNumericInputs: Record<string, Record<string, string>>,
  localDrafts: Record<string, Record<string, ConfigValue>>, pluginId: string, field: PluginConfigSchemaField): string {
  const map = localNumericInputs[pluginId];
  if (map && map[field.key] !== undefined) { return map[field.key]; }
  const val = readPluginDraftValue(localDrafts, pluginId, field);
  return val === null || val === undefined ? '' : String(val);
}

export function isPluginToolDisabled(disabledDrafts: Record<string, string[]>, pluginId: string,
  tool: PluginToolRecord): boolean {
  const list = disabledDrafts[pluginId] ?? [];
  return list.includes(tool.raw_name) || list.includes(tool.name);
}

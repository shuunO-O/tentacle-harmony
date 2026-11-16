import { ConfigField, ConfigSnapshot, ConfigValue, displayValue } from './Management';
import { formatStringListLines } from './Plugins';

// Keep the same section boundaries as web/static/configuration.js.
export function configurationSection(group: string): string {
  if (/^(连接|模型|角色) · /.test(group)) { return 'models'; }
  return ['心跳', '公开网页工具', '定时任务', '功能开关'].includes(group) ? 'runtime' : 'maintenance';
}

export function configurationRole(id: string): string {
  const names: Record<string, string> = { 'chat': '主对话', 'subagent': '子代理', 'embedding': '向量嵌入',
    'memory_extractor': '记忆提取', 'compress': '上下文压缩', 'subconscious': '潜意识' };
  return names[id] ?? id;
}

export function configurationFieldSection(path: string, kind: string): string {
  if (kind === 'tools') { return 'tools'; }
  const common = ['label', 'type', 'base_url', 'api_key_env', 'project', 'location', 'credentials_env', 'gcs_base_url', 'provider', 'name',
    'api_style', 'vision', 'audio', 'video', 'context_window', 'model', 'max_iterations', 'temperature', 'reasoning_effort', 'stream'];
  return common.includes(path.substring(path.lastIndexOf('.') + 1)) ? 'common' : 'advanced';
}

/** Match Web configGrouping.ts 4-section taxonomy for ConfigSnapshot fields. */
export function configurationPathSection(path: string): string {
  if (path.startsWith('providers.') || path.startsWith('models.') || path.startsWith('roles.')) {
    return 'models';
  }
  if (path.startsWith('memory.') || path.startsWith('concepts.') || path.startsWith('embeddings.')) {
    return 'memory';
  }
  if (
    path.startsWith('webui.') ||
    path.startsWith('qqbot.') ||
    path.startsWith('web_tools.') ||
    path.startsWith('media_inputs.') ||
    path.startsWith('qq.') ||
    path.startsWith('attachments.') ||
    path.startsWith('files.') ||
    path.startsWith('web.')
  ) {
    return 'channels';
  }
  return 'runtime';
}

/** Estimate visual wrapped lines so long mobile paragraphs auto-expand in the composer pill. */
export function estimateWrappedLines(text: string, maxLines: number = 5, colsPerLine: number = 28): number {
  if (!text) { return 1; }
  const rawLines = text.split('\n');
  let total = 0;
  for (let i = 0; i < rawLines.length; i++) {
    const line = rawLines[i];
    let visualCols = 0;
    for (let j = 0; j < line.length; j++) {
      const code = line.charCodeAt(j);
      visualCols += code >= 0x2E80 ? 2 : 1;
    }
    total += Math.max(1, Math.ceil(visualCols / colsPerLine));
    if (total >= maxLines) { return maxLines; }
  }
  return Math.max(1, total);
}

/** Shared field resolution & dirty-comparison helpers used by ConfigurationPage and ConfigFieldEditor. */
export function resolveConfigValue(data: ConfigSnapshot | null, draft: Record<string, ConfigValue>, f: ConfigField): ConfigValue {
  const changed = draft[f.path];
  const inherit = changed !== null && typeof changed === 'object' && !Array.isArray(changed);
  if (changed !== undefined && !inherit) { return changed; }
  if (f.inheritable && (f.source === 'default' || inherit) && data !== null) {
    const role = f.path.split('.')[1];
    const modelField = data.fields.find((item: ConfigField) => item.path === 'roles.' + role + '.model');
    const modelId = modelField === undefined ? '' : String(resolveConfigValue(data, draft, modelField));
    const key = f.path.substring(f.path.lastIndexOf('.') + 1);
    const parent = data.fields.find((item: ConfigField) => item.path === 'models.' + modelId + '.defaults.' + key);
    if (parent !== undefined) { return resolveConfigValue(data, draft, parent); }
    return f.default;
  }
  return f.value;
}

export function formatConfigText(data: ConfigSnapshot | null, draft: Record<string, ConfigValue>, f: ConfigField): string {
  const v = resolveConfigValue(data, draft, f);
  if (v === null) { return ''; }
  if (f.kind === 'string_list' && Array.isArray(v)) { return formatStringListLines(v); }
  return typeof v === 'string' ? v : displayValue(v);
}

export function resolveConfigChoices(data: ConfigSnapshot | null, draft: Record<string, ConfigValue>, f: ConfigField): string[] {
  if (data === null) { return f.choices; }
  if (f.path.startsWith('models.') && f.path.endsWith('.api_style')) {
    const providerField = data.fields.find((p: ConfigField) => p.path === 'models.' + f.path.split('.')[1] + '.provider');
    if (providerField !== undefined) {
      const typeField = data.fields.find((p: ConfigField) => p.path === 'providers.' + resolveConfigValue(data, draft, providerField) + '.type');
      const spec = typeField === undefined ? undefined : data.provider_types[String(resolveConfigValue(data, draft, typeField))];
      if (spec !== undefined) { return spec.protocols; }
    }
  }
  return f.choices;
}

export function resolveConfigTools(data: ConfigSnapshot | null, draft: Record<string, ConfigValue>, f: ConfigField): string[] {
  const current = resolveConfigValue(data, draft, f);
  const known = data === null ? [] : data.tools[f.path.split('.')[1]] ?? [];
  const names: string[] = known.concat(Array.isArray(current) ? current as string[] : []);
  return names.filter((n: string, i: number) => names.indexOf(n) === i).sort();
}

export function isConfigFieldLocked(f: ConfigField, busy: boolean): boolean {
  return busy || f.protected || f.path.startsWith('providers.') && f.path.endsWith('.auth');
}

export function isConfigValueSameAsSaved(f: ConfigField, value: ConfigValue): boolean {
  if (JSON.stringify(value) === JSON.stringify(f.value)) {
    return true;
  }
  if ((f.kind === 'number' || f.kind === 'integer') && typeof f.value === 'number' && typeof value === 'string') {
    const trimmed = value.trim();
    if (trimmed.length > 0 && Number(trimmed) === f.value) {
      return true;
    }
  }
  return false;
}

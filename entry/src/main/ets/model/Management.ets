/** Public backend contracts only. No host paths, credentials or local command registry. */
export interface InheritValue { $inherit: boolean; }
export interface ToolSelection { enabled: string[]; }
export type ConfigValue = string | number | boolean | null | string[] | InheritValue | ToolSelection;
export interface ConfigField {
  path: string;
  label: string;
  kind: string;
  group: string;
  value: ConfigValue;
  active: ConfigValue;
  default: ConfigValue;
  effect: string;
  source: string;
  choices: string[];
  nullable: boolean;
  inheritable: boolean;
  protected: boolean;
  pending: boolean;
  minimum: number | null;
  maximum: number | null;
  help: string;
  configured?: boolean;
  multiline?: boolean;
}
export interface ConfigEnvResult { status?: ConfigSnapshot; }
export interface ConfigBackup { id: string; created_at: number; }
export interface ProviderSpec { label: string; auth: string; protocols: string[]; base_url: string; api_style: string; }
export interface ProviderReferences { models: string[]; roles: string[]; uploads: string[]; balance: boolean; }
export interface ConfigEntity {
  id: string;
  label: string;
  type?: string;
  provider?: string;
  model?: string;
  name?: string;
  references: ProviderReferences | string[];
}
export interface ConfigEntities { providers: ConfigEntity[]; models: ConfigEntity[]; roles: ConfigEntity[]; }
export interface CredentialState { auth: string; configured: boolean; }
export interface RestartState { available: boolean; state: string; }
export interface ActiveModel { name: string; provider_id: string | null; model_id: string | null; api_style: string; }
export interface ConfigSnapshot {
  revision: string;
  config_version: number;
  fields: ConfigField[];
  history: ConfigBackup[];
  entities: ConfigEntities;
  provider_types: Record<string, ProviderSpec>;
  tools: Record<string, string[]>;
  connection_status: Record<string, CredentialState>;
  active_role: string;
  active_model: ActiveModel;
  applying: boolean;
  error: string | null;
  restart_required: boolean;
  concept_migration_needed?: boolean;
  restart: RestartState;
}
export interface MaintenanceVersion {
  version?: string;
  commit?: string;
  built_at?: string;
}
export interface MaintenanceCheck {
  ok?: boolean;
  available?: boolean;
  current?: string;
  latest?: string;
  message?: string;
  data_compatible?: boolean;
  checked_at?: number;
}
export interface MaintenanceOperation {
  id?: string;
  action?: string;
  version?: string;
  state?: string;
  error?: string;
}
export interface MaintenanceStatus {
  available?: boolean;
  can_update?: boolean;
  web_allowed?: boolean;
  version?: MaintenanceVersion | null;
  check?: MaintenanceCheck | null;
  operation?: MaintenanceOperation | null;
}
export interface DedupAuditEntry {
  id: string;
  actor: string;
  source?: string;
  action: string;
  reference?: string;
  status?: string;
  created?: number;
}
export interface DedupAuditResult {
  entries?: DedupAuditEntry[];
  total?: number;
}
export interface ConfigChange { path: string; label: string; before: ConfigValue; after: ConfigValue; effect: string; impact?: string[]; }
export interface MigrationNeed { role: string; reason: string; }
export interface ConfigPreview {
  revision: string;
  changes: ConfigChange[];
  status?: ConfigSnapshot;
  equivalent?: boolean;
  unresolved?: MigrationNeed[];
  changed_roles?: string[];
  warnings?: string[];
}
export interface StructureOperation { op: string; kind: string; id: string; value?: Record<string, ConfigValue>; }
export interface CatalogModel { import_id: string; name: string; context_window?: number; configured?: boolean; }
export interface ModelCatalog { revision: string; provider: string; models: CatalogModel[]; api_style: string; notice: string; truncated: boolean; }

export interface DeviceRecord { id: string; name: string; created: number; last_seen?: number; }
export interface DeviceInfo {
  devices: DeviceRecord[];
  device_auth: boolean;
  device_bound: boolean;
  allow_new_devices: boolean;
  has_password: boolean;
  freeze: boolean;
}
export interface SelfBackup { source: string; timestamp: string; size_bytes: number; }
export interface SelfBackupsResult { items: SelfBackup[]; }

export interface SubagentTask {
  id: string; objective: string; status: string; progress: string; result: string;
  error: string | null; delivery: string; background: string; archived: boolean;
  created_at: number; updated_at: number; finished_at: number | null; cleanup_error?: string;
}
export interface SubagentList { enabled: boolean; tasks: SubagentTask[]; has_more?: boolean; execution_blocked?: boolean; coding_enabled?: boolean; }
export interface SubagentWsEvent {
  event?: string;
  task_id?: string;
  enabled?: boolean;
  execution_blocked?: boolean;
  coding_enabled?: boolean;
  tasks?: SubagentTask[];
  has_more?: boolean;
}
export interface TurnUsage { prompt_tokens: number; completion_tokens: number; }
export interface SubagentTurn {
  id: number; status: string; delivery: string; message: string; result: string; error: string | null;
  created_at: number; finished_at: number | null; usage: TurnUsage;
}
export interface SubagentDetail { task: SubagentTask; turns: SubagentTurn[]; next_before: number | null; }

export interface DedupNode { id: string; name: string; aliases: string[]; first_context: string; events: string[]; description?: string; }
export interface DedupEvidence { left: DedupNode; right: DedupNode; conflicts?: object[]; }
export interface DedupScore { probabilities?: Record<string, number>; label?: string | number; }
export interface DedupPairData { preview: DedupEvidence; reason: string; error_code?: string; automatic?: boolean; score?: DedupScore; }
export interface DedupChoice { keep_id: string; policy: string; }
export interface DedupPair { id: string; state: string; data: DedupPairData; choice?: DedupChoice; operation?: object; }
export interface DedupRun { status: string; visited: number; checked: number; errors: number; message: string; }
export interface DedupStatus { run: DedupRun | null; counts: Record<string, number>; pairs: DedupPair[]; }
export interface DedupWsEvent { event?: string; run?: DedupRun | null; counts?: Record<string, number>; }

export function displayValue(value: ConfigValue): string {
  if (value === null) { return '不指定'; }
  if (typeof value === 'string') { return value; }
  return JSON.stringify(value);
}

export function fieldValue(field: ConfigField, text: string): ConfigValue {
  if (field.kind === 'number' || field.kind === 'integer') {
    if (text.trim().length === 0) { throw new Error(field.label + '不能为空'); }
    const n = Number(text);
    if (!Number.isFinite(n) || (field.kind === 'integer' && !Number.isInteger(n))) {
      throw new Error(field.label + '需要' + (field.kind === 'integer' ? '整数' : '有效数值'));
    }
    if (field.minimum !== null && n < field.minimum || field.maximum !== null && n > field.maximum) {
      throw new Error(field.label + '超出允许范围');
    }
    return n;
  }
  return text;
}

export function effectLabel(effect: string): string {
  return effect === 'immediate' ? '保存后生效' : effect === 'round' ? '回合结束后生效' : '需要重启';
}

export function taskStatus(status: string): string {
  const labels: Record<string, string> = { 'queued': '排队中', 'running': '运行中', 'waiting_input': '等待补充信息',
    'completed': '已完成', 'failed': '失败', 'cancelled': '已取消', 'interrupted': '已中断', 'pending': '待审核',
    'merged': '已合并', 'independent': '保持独立', 'different': '判定不同', 'limited': '达到本轮上限' };
  return labels[status] ?? status;
}

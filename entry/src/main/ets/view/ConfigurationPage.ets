import { TentacleApi } from '../service/TentacleApi';
import { ConfigSnapshot, ConfigField, ConfigValue, ConfigPreview, ConfigChange, ConfigBackup, ConfigEntity,
  StructureOperation, ModelCatalog, CatalogModel, ToolSelection, displayValue, fieldValue, effectLabel } from '../model/Management';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle, StatusPill } from '../components/UiKit';
import { notifyToast } from '../model/UiToast';
import {
  configurationSection,
  configurationRole,
  configurationFieldSection,
  configurationPathSection,
  formatConfigText,
  isConfigFieldLocked,
  isConfigValueSameAsSaved,
  resolveConfigChoices,
  resolveConfigTools,
  resolveConfigValue,
} from '../model/ConfigurationNavigation';
import { formatStringListLines, parseStringListLines } from '../model/Plugins';

/** Schema-driven native configuration editor aligned with WebUI ConfigurationPanel. */
@Component
export struct ConfigurationPage {
  @State data: ConfigSnapshot | null = null;
  @State draft: Record<string, ConfigValue> = {};
  @State group: string = '';
  @State search: string = '';
  @State fieldSearch: string = '';
  @State showDirtyOnly: boolean = false;
  @State message: string = '';
  @State messageTone: string = 'info';
  @State busy: boolean = false;
  @State preview: ConfigPreview | null = null;
  @State catalog: ModelCatalog | null = null;
  @State catalogSearch: string = '';
  @State selectedModels: string[] = [];
  @State catalogProtocol: string = '';
  @State createKind: string = '';
  @State createId: string = '';
  @State createLabel: string = '';
  @State createName: string = '';
  @State createParent: string = '';
  @State createType: string = '';
  @State createUrl: string = '';
  @State createEnv: string = '';
  @State createProject: string = '';
  @State createLocation: string = 'global';
  @State createCredentialsEnv: string = '';
  @State createGcsBaseUrl: string = '';
  @State createApiStyle: string = 'chat';
  @State createContextWindow: string = '131072';
  @State createVision: boolean = false;
  @State section: string = 'models';
  @State inspecting: boolean = false;
  @State maintenanceOpen: boolean = false;
  @State expandedProviders: string[] = [];
  @State expandedModels: string[] = [];
  @State advancedOpen: boolean = false;
  @State toolsOpen: boolean = false;
  @State envTargetPath: string = '';
  @State envTargetLabel: string = '';
  @State envTargetName: string = '';
  @State envSecretValue: string = '';
  private previewKind: string = '';
  private operations: StructureOperation[] = [];
  private backup: string = '';
  private timer: number = -1;
  private visible: boolean = false;
  private generation: number = 0;

  aboutToAppear(): void { this.visible = true; this.load(); }
  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private dirty(): boolean { return Object.keys(this.draft).length > 0 || this.createKind.length > 0; }

  private setNotice(text: string, tone: string = 'info'): void {
    this.message = text;
    this.messageTone = tone;
  }

  private async load(): Promise<void> {
    if (this.dirty() || this.preview !== null || this.busy) { return; }
    const seq = ++this.generation;
    try {
      const data = await TentacleApi.getInstance().getConfiguration();
      if (seq !== this.generation || !this.visible || this.dirty() || this.preview !== null) { return; }
      this.data = data;
      if (!this.groups().includes(this.group)) {
        const active = '角色 · ' + data.active_role;
        this.group = this.groups().includes(active) ? active : this.groups()[0] ?? '';
        const role = data.entities.roles.find((e: ConfigEntity) => e.id === data.active_role);
        const model = data.entities.models.find((e: ConfigEntity) => e.id === role?.model);
        if (model !== undefined) { this.expandedModels = [model.id]; this.expandedProviders = [model.provider ?? '']; }
      }
      this.setNotice(data.error ?? '', data.error ? 'danger' : 'info');
      if ((data.applying || data.restart.state === 'waiting' || data.restart.state === 'restarting') && this.visible) {
        this.timer = setTimeout(() => this.load(), 2000);
      }
    } catch (e) { if (seq === this.generation) { this.setNotice((e as Error).message, 'danger'); } }
  }

  private groups(): string[] {
    if (this.data === null) { return []; }
    const result: string[] = [];
    for (const f of this.data.fields) {
      if (f.path !== 'usage.balance_provider' && !f.path.startsWith('plugins.items.') && !result.includes(f.group)) {
        result.push(f.group);
      }
    }
    return result;
  }

  private options(values: string[]): SelectOption[] { return values.map((v: string): SelectOption => ({ value: v })); }

  // Preserved for configurationSection unit semantics
  private sectionGroups(): string[] { return this.groups().filter((g: string) => configurationSection(g) === this.section); }

  private uiSectionGroups(): string[] {
    if (this.data === null) { return []; }
    const out: string[] = [];
    for (const f of this.data.fields) {
      if (f.path === 'usage.balance_provider' || f.path.startsWith('plugins.items.')) { continue; }
      if (configurationPathSection(f.path) === this.section && !out.includes(f.group)) {
        out.push(f.group);
      }
    }
    return out;
  }

  private uiSectionCount(sec: string): number {
    if (this.data === null) { return 0; }
    let count = 0;
    for (const f of this.data.fields) {
      if (f.path === 'usage.balance_provider' || f.path.startsWith('plugins.items.')) { continue; }
      if (configurationPathSection(f.path) === sec) { count++; }
    }
    return count;
  }

  private uiSectionDirtyCount(sec: string): number {
    let count = 0;
    for (const path of Object.keys(this.draft)) {
      if (configurationPathSection(path) === sec) { count++; }
    }
    return count;
  }

  private groupDirtyCount(groupName: string): number {
    if (this.data === null) { return 0; }
    let count = 0;
    for (const f of this.data.fields) {
      if (f.group === groupName && this.draft[f.path] !== undefined) { count++; }
    }
    return count;
  }

  private navigate(group: string): void {
    if (this.busy) { return; }
    this.group = group; this.section = configurationSection(group); this.inspecting = true;
    this.maintenanceOpen = false;
    this.advancedOpen = false; this.toolsOpen = false;
    this.fieldSearch = '';
  }

  private selectEntityGroup(group: string): void {
    if (this.busy) { return; }
    this.group = group;
    this.advancedOpen = false;
    this.toolsOpen = false;
    this.fieldSearch = '';
  }

  private switchSection(section: string): void {
    if (this.busy || this.preview !== null || this.createKind || this.catalog !== null || this.envTargetPath) { return; }
    this.section = section; this.inspecting = false; this.maintenanceOpen = false;
    if (!this.sectionGroups().includes(this.group)) { this.group = this.sectionGroups()[0] ?? ''; }
    this.advancedOpen = false; this.toolsOpen = false;
  }

  private switchUiSection(sec: string): void {
    if (this.busy || this.preview !== null || this.createKind || this.catalog !== null || this.envTargetPath) { return; }
    this.section = sec;
    this.inspecting = false;
    this.maintenanceOpen = false;
    this.fieldSearch = '';
    const groups = this.uiSectionGroups();
    if (!groups.includes(this.group)) {
      this.group = groups[0] ?? '';
    }
    this.advancedOpen = false;
    this.toolsOpen = false;
  }

  private entityTitle(kind: string, entity: ConfigEntity): string {
    const field = this.data?.fields.find((f: ConfigField) => f.path === kind + '.' + entity.id + '.label');
    const label = field === undefined ? entity.label : String(this.value(field) ?? '');
    return label && label !== entity.id ? label : kind === 'roles' ? configurationRole(entity.id) : entity.id;
  }
  private entityMatches(kind: string, entity: ConfigEntity): boolean {
    return !this.search || (this.entityTitle(kind, entity) + ' ' + entity.id + ' ' + (entity.name ?? '')).toLowerCase().includes(this.search.trim().toLowerCase());
  }
  private modelsFor(provider: string): ConfigEntity[] {
    return (this.data?.entities.models ?? []).filter((m: ConfigEntity) => m.provider === provider);
  }
  private rolesFor(model: string): ConfigEntity[] {
    return (this.data?.entities.roles ?? []).filter((r: ConfigEntity) => r.model === model);
  }
  private visibleModel(model: ConfigEntity): boolean {
    return this.entityMatches('models', model) || this.rolesFor(model.id).some((r: ConfigEntity) => this.entityMatches('roles', r));
  }
  private visibleProviders(): ConfigEntity[] {
    return (this.data?.entities.providers ?? []).filter((p: ConfigEntity) => this.entityMatches('providers', p) ||
      this.modelsFor(p.id).some((m: ConfigEntity) => this.visibleModel(m)));
  }
  private toggleProvider(id: string): void {
    this.expandedProviders = this.expandedProviders.includes(id) ? this.expandedProviders.filter((v: string) => v !== id) : this.expandedProviders.concat([id]);
  }
  private toggleModel(id: string): void {
    this.expandedModels = this.expandedModels.includes(id) ? this.expandedModels.filter((v: string) => v !== id) : this.expandedModels.concat([id]);
  }
  private editorFields(part: string): ConfigField[] {
    return (this.data?.fields ?? []).filter((f: ConfigField) => f.group === this.group &&
      f.path !== 'usage.balance_provider' && !f.path.startsWith('plugins.items.') &&
      this.fieldVisible(f) && (part === 'all' || configurationFieldSection(f.path, f.kind) === part));
  }

  private visibleEditorFields(part: string): ConfigField[] {
    let list = this.editorFields(part);
    if (this.showDirtyOnly) {
      list = list.filter((f: ConfigField) => this.draft[f.path] !== undefined);
    }
    const q = this.fieldSearch.trim().toLowerCase();
    if (q.length > 0) {
      list = list.filter((f: ConfigField) =>
        f.label.toLowerCase().includes(q) || f.path.toLowerCase().includes(q) || (f.help ?? '').toLowerCase().includes(q));
    }
    return list;
  }

  private fieldVisible(field: ConfigField): boolean {
    const key = field.path.substring(field.path.lastIndexOf('.') + 1);
    if (!['credentials_env', 'gcs_base_url'].includes(key)) { return true; }
    const parts = field.path.split('.');
    if (parts[0] === 'providers') {
      const typeField = this.data?.fields.find((item: ConfigField) => item.path === 'providers.' + parts[1] + '.type');
      const type = typeField === undefined ? this.data?.entities.providers.find((item: ConfigEntity) => item.id === parts[1])?.type : String(this.value(typeField));
      return this.data?.provider_types[type ?? '']?.auth === 'adc';
    }
    const auth = this.data?.fields.find((item: ConfigField) => item.path === 'models.' + parts[1] + '.auth');
    return auth !== undefined && this.value(auth) === 'adc';
  }

  private currentEntityKind(): string {
    if (this.group.startsWith('连接 · ')) { return 'providers'; }
    if (this.group.startsWith('模型 · ')) { return 'models'; }
    if (this.group.startsWith('角色 · ')) { return 'roles'; }
    return '';
  }

  private currentEntityId(): string {
    const idx = this.group.indexOf(' · ');
    return idx >= 0 ? this.group.substring(idx + 3) : '';
  }

  private currentEntity(): ConfigEntity | undefined {
    const kind = this.currentEntityKind();
    const id = this.currentEntityId();
    if (!kind || !id || this.data === null) { return undefined; }
    const list = kind === 'providers' ? this.data.entities.providers
      : kind === 'models' ? this.data.entities.models : this.data.entities.roles;
    return list.find((e: ConfigEntity) => e.id === id);
  }

  private currentEntityLocked(): boolean {
    const entity = this.currentEntity();
    if (entity === undefined) { return false; }
    if (Array.isArray(entity.references)) { return entity.references.length > 0; }
    const refs = entity.references;
    return refs.models.length > 0 || refs.roles.length > 0 || refs.uploads.length > 0 || refs.balance;
  }

  private chainProvider(): ConfigEntity | undefined {
    if (this.data === null) { return undefined; }
    const kind = this.currentEntityKind();
    const cur = this.currentEntity();
    if (cur === undefined) { return undefined; }
    if (kind === 'providers') { return cur; }
    if (kind === 'models') {
      return this.data.entities.providers.find((p: ConfigEntity) => p.id === cur.provider);
    }
    const mod = this.data.entities.models.find((m: ConfigEntity) => m.id === cur.model);
    return mod ? this.data.entities.providers.find((p: ConfigEntity) => p.id === mod.provider) : undefined;
  }

  private chainModels(): ConfigEntity[] {
    if (this.data === null) { return []; }
    const kind = this.currentEntityKind();
    const cur = this.currentEntity();
    if (cur === undefined) { return []; }
    if (kind === 'providers') {
      return this.data.entities.models.filter((m: ConfigEntity) => m.provider === cur.id);
    }
    if (kind === 'models') { return [cur]; }
    const bound = this.data.entities.models.find((m: ConfigEntity) => m.id === cur.model);
    return bound ? [bound] : [];
  }

  private chainRoles(): ConfigEntity[] {
    if (this.data === null) { return []; }
    const kind = this.currentEntityKind();
    const cur = this.currentEntity();
    if (cur === undefined) { return []; }
    if (kind === 'roles') { return [cur]; }
    if (kind === 'models') {
      return this.data.entities.roles.filter((r: ConfigEntity) => r.model === cur.id);
    }
    const modIds = this.chainModels().map((m: ConfigEntity) => m.id);
    return this.data.entities.roles.filter((r: ConfigEntity) => r.model !== undefined && modIds.includes(r.model));
  }

  private groupTitle(): string {
    const parts = this.group.split(' · ');
    const kind = parts[0] === '连接' ? 'providers' : parts[0] === '模型' ? 'models' : 'roles';
    const list = kind === 'providers' ? this.data?.entities.providers : kind === 'models' ? this.data?.entities.models : this.data?.entities.roles;
    const entity = list?.find((e: ConfigEntity) => e.id === parts[1]);
    return entity === undefined ? this.group : this.entityTitle(kind, entity);
  }
  private removeSelected(): void {
    const parts = this.group.split(' · ');
    this.structure([{ op: 'delete', kind: parts[0] === '连接' ? 'providers' : parts[0] === '模型' ? 'models' : 'roles', id: parts[1] }]);
  }
  private providerTypes(): string[] { return this.data === null ? [] : Object.keys(this.data.provider_types); }

  private value(f: ConfigField): ConfigValue {
    return resolveConfigValue(this.data, this.draft, f);
  }

  private text(f: ConfigField): string {
    return formatConfigText(this.data, this.draft, f);
  }

  private edit(f: ConfigField, value: ConfigValue): void {
    if (this.locked(f)) { return; }
    const next: Record<string, ConfigValue> = {};
    for (const key of Object.keys(this.draft)) { if (key !== f.path) { next[key] = this.draft[key]; } }
    if (!isConfigValueSameAsSaved(f, value)) { next[f.path] = value; }
    this.draft = next;
    this.preview = null;
    this.setNotice('');
    if (Object.keys(next).length === 0) { this.showDirtyOnly = false; }
    if (f.path.startsWith('providers.') && f.path.endsWith('.type') && this.data !== null) {
      const spec = this.data.provider_types[String(value)];
      if (spec !== undefined) { this.draft[f.path.replace(/\.type$/, '.auth')] = spec.auth; }
    }
  }

  private choices(f: ConfigField): string[] {
    return resolveConfigChoices(this.data, this.draft, f);
  }

  private tools(f: ConfigField): string[] {
    return resolveConfigTools(this.data, this.draft, f);
  }

  private toggleTool(f: ConfigField, name: string, enabled: boolean): void {
    const current = this.value(f);
    const names: string[] = Array.isArray(current) ? current as string[] : [];
    this.edit(f, enabled ? names.concat([name]).filter((n: string, i: number, a: string[]) => a.indexOf(n) === i) :
      names.filter((n: string) => n !== name));
  }

  private locked(f: ConfigField): boolean {
    return isConfigFieldLocked(f, this.busy);
  }

  private changes(): Record<string, ConfigValue> {
    const result: Record<string, ConfigValue> = {};
    if (this.data === null) { return result; }
    for (const key of Object.keys(this.draft)) {
      const f = this.data.fields.find((item: ConfigField) => item.path === key);
      const value = this.draft[key];
      result[key] = f !== undefined && (f.kind === 'number' || f.kind === 'integer') && value !== null &&
        typeof value === 'string' ? fieldValue(f, value) : value;
    }
    return result;
  }

  private async previewChanges(): Promise<void> {
    if (this.data === null || this.busy) { return; }
    this.busy = true;
    try {
      const changes = this.changes();
      this.preview = await TentacleApi.getInstance().previewConfiguration(this.data.revision, changes);
      this.previewKind = 'fields';
      this.setNotice(this.preview.changes.length ? '校验通过，请核对变更后保存' : '没有需要保存的修改', 'info');
    } catch (e) { this.setNotice((e as Error).message, 'danger'); this.preview = null; }
    finally { this.busy = false; }
  }

  private async save(): Promise<void> {
    if (this.preview === null || this.busy || this.preview.changes.length === 0) { return; }
    this.busy = true;
    try {
      const api = TentacleApi.getInstance();
      const revision = this.preview.revision;
      let result: ConfigPreview;
      if (this.previewKind === 'structure') { result = await api.structureConfiguration(revision, this.operations, true); }
      else if (this.previewKind === 'restore') { result = await api.restoreConfiguration(revision, this.backup, true); }
      else { result = await api.saveConfiguration(revision, this.changes()); }
      this.preview = null;
      this.draft = {};
      this.showDirtyOnly = false;
      this.createKind = '';
      this.catalog = null;
      this.maintenanceOpen = false;
      if (result.status !== undefined) { this.data = result.status; }
      const okMsg = '已备份并保存；' + (this.data?.restart_required ? '部分配置等待重启' : '动态配置将在回合结束后应用');
      this.setNotice(okMsg, 'ok');
      notifyToast(okMsg, 'ok');
    } catch (e) { this.setNotice((e as Error).message, 'danger'); this.preview = null; }
    finally { this.busy = false; }
    this.load();
  }

  private async structure(operations: StructureOperation[]): Promise<void> {
    if (this.data === null || this.busy || Object.keys(this.draft).length) {
      this.setNotice('请先保存或放弃字段修改', 'danger'); return;
    }
    this.busy = true;
    try {
      this.preview = await TentacleApi.getInstance().structureConfiguration(this.data.revision, operations, false);
      this.operations = operations;
      this.previewKind = 'structure';
      this.setNotice('请核对结构变更及影响范围', 'info');
    } catch (e) { this.setNotice((e as Error).message, 'danger'); this.preview = null; }
    finally { this.busy = false; }
  }

  private openCreate(kind: string, parentId: string = ''): void {
    if (this.dirty() || this.preview !== null) { this.setNotice('请先保存或放弃当前修改', 'danger'); return; }
    this.maintenanceOpen = false;
    this.createKind = kind; this.createId = ''; this.createLabel = ''; this.createName = '';
    this.createParent = parentId || (kind === 'models' ? this.data?.entities.providers[0]?.id ?? '' : this.data?.entities.models[0]?.id ?? '');
    this.createType = this.data === null ? '' : Object.keys(this.data.provider_types)[0] ?? '';
    const spec = this.data?.provider_types[this.createType];
    this.createUrl = spec?.base_url ?? '';
    this.createEnv = ''; this.createProject = ''; this.createLocation = 'global';
    this.createCredentialsEnv = ''; this.createGcsBaseUrl = '';
    const parentProv = kind === 'models' ? this.data?.entities.providers.find((e: ConfigEntity) => e.id === this.createParent) : undefined;
    const parentSpec = parentProv?.type ? this.data?.provider_types[parentProv.type] : undefined;
    this.createApiStyle = parentSpec?.api_style ?? parentSpec?.protocols[0] ?? 'chat';
    this.createContextWindow = '131072';
    this.createVision = false;
  }

  private create(): void {
    const value: Record<string, ConfigValue> = {};
    if (this.createKind === 'providers') {
      const spec = this.data?.provider_types[this.createType];
      value['type'] = this.createType; value['auth'] = spec?.auth ?? 'api_key';
      value['base_url'] = this.createUrl; value['proxy'] = null;
      if (spec?.auth === 'adc') {
        value['project'] = this.createProject; value['location'] = this.createLocation;
        value['credentials_env'] = this.createCredentialsEnv.trim(); value['gcs_base_url'] = this.createGcsBaseUrl.trim();
      }
      else { value['api_key_env'] = this.createEnv; }
    } else if (this.createKind === 'models') {
      value['provider'] = this.createParent; value['name'] = this.createName;
      const provider = this.data?.entities.providers.find((e: ConfigEntity) => e.id === this.createParent);
      const spec = this.data?.provider_types[provider?.type ?? ''];
      value['api_style'] = this.createApiStyle.trim() || spec?.api_style || spec?.protocols[0] || 'chat';
      const ctx = Number(this.createContextWindow.trim());
      if (Number.isInteger(ctx) && ctx > 0) { value['context_window'] = ctx; }
      if (this.createVision) { value['vision'] = true; }
    } else {
      value['model'] = this.createParent;
      const tools: ToolSelection = { enabled: [] };
      value['tools'] = tools;
    }
    if (this.createLabel.trim()) { value['label'] = this.createLabel.trim(); }
    this.structure([{ op: 'create', kind: this.createKind, id: this.createId.trim(), value: value }]);
  }

  private async discover(provider: string): Promise<void> {
    if (this.data === null || this.dirty() || this.busy) { this.setNotice('请先保存或放弃修改，再读取模型目录', 'danger'); return; }
    this.busy = true;
    try {
      this.catalog = await TentacleApi.getInstance().discoverModels(this.data.revision, provider);
      this.catalogProtocol = this.catalog.api_style; this.selectedModels = []; this.catalogSearch = '';
    } catch (e) { this.setNotice((e as Error).message, 'danger'); }
    finally { this.busy = false; }
  }

  private importModels(): void {
    if (this.catalog === null) { return; }
    if (this.data?.revision !== this.catalog.revision) { this.setNotice('配置已变化，请重新读取模型目录', 'danger'); return; }
    const provider = this.catalog.provider;
    const operations: StructureOperation[] = [];
    for (const model of this.catalog.models) {
      if (this.selectedModels.includes(model.import_id) && !model.configured) {
        const value: Record<string, ConfigValue> = { 'provider': provider, 'name': model.name, 'api_style': this.catalogProtocol };
        if (model.context_window !== undefined) { value['context_window'] = model.context_window; }
        operations.push({ op: 'create', kind: 'models', id: model.import_id, value: value });
      }
    }
    this.structure(operations);
  }

  private async restore(id: string): Promise<void> {
    if (this.data === null || this.dirty() || this.busy) { this.setNotice('请先保存或放弃修改', 'danger'); return; }
    this.busy = true;
    try {
      this.preview = await TentacleApi.getInstance().restoreConfiguration(this.data.revision, id, false);
      this.backup = id; this.previewKind = 'restore';
    } catch (e) { this.setNotice((e as Error).message, 'danger'); }
    finally { this.busy = false; }
  }

  private discard(): void {
    this.draft = {}; this.showDirtyOnly = false; this.preview = null; this.createKind = ''; this.catalog = null;
    this.maintenanceOpen = false;
    this.setNotice('');
    this.cancelEnvEditor();
    this.load();
  }

  private openEnvEditor(f: ConfigField): void {
    if (this.busy || this.preview !== null || this.dirty()) {
      this.setNotice('请先保存或放弃当前修改，再录入环境变量', 'danger');
      return;
    }
    this.envTargetPath = f.path;
    this.envTargetLabel = f.label;
    const val = this.value(f);
    this.envTargetName = typeof val === 'string' ? val.trim() : '';
    this.envSecretValue = '';
  }

  private cancelEnvEditor(): void {
    this.envTargetPath = '';
    this.envTargetLabel = '';
    this.envTargetName = '';
    this.envSecretValue = '';
  }

  private async saveEnvSecret(): Promise<void> {
    if (this.data === null || !this.envTargetPath || this.busy) { return; }
    if (!this.envSecretValue.trim()) {
      this.setNotice('请输入有效的凭据值', 'danger');
      return;
    }
    this.busy = true;
    const path = this.envTargetPath;
    const secret = this.envSecretValue;
    this.envSecretValue = '';
    let ok = false;
    try {
      const res = await TentacleApi.getInstance().saveConfigurationEnvironment(path, secret, this.data.revision);
      this.cancelEnvEditor();
      if (res.status !== undefined) { this.data = res.status; }
      this.setNotice('环境变量已安全写入 .env（需重启使凭据生效）', 'ok');
      notifyToast('环境变量已写入 .env', 'ok');
      ok = true;
    } catch (e) {
      this.setNotice((e as Error).message, 'danger');
    } finally {
      this.busy = false;
    }
    if (ok) { this.load(); }
  }

  private refresh(): void {
    if (this.dirty() || this.preview !== null) {
      AlertDialog.show({ message: '放弃未保存修改并刷新？', primaryButton: { value: '继续编辑', action: () => {} },
        secondaryButton: { value: '放弃并刷新', action: () => this.discard() } });
    } else { this.load(); }
  }

  private async apply(): Promise<void> {
    if (this.busy || this.dirty() || this.preview !== null) { return; }
    this.busy = true;
    try {
      this.data = await TentacleApi.getInstance().applyConfiguration();
      notifyToast('已请求应用动态配置', 'ok');
    }
    catch (e) { this.setNotice((e as Error).message, 'danger'); }
    finally { this.busy = false; }
    this.load();
  }

  private restart(reembed: boolean = false): void {
    const revision = this.data?.revision ?? '';
    const msg = reembed
      ? '重启期间将使用当前嵌入模型重算全部记忆向量（将消耗嵌入模型用量），确定继续？'
      : '重启后端应用？服务会等待当前对话完成，期间可能暂时断开连接。';
    AlertDialog.show({
      message: msg,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: reembed ? '重算并重启' : '重启',
        action: async () => {
          this.busy = true;
          try {
            await TentacleApi.getInstance().restartApplication(revision, reembed);
            const txt = reembed ? '已请求重启并重算记忆向量' : '已请求重启，等待服务恢复';
            this.setNotice(txt, 'ok');
            notifyToast(txt, 'ok');
          }
          catch (e) { this.setNotice((e as Error).message, 'danger'); }
          finally { this.busy = false; }
          this.load();
        }
      }
    });
  }

  @Builder
  HierarchyBanner() {
    AppCard() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          StatusPill({
            label: this.currentEntityKind() === 'providers' ? '① 供应商连接'
              : this.currentEntityKind() === 'models' ? '② 模型定义' : '③ 角色策略',
            tone: 'accent'
          })
          Text(this.groupTitle())
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')

        Text(this.currentEntityKind() + '.' + this.currentEntityId())
          .fontSize(11).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint')).width('100%')

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          if (this.currentEntityKind() === 'providers') {
            Row() {
              ActionButton({ label: '发现模型目录', tone: 'secondary', compact: true, isEnabled: !this.busy,
                onTap: () => { this.discover(this.currentEntityId()); } })
            }.margin({ right: 8, bottom: 6 })
            Row() {
              ActionButton({ label: '+ 模型', tone: 'secondary', compact: true, isEnabled: !this.busy,
                onTap: () => { this.openCreate('models', this.currentEntityId()); } })
            }.margin({ right: 8, bottom: 6 })
          }
          if (this.currentEntityKind() === 'models') {
            Row() {
              ActionButton({ label: '+ 绑定角色', tone: 'secondary', compact: true, isEnabled: !this.busy,
                onTap: () => { this.openCreate('roles', this.currentEntityId()); } })
            }.margin({ right: 8, bottom: 6 })
          }
          Row() {
            ActionButton({
              label: '删除条目',
              tone: 'danger',
              compact: true,
              isEnabled: !this.busy && !this.currentEntityLocked() && Object.keys(this.draft).length === 0,
              onTap: () => { this.removeSelected(); }
            })
          }.margin({ bottom: 6 })
        }.width('100%')

        Column({ space: 8 }) {
          if (this.chainProvider() !== undefined) {
            Row({ space: 6 }) {
              Text('① 连接').fontSize(10.5).fontColor($r('app.color.tentacle_text_faint')).width(48)
              Text(this.entityTitle('providers', this.chainProvider()!))
                .fontSize(11.5)
                .fontColor(this.currentEntityKind() === 'providers' ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text'))
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(8)
                .backgroundColor(this.currentEntityKind() === 'providers' ? $r('app.color.tentacle_accent_soft') : $r('app.color.tentacle_bg_hover'))
                .onClick(() => this.navigate('连接 · ' + this.chainProvider()!.id))
            }.width('100%')
          }
          if (this.chainModels().length > 0) {
            Row({ space: 6 }) {
              Text('② 模型').fontSize(10.5).fontColor($r('app.color.tentacle_text_faint')).width(48)
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                ForEach(this.chainModels(), (m: ConfigEntity) => {
                  Text(this.entityTitle('models', m))
                    .fontSize(11.5)
                    .fontColor(this.currentEntityKind() === 'models' && this.currentEntityId() === m.id
                      ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text'))
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .margin({ right: 6, bottom: 4 })
                    .borderRadius(8)
                    .backgroundColor(this.currentEntityKind() === 'models' && this.currentEntityId() === m.id
                      ? $r('app.color.tentacle_accent_soft') : $r('app.color.tentacle_bg_hover'))
                    .onClick(() => this.navigate('模型 · ' + m.id))
                }, (m: ConfigEntity) => m.id)
              }.layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Top)
          }
          if (this.chainRoles().length > 0) {
            Row({ space: 6 }) {
              Text('③ 角色').fontSize(10.5).fontColor($r('app.color.tentacle_text_faint')).width(48)
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                ForEach(this.chainRoles(), (r: ConfigEntity) => {
                  Text(this.entityTitle('roles', r))
                    .fontSize(11.5)
                    .fontColor(this.currentEntityKind() === 'roles' && this.currentEntityId() === r.id
                      ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text'))
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .margin({ right: 6, bottom: 4 })
                    .borderRadius(8)
                    .backgroundColor(this.currentEntityKind() === 'roles' && this.currentEntityId() === r.id
                      ? $r('app.color.tentacle_accent_soft') : $r('app.color.tentacle_bg_hover'))
                    .onClick(() => this.navigate('角色 · ' + r.id))
                }, (r: ConfigEntity) => r.id)
              }.layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Top)
          }
        }
        .width('100%')
        .padding(10)
        .borderRadius(10)
        .backgroundColor($r('app.color.tentacle_bg_input'))
      }.width('100%')
    }
  }

  @Builder
  EntityRow(kind: string, entity: ConfigEntity, subtitle: string) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(this.entityTitle(kind, entity)).fontSize(13.5).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
        Text(subtitle).fontSize(11).fontColor($r('app.color.tentacle_text_faint')).maxLines(2).width('100%')
      }.layoutWeight(1)
      Text('›').fontSize(18).fontColor($r('app.color.tentacle_text_faint'))
    }.width('100%').padding({ top: 9, bottom: 9 })
      .onClick(() => this.navigate((kind === 'providers' ? '连接' : kind === 'models' ? '模型' : '角色') + ' · ' + entity.id))
  }

  @Builder
  EntityTree() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('连接 · 模型 · 角色').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
        ActionButton({ label: '+ 连接', tone: 'primary', compact: true, isEnabled: !this.busy,
          onTap: () => { this.openCreate('providers'); } })
      }.width('100%')
      TextInput({ text: this.search, placeholder: '搜索连接、模型或角色…' }).fontSize(13).height(38)
        .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
        .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10)
        .onChange((value: string) => this.search = value)
      Row() {
        Text((this.data?.entities.providers.length ?? 0) + ' 连接 · ' + (this.data?.entities.models.length ?? 0) + ' 模型 · ' +
          (this.data?.entities.roles.length ?? 0) + ' 角色')
          .fontSize(11).fontColor($r('app.color.tentacle_text_faint')).layoutWeight(1)
        Text('全部收起').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).padding(6)
          .onClick(() => { this.expandedProviders = []; this.expandedModels = []; this.search = ''; })
      }.width('100%')
      ForEach(this.visibleProviders(), (provider: ConfigEntity) => {
        AppCard() {
          Column() {
            Row({ space: 8 }) {
              Text(this.expandedProviders.includes(provider.id) || this.search ? '⌄' : '›').fontSize(18)
                .fontColor($r('app.color.tentacle_text_dim')).width(22).height(42).textAlign(TextAlign.Center)
                .onClick(() => this.toggleProvider(provider.id))
              Column({ space: 3 }) {
                Text(this.entityTitle('providers', provider)).fontSize(14.5).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
                Text((this.data?.provider_types[provider.type ?? '']?.label ?? provider.type ?? '') + ' · ' + this.modelsFor(provider.id).length + ' 模型')
                  .fontSize(11).fontColor($r('app.color.tentacle_text_faint')).width('100%')
              }.layoutWeight(1).onClick(() => this.toggleProvider(provider.id))
              StatusPill({
                label: this.data?.connection_status[provider.id]?.configured ? '就绪' : '待配置',
                tone: this.data?.connection_status[provider.id]?.configured ? 'ok' : 'default'
              })
              Text('配置 ›').fontSize(12).fontColor($r('app.color.tentacle_accent')).padding({ left: 6, top: 10, bottom: 10 })
                .onClick(() => this.navigate('连接 · ' + provider.id))
            }.width('100%')
            if (this.expandedProviders.includes(provider.id) || this.search) {
              Divider().color($r('app.color.tentacle_border')).margin({ top: 8, bottom: 4 })
              ForEach(this.modelsFor(provider.id).filter((m: ConfigEntity) => !this.search || this.entityMatches('providers', provider) || this.visibleModel(m)), (model: ConfigEntity) => {
                Column() {
                  Row({ space: 6 }) {
                    Text(this.expandedModels.includes(model.id) || this.search ? '⌄' : '›').fontSize(16)
                      .fontColor($r('app.color.tentacle_text_faint')).width(22).height(40).textAlign(TextAlign.Center)
                      .onClick(() => this.toggleModel(model.id))
                    Column({ space: 2 }) {
                      Text(this.entityTitle('models', model)).fontSize(13).fontColor($r('app.color.tentacle_text')).width('100%')
                      Text(this.rolesFor(model.id).length + ' 个绑定角色').fontSize(11).fontColor($r('app.color.tentacle_text_faint')).width('100%')
                    }.layoutWeight(1).onClick(() => this.toggleModel(model.id))
                    Text('配置 ›').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).padding({ left: 6, top: 10, bottom: 10 })
                      .onClick(() => this.navigate('模型 · ' + model.id))
                  }.width('100%')
                  if (this.expandedModels.includes(model.id) || this.search) {
                    Column() {
                      ForEach(this.rolesFor(model.id), (role: ConfigEntity) => {
                        this.EntityRow('roles', role, role.id + (role.id === this.data?.active_role ? ' · 当前主对话' : ''))
                      }, (role: ConfigEntity) => role.id)
                    }.width('100%').padding({ left: 14, right: 10 }).backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10)
                  }
                }.width('100%').padding({ left: 8 })
              }, (model: ConfigEntity) => model.id)
            }
          }.width('100%')
        }
      }, (provider: ConfigEntity) => provider.id)
      if (this.visibleProviders().length === 0) {
        Text(this.search ? '没有匹配的连接、模型或角色' : '尚未配置连接').fontSize(13).fontColor($r('app.color.tentacle_text_faint')).padding(24)
      }
      Row({ space: 8 }) {
        ActionButton({ label: '+ 模型', tone: 'secondary', compact: true, isEnabled: !this.busy,
          onTap: () => { this.openCreate('models'); } })
        ActionButton({ label: '+ 角色', tone: 'secondary', compact: true, isEnabled: !this.busy,
          onTap: () => { this.openCreate('roles'); } })
      }.width('100%')
    }.width('100%')
  }

  @Builder
  CreateEditor() {
    AppCard() {
      Column({ space: 10 }) {
        SectionTitle({ title: this.createKind === 'providers' ? '新增供应商连接' : this.createKind === 'models' ? '新增模型定义' : '新增模型角色' })
        TextInput({ text: this.createId, placeholder: '内部标识 ID（留空自动生成）' })
          .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
          .onChange((v: string) => this.createId = v)
        TextInput({ text: this.createLabel, placeholder: '显示备注名称（可选）' })
          .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
          .onChange((v: string) => this.createLabel = v)
        if (this.createKind === 'providers') {
          Select(this.options(this.providerTypes())).value(this.createType).fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
            .width('100%')
            .onSelect((i: number) => { this.createType = this.providerTypes()[i]; this.createUrl = this.data?.provider_types[this.createType]?.base_url ?? ''; })
          TextInput({ text: this.createUrl, placeholder: 'API Base URL' })
            .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
            .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
            .onChange((v: string) => this.createUrl = v)
          if (this.data?.provider_types[this.createType]?.auth === 'adc') {
            TextInput({ text: this.createProject, placeholder: 'Google Cloud 项目' })
              .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
              .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
              .onChange((v: string) => this.createProject = v)
            TextInput({ text: this.createLocation, placeholder: '区域（如 global）' })
              .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
              .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
              .onChange((v: string) => this.createLocation = v)
            TextInput({ text: this.createCredentialsEnv, placeholder: '凭据路径环境变量名（留空使用 ADC）' })
              .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
              .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
              .onChange((v: string) => this.createCredentialsEnv = v)
            TextInput({ text: this.createGcsBaseUrl, placeholder: 'GCS 地址（gs://BUCKET/PREFIX）' })
              .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
              .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
              .onChange((v: string) => this.createGcsBaseUrl = v)
          } else {
            TextInput({ text: this.createEnv, placeholder: '密钥环境变量名（如 OPENAI_API_KEY）' })
              .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
              .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
              .onChange((v: string) => this.createEnv = v)
          }
        } else {
          Select(this.options(this.createKind === 'models' ? (this.data?.entities.providers ?? []).map((e: ConfigEntity) => e.id) :
            (this.data?.entities.models ?? []).map((e: ConfigEntity) => e.id))).value(this.createParent)
            .width('100%')
            .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input')).onSelect((i: number) => {
              this.createParent = this.createKind === 'models' ? this.data?.entities.providers[i].id ?? '' : this.data?.entities.models[i].id ?? '';
              if (this.createKind === 'models') {
                const prov = this.data?.entities.providers.find((p: ConfigEntity) => p.id === this.createParent);
                const spec = prov?.type ? this.data?.provider_types[prov.type] : undefined;
                if (spec !== undefined) { this.createApiStyle = spec.api_style || spec.protocols[0] || 'chat'; }
              }
            })
          if (this.createKind === 'models') {
            TextInput({ text: this.createName, placeholder: '远端模型名称（如 deepseek-chat / gpt-4.1）' })
              .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
              .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
              .onChange((v: string) => this.createName = v)
            Row({ space: 8 }) {
              TextInput({ text: this.createApiStyle, placeholder: 'API 协议' }).layoutWeight(1)
                .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
                .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
                .onChange((v: string) => this.createApiStyle = v)
              TextInput({ text: this.createContextWindow, placeholder: '上下文窗口' }).layoutWeight(1)
                .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
                .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
                .onChange((v: string) => this.createContextWindow = v)
            }.width('100%')
            Row() {
              Text('支持视觉图片输入').fontSize(13).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.createVision })
                .selectedColor($r('app.color.tentacle_accent'))
                .onChange((on: boolean) => this.createVision = on)
            }.width('100%')
          }
        }
        Row({ space: 8 }) {
          ActionButton({ label: '取消', tone: 'secondary', compact: true, isEnabled: !this.busy,
            onTap: () => { this.createKind = ''; } })
          ActionButton({ label: '校验并预览', tone: 'primary', compact: true, isEnabled: !this.busy && this.preview === null,
            onTap: () => { this.create(); } })
        }.width('100%')
      }.width('100%').enabled(!this.busy && this.preview === null)
    }
  }

  @Builder
  Inspector() {
    Column({ space: 12 }) {
      if (this.section === 'models') {
        Row({ space: 8 }) {
          ActionButton({ label: '‹ 返回连接树', tone: 'ghost', compact: true, isEnabled: !this.busy,
            onTap: () => { this.inspecting = false; this.fieldSearch = ''; } })
          Blank()
        }.width('100%')
        this.HierarchyBanner()
      } else if (this.uiSectionGroups().length > 1) {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.uiSectionGroups(), (grp: string) => {
              Row({ space: 5 }) {
                Text(grp)
                  .fontSize(12)
                  .fontWeight(this.group === grp ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.group === grp ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
                if (this.groupDirtyCount(grp) > 0) {
                  Column().width(5).height(5).borderRadius(2.5)
                    .backgroundColor(this.group === grp ? '#FFFFFF' : '#D4A359')
                }
              }
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor(this.group === grp ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_card'))
              .border({ width: 0.5, color: this.group === grp ? Color.Transparent : $r('app.color.tentacle_border') })
              .onClick(() => this.selectEntityGroup(grp))
            }, (grp: string) => grp)
          }.padding({ bottom: 2 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      }

      // 字段检索与仅看已改工具条
      Row({ space: 8 }) {
        TextInput({ text: this.fieldSearch, placeholder: '检索参数名、路径或说明…' })
          .layoutWeight(1).height(36).fontSize(12.5)
          .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10)
          .onChange((v: string) => { if (v !== this.fieldSearch) { this.fieldSearch = v; } })
        if (Object.keys(this.draft).length > 0) {
          Text('仅看已改 (' + Object.keys(this.draft).length.toString() + ')')
            .fontSize(11.5)
            .fontColor(this.showDirtyOnly ? '#D4A359' : $r('app.color.tentacle_text_dim'))
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .borderRadius(10)
            .backgroundColor(this.showDirtyOnly ? '#24D4A359' : $r('app.color.tentacle_bg_card'))
            .border({ width: 0.5, color: $r('app.color.tentacle_border') })
            .onClick(() => { this.showDirtyOnly = !this.showDirtyOnly; })
        }
      }.width('100%')

      AppCard() {
        Column({ space: 4 }) {
          SectionTitle({ title: this.section === 'models' ? '基础配置' : this.group })
          if (this.visibleEditorFields(this.section === 'models' ? 'common' : 'all').length === 0) {
            Text('当前筛选条件下暂无匹配配置项').fontSize(12).fontColor($r('app.color.tentacle_text_faint')).padding({ top: 10, bottom: 6 })
          } else {
            ForEach(this.visibleEditorFields(this.section === 'models' ? 'common' : 'all'), (f: ConfigField) => {
              ConfigFieldEditor({
                field: f,
                snapshot: this.data,
                draft: $draft,
                pageBusy: this.busy,
                onEdit: (fld: ConfigField, v: ConfigValue) => { this.edit(fld, v); },
                onToggleTool: (fld: ConfigField, nm: string, on: boolean) => { this.toggleTool(fld, nm, on); },
                onOpenEnv: (fld: ConfigField) => { this.openEnvEditor(fld); }
              })
            }, (f: ConfigField) => f.path)
          }
        }.width('100%')
      }

      if (this.section === 'models') {
        if (this.visibleEditorFields('advanced').length > 0) {
          AppCard() {
            Column() {
              Row() {
                Text('高级参数 (' + this.visibleEditorFields('advanced').length.toString() + ')')
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
                Text(this.advancedOpen || this.fieldSearch.length > 0 || this.showDirtyOnly ? '收起 ⌃' : '展开 ⌄')
                  .fontSize(12).fontColor($r('app.color.tentacle_text_faint'))
              }.width('100%').padding({ top: 4, bottom: 4 }).onClick(() => this.advancedOpen = !this.advancedOpen)
              if (this.advancedOpen || this.fieldSearch.length > 0 || this.showDirtyOnly) {
                ForEach(this.visibleEditorFields('advanced'), (f: ConfigField) => {
                  ConfigFieldEditor({
                    field: f,
                    snapshot: this.data,
                    draft: $draft,
                    pageBusy: this.busy,
                    onEdit: (fld: ConfigField, v: ConfigValue) => { this.edit(fld, v); },
                    onToggleTool: (fld: ConfigField, nm: string, on: boolean) => { this.toggleTool(fld, nm, on); },
                    onOpenEnv: (fld: ConfigField) => { this.openEnvEditor(fld); }
                  })
                }, (f: ConfigField) => f.path)
              }
            }.width('100%')
          }
        }
        if (this.visibleEditorFields('tools').length > 0) {
          AppCard() {
            Column() {
              Row() {
                Text('工具权限 (' + this.visibleEditorFields('tools').length.toString() + ')')
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
                Text(this.toolsOpen || this.fieldSearch.length > 0 || this.showDirtyOnly ? '收起 ⌃' : '展开 ⌄')
                  .fontSize(12).fontColor($r('app.color.tentacle_text_faint'))
              }.width('100%').padding({ top: 4, bottom: 4 }).onClick(() => this.toolsOpen = !this.toolsOpen)
              if (this.toolsOpen || this.fieldSearch.length > 0 || this.showDirtyOnly) {
                ForEach(this.visibleEditorFields('tools'), (f: ConfigField) => {
                  ConfigFieldEditor({
                    field: f,
                    snapshot: this.data,
                    draft: $draft,
                    pageBusy: this.busy,
                    onEdit: (fld: ConfigField, v: ConfigValue) => { this.edit(fld, v); },
                    onToggleTool: (fld: ConfigField, nm: string, on: boolean) => { this.toggleTool(fld, nm, on); },
                    onOpenEnv: (fld: ConfigField) => { this.openEnvEditor(fld); }
                  })
                }, (f: ConfigField) => f.path)
              }
            }.width('100%')
          }
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  CatalogPanel() {
    AppCard() {
      Column({ space: 12 }) {
        Row() {
          Text('模型目录 · ' + (this.catalog?.provider ?? '')).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
          ActionButton({ label: '返回', tone: 'secondary', compact: true, isEnabled: !this.busy,
            onTap: () => { this.catalog = null; this.preview = null; } })
        }.width('100%')
        if (this.catalog?.notice) {
          Text(this.catalog.notice).fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        }
        TextInput({ text: this.catalogSearch, placeholder: '搜索远端模型名称…' }).height(38).fontSize(13)
          .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10)
          .onChange((v: string) => this.catalogSearch = v)
        Select(this.options(this.data?.provider_types[this.data?.entities.providers.find((p: ConfigEntity) => p.id === this.catalog?.provider)?.type ?? '']?.protocols ?? []))
          .value(this.catalogProtocol).fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input')).width('100%')
          .onSelect((i: number, v: string) => { this.catalogProtocol = v; this.preview = null; })
        ForEach((this.catalog?.models ?? []).filter((m: CatalogModel) => !this.catalogSearch || m.name.toLowerCase().includes(this.catalogSearch.toLowerCase())), (m: CatalogModel) => {
          Row() {
            Text(m.name + (m.configured ? '（已配置）' : '')).fontSize(13).fontFamily('monospace').fontColor($r('app.color.tentacle_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Checkbox, isOn: this.selectedModels.includes(m.import_id) }).selectedColor($r('app.color.tentacle_accent')).enabled(!m.configured && !this.busy)
              .onChange((on: boolean) => {
                if (on && this.selectedModels.length >= 50) { this.setNotice('每批最多导入 50 个模型', 'danger'); return; }
                this.selectedModels = on ? this.selectedModels.concat([m.import_id]) : this.selectedModels.filter((id: string) => id !== m.import_id); this.preview = null;
              })
          }.width('100%').padding({ top: 5, bottom: 5 })
        }, (m: CatalogModel) => m.import_id)
        ActionButton({
          label: '预览导入 ' + this.selectedModels.length.toString() + ' 个模型',
          tone: 'primary',
          compact: true,
          isEnabled: !this.busy && this.selectedModels.length > 0,
          onTap: () => { this.importModels(); }
        })
      }.width('100%')
    }
  }

  @Builder
  PreviewPanel() {
    AppCard() {
      Column({ space: 14 }) {
        SectionTitle({ title: '确认配置变更预览' })
        Text('核对将写入 config.yaml 的差异，保存时将自动创建历史备份').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        ForEach(this.preview?.changes ?? [], (change: ConfigChange) => {
          Column({ space: 6 }) {
            Row({ space: 8 }) {
              Text(change.label).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
              StatusPill({ label: effectLabel(change.effect), tone: change.effect === 'restart' ? 'warn' : 'accent' })
            }.width('100%')
            Text('- ' + displayValue(change.before))
              .fontSize(11.5).fontFamily('monospace').fontColor($r('app.color.tentacle_danger')).width('100%')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(6).backgroundColor('#1FCF6A5F')
            Text('+ ' + displayValue(change.after))
              .fontSize(12).fontFamily('monospace').fontColor($r('app.color.tentacle_ok')).width('100%')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(6).backgroundColor('#1F7FA66A')
            if (change.impact && change.impact.length > 0) {
              Text('影响：' + JSON.stringify(change.impact)).fontSize(11).fontColor($r('app.color.tentacle_text_dim')).width('100%')
            }
          }.width('100%').padding(10).borderRadius(10).backgroundColor($r('app.color.tentacle_bg_input'))
        }, (change: ConfigChange) => change.path)
        Row({ space: 8 }) {
          ActionButton({ label: '返回编辑', tone: 'secondary', compact: true, isEnabled: !this.busy,
            onTap: () => { this.preview = null; } })
          ActionButton({ label: '备份并保存', tone: 'primary', compact: true,
            isEnabled: !this.busy && (this.preview?.changes.length ?? 0) > 0,
            onTap: () => { this.save(); } })
        }.width('100%')
      }.width('100%')
    }
  }

  @Builder
  MaintenanceToolbox() {
    Column({ space: 12 }) {
      Row() {
        Text('配置维护与历史备份').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
        ActionButton({ label: '返回配置', tone: 'ghost', compact: true, isEnabled: !this.busy,
          onTap: () => { this.maintenanceOpen = false; } })
      }.width('100%')

      AppCard() {
        Column({ space: 10 }) {
          SectionTitle({ title: '运行状态与重载维护' })
          Text(this.data?.restart_required ? '存在需要重启应用主进程才能生效的配置修改'
            : this.data?.applying ? '正在等待当前对话回合结束后自动应用动态配置'
              : '所有配置已处于最新应用状态')
            .fontSize(12.5).fontColor($r('app.color.tentacle_text_dim')).width('100%')
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            Row() {
              ActionButton({ label: '应用动态配置', tone: 'secondary', compact: true,
                isEnabled: !this.busy && !this.dirty() && this.preview === null,
                onTap: () => { this.apply(); } })
            }.margin({ right: 8, bottom: 8 })
            Row() {
              ActionButton({ label: '重启应用', tone: 'danger', compact: true,
                isEnabled: !this.busy && !this.dirty() && this.preview === null &&
                  (this.data?.restart.available ?? false) && this.data?.restart.state === 'idle',
                onTap: () => { this.restart(false); } })
            }.margin({ right: 8, bottom: 8 })
            Row() {
              ActionButton({ label: '重算向量并重启', tone: 'accent', compact: true,
                isEnabled: !this.busy && !this.dirty() && this.preview === null &&
                  (this.data?.restart.available ?? false) && this.data?.restart.state === 'idle',
                onTap: () => { this.restart(true); } })
            }.margin({ bottom: 8 })
          }.width('100%')
        }.width('100%')
      }

      AppCard() {
        Column({ space: 10 }) {
          SectionTitle({ title: 'config.yaml 历史备份恢复' })
          if ((this.data?.history.length ?? 0) === 0) {
            Text('暂无自动生成的配置备份').fontSize(12).fontColor($r('app.color.tentacle_text_faint'))
          } else {
            ForEach(this.data?.history ?? [], (backup: ConfigBackup) => {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(new Date(backup.created_at * 1000).toLocaleString()).fontSize(12.5).fontColor($r('app.color.tentacle_text'))
                  Text(backup.id).fontSize(10.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint'))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                ActionButton({ label: '预览恢复', tone: 'secondary', compact: true,
                  isEnabled: !this.busy && !this.dirty(),
                  onTap: () => { this.restore(backup.id); } })
              }
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor($r('app.color.tentacle_bg_input'))
            }, (backup: ConfigBackup) => backup.id)
          }
        }.width('100%')
      }
    }.width('100%')
  }

  @Builder
  EnvEditorPanel() {
    AppCard() {
      Column({ space: 12 }) {
        SectionTitle({ title: '写入 .env 凭据' })
        Text(this.envTargetLabel + (this.envTargetName ? '（当前变量：' + this.envTargetName + '）' : ''))
          .fontSize(13).fontColor($r('app.color.tentacle_text')).width('100%')
        Text('值仅写入应用目录 .env 并生成受管变量引用，不会写入 config.yaml 或回显到界面。')
          .fontSize(11).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        TextInput({ text: this.envSecretValue, placeholder: '请输入密钥或凭据值（提交后不回显）' })
          .type(InputType.Password)
          .fontSize(14).fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).width('100%')
          .onChange((v: string) => this.envSecretValue = v)
        Row({ space: 8 }) {
          ActionButton({ label: '取消', tone: 'secondary', compact: true, isEnabled: !this.busy,
            onTap: () => { this.cancelEnvEditor(); } })
          ActionButton({ label: '安全写入 .env', tone: 'primary', compact: true,
            isEnabled: !this.busy && this.envSecretValue.trim().length > 0,
            onTap: () => { this.saveEnvSecret(); } })
        }.width('100%')
      }.width('100%')
    }
  }

  build() {
    Column() {
      // 紧凑顶部摘要与维护工具条（不再重复占高标题）
      Row({ space: 6 }) {
        if (this.data?.active_model?.name) {
          StatusPill({ label: '主模型 ' + this.data.active_model.name, tone: 'accent' })
        }
        if (this.data?.restart_required) {
          StatusPill({ label: '待重启', tone: 'warn' })
        }
        Blank()
        ActionButton({
          label: this.maintenanceOpen ? '编辑配置' : '维护工具',
          tone: this.maintenanceOpen ? 'primary' : 'secondary',
          compact: true,
          isEnabled: !this.busy && this.preview === null && !this.createKind && this.catalog === null && !this.envTargetPath,
          onTap: () => { this.maintenanceOpen = !this.maintenanceOpen; }
        })
        ActionButton({ label: '刷新', tone: 'secondary', compact: true, isEnabled: !this.busy,
          onTap: () => { this.refresh(); } })
      }.width('100%').padding({ left: 14, right: 14, top: 4, bottom: 8 })

      // 4 分类导航栏（与 Web configGrouping 对齐）
      if (!this.maintenanceOpen && this.preview === null && !this.createKind && this.catalog === null && !this.envTargetPath) {
        Scroll() {
          Row({ space: 6 }) {
            ForEach([
              ['models', '模型与连接'],
              ['memory', '记忆系统'],
              ['runtime', '运行与调度'],
              ['channels', '通道与媒体'],
            ], (item: string[]) => {
              Row({ space: 5 }) {
                Text(item[1])
                  .fontSize(12.5)
                  .fontWeight(this.section === item[0] ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.section === item[0] ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text_dim'))
                if (this.uiSectionCount(item[0]) > 0) {
                  Text(this.uiSectionCount(item[0]).toString())
                    .fontSize(10)
                    .fontColor(this.section === item[0] ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text_faint'))
                    .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                    .borderRadius(999)
                    .backgroundColor(this.section === item[0] ? $r('app.color.tentacle_accent_soft') : $r('app.color.tentacle_bg_hover'))
                }
                if (this.uiSectionDirtyCount(item[0]) > 0) {
                  Column().width(6).height(6).borderRadius(3).backgroundColor('#D4A359')
                }
              }
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .borderRadius(10)
              .backgroundColor(this.section === item[0] ? $r('app.color.tentacle_accent_soft') : Color.Transparent)
              .onClick(() => this.switchUiSection(item[0]))
            }, (item: string[]) => item[0])
          }.padding({ left: 14, right: 14, bottom: 6 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
        Divider().color($r('app.color.tentacle_border'))
      }

      Scroll() {
        Column({ space: 12 }) {
          if (this.message) {
            FeedbackBanner({ text: this.message, tone: this.messageTone })
          }
          if (this.data === null) {
            LoadingProgress().width(28).height(28).color($r('app.color.tentacle_accent')).margin({ top: 36 })
          } else if (this.preview !== null) {
            this.PreviewPanel()
          } else if (this.envTargetPath) {
            this.EnvEditorPanel()
          } else if (this.createKind) {
            this.CreateEditor()
          } else if (this.catalog !== null) {
            this.CatalogPanel()
          } else if (this.maintenanceOpen) {
            this.MaintenanceToolbox()
          } else if (this.section === 'models') {
            if (this.inspecting) { this.Inspector() } else { this.EntityTree() }
          } else {
            this.Inspector()
          }
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 24 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)

      if (Object.keys(this.draft).length > 0 && this.preview === null && !this.createKind && this.catalog === null && !this.envTargetPath) {
        Row({ space: 8 }) {
          StatusPill({ label: Object.keys(this.draft).length.toString() + ' 项未保存', tone: 'warn' })
          Blank()
          ActionButton({ label: '放弃', tone: 'ghost', compact: true, isEnabled: !this.busy,
            onTap: () => { this.refresh(); } })
          ActionButton({ label: '预览并保存', tone: 'primary', compact: true, isEnabled: !this.busy,
            onTap: () => { this.previewChanges(); } })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 12 })
        .backgroundColor($r('app.color.tentacle_bg_elevated'))
        .border({ width: { top: 0.75 }, color: $r('app.color.tentacle_border') })
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.tentacle_bg'))
  }
}

@Component
struct ConfigFieldEditor {
  @Prop field: ConfigField = {
    path: '',
    label: '',
    kind: 'text',
    group: '',
    value: null,
    active: null,
    default: null,
    effect: 'restart',
    source: 'user',
    choices: [],
    nullable: false,
    inheritable: false,
    protected: false,
    pending: false,
    minimum: null,
    maximum: null,
    help: ''
  };
  @Prop snapshot: ConfigSnapshot | null = null;
  @Link draft: Record<string, ConfigValue>;
  @Prop pageBusy: boolean = false;
  onEdit: (f: ConfigField, v: ConfigValue) => void = () => {};
  onToggleTool: (f: ConfigField, name: string, on: boolean) => void = () => {};
  onOpenEnv: (f: ConfigField) => void = () => {};

  private selectOptions(values: string[]): SelectOption[] {
    return values.map((v: string): SelectOption => ({ value: v }));
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.field.label).fontSize(13.5).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
        if (this.draft[this.field.path] !== undefined) {
          StatusPill({ label: '已改', tone: 'warn' })
        }
        Text(effectLabel(this.field.effect)).fontSize(10).fontColor($r('app.color.tentacle_text_faint'))
      }.width('100%')

      if (this.field.inheritable) {
        Row() {
          Text(this.field.source === 'default' && this.draft[this.field.path] === undefined ? '继承模型参数' : '角色自定义')
            .fontSize(11).fontColor($r('app.color.tentacle_text_faint')).layoutWeight(1)
          Text('恢复继承').fontSize(11.5).fontColor($r('app.color.tentacle_accent')).padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .enabled(!isConfigFieldLocked(this.field, this.pageBusy))
            .onClick(() => this.onEdit(this.field, { $inherit: true }))
        }.width('100%')
      }

      if (this.field.nullable) {
        Row() {
          Text(this.field.kind === 'proxy' ? '继承环境代理' : '不指定，使用默认行为')
            .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: resolveConfigValue(this.snapshot, this.draft, this.field) === null })
            .selectedColor($r('app.color.tentacle_accent'))
            .enabled(!isConfigFieldLocked(this.field, this.pageBusy))
            .onChange((on: boolean) => {
              const curIsNull = resolveConfigValue(this.snapshot, this.draft, this.field) === null;
              if (on === curIsNull) { return; }
              this.onEdit(this.field, on ? null : this.field.kind === 'tools' || this.field.kind === 'string_list' ? []
                : this.field.kind === 'number' || this.field.kind === 'integer' ? 0 : '');
            })
        }.width('100%')
      }

      if (this.field.kind === 'boolean') {
        Toggle({ type: ToggleType.Switch, isOn: resolveConfigValue(this.snapshot, this.draft, this.field) === true })
          .selectedColor($r('app.color.tentacle_accent'))
          .enabled(!isConfigFieldLocked(this.field, this.pageBusy))
          .onChange((on: boolean) => {
            const curVal = resolveConfigValue(this.snapshot, this.draft, this.field);
            if (this.field.nullable && curVal === null) { return; }
            if (on !== (curVal === true)) { this.onEdit(this.field, on); }
          })
      } else if (this.field.kind === 'tools') {
        ForEach(resolveConfigTools(this.snapshot, this.draft, this.field), (name: string) => {
          Row() {
            Text(name).fontSize(12.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text_dim')).layoutWeight(1)
            Toggle({
              type: ToggleType.Checkbox,
              isOn: Array.isArray(resolveConfigValue(this.snapshot, this.draft, this.field)) &&
                (resolveConfigValue(this.snapshot, this.draft, this.field) as string[]).includes(name)
            })
              .selectedColor($r('app.color.tentacle_accent'))
              .enabled(!isConfigFieldLocked(this.field, this.pageBusy) &&
                resolveConfigValue(this.snapshot, this.draft, this.field) !== null)
              .onChange((on: boolean) => {
                const curVal = resolveConfigValue(this.snapshot, this.draft, this.field);
                if (this.field.nullable && curVal === null) { return; }
                const checked = Array.isArray(curVal) && (curVal as string[]).includes(name);
                if (on !== checked) { this.onToggleTool(this.field, name, on); }
              })
          }.width('100%').padding({ top: 3, bottom: 3 })
        }, (name: string) => name)
      } else if (this.field.kind === 'string_list') {
        TextArea({
          text: formatConfigText(this.snapshot, this.draft, this.field),
          placeholder: this.field.help || '每行填写一项'
        })
          .enabled(!isConfigFieldLocked(this.field, this.pageBusy) &&
            resolveConfigValue(this.snapshot, this.draft, this.field) !== null)
          .fontSize(13.5).fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') })
          .borderRadius(10).height(88).width('100%')
          .onChange((v: string) => {
            const curVal = resolveConfigValue(this.snapshot, this.draft, this.field);
            if (this.field.nullable && curVal === null) { return; }
            if (v === formatConfigText(this.snapshot, this.draft, this.field)) { return; }
            const parsed = parseStringListLines(v);
            if (this.draft[this.field.path] === undefined && JSON.stringify(parsed) === JSON.stringify(curVal)) { return; }
            this.onEdit(this.field, parsed);
          })
      } else if (resolveConfigChoices(this.snapshot, this.draft, this.field).length > 0) {
        Select(this.selectOptions(resolveConfigChoices(this.snapshot, this.draft, this.field)))
          .value(formatConfigText(this.snapshot, this.draft, this.field))
          .font({ size: 13.5 })
          .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .selectedOptionBgColor($r('app.color.tentacle_accent_soft')).selectedOptionFontColor($r('app.color.tentacle_accent'))
          .enabled(!isConfigFieldLocked(this.field, this.pageBusy) &&
            resolveConfigValue(this.snapshot, this.draft, this.field) !== null)
          .onSelect((index: number) => {
            const curVal = resolveConfigValue(this.snapshot, this.draft, this.field);
            if (this.field.nullable && curVal === null) { return; }
            const chosen = resolveConfigChoices(this.snapshot, this.draft, this.field)[index];
            if (chosen !== undefined && chosen !== formatConfigText(this.snapshot, this.draft, this.field)) {
              this.onEdit(this.field, chosen);
            }
          })
          .width('100%')
      } else if (this.field.multiline) {
        TextArea({
          text: formatConfigText(this.snapshot, this.draft, this.field),
          placeholder: this.field.help
        })
          .enabled(!isConfigFieldLocked(this.field, this.pageBusy) &&
            resolveConfigValue(this.snapshot, this.draft, this.field) !== null)
          .fontSize(13.5).fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') })
          .borderRadius(10).height(96).width('100%')
          .onChange((v: string) => {
            const curVal = resolveConfigValue(this.snapshot, this.draft, this.field);
            if (this.field.nullable && curVal === null) { return; }
            if (v !== formatConfigText(this.snapshot, this.draft, this.field)) {
              this.onEdit(this.field, v);
            }
          })
      } else {
        TextInput({
          text: formatConfigText(this.snapshot, this.draft, this.field),
          placeholder: this.field.help
        })
          .enabled(!isConfigFieldLocked(this.field, this.pageBusy) &&
            resolveConfigValue(this.snapshot, this.draft, this.field) !== null)
          .fontSize(13.5).fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') })
          .borderRadius(10).height(40).width('100%')
          .onChange((v: string) => {
            const curVal = resolveConfigValue(this.snapshot, this.draft, this.field);
            if (this.field.nullable && curVal === null) { return; }
            if (v !== formatConfigText(this.snapshot, this.draft, this.field)) {
              this.onEdit(this.field, v);
            }
          })
      }

      if (this.field.kind === 'env') {
        Row({ space: 8 }) {
          StatusPill({ label: this.field.configured ? '.env 已配置' : '.env 未设置', tone: this.field.configured ? 'ok' : 'warn' })
          Blank()
          ActionButton({
            label: this.field.configured ? '更新 .env 值' : '写入 .env 值',
            tone: 'accent',
            compact: true,
            isEnabled: !isConfigFieldLocked(this.field, this.pageBusy),
            onTap: () => { this.onOpenEnv(this.field); }
          })
        }.width('100%')
      }

      if (this.field.help || this.field.pending || this.field.protected) {
        Text((this.field.help || '') + (this.field.pending ? '\n当前生效：' + displayValue(this.field.active) : '') +
          (this.field.protected ? '\n由主机管理认证信息' : ''))
          .fontSize(11).lineHeight(16).fontColor($r('app.color.tentacle_text_faint')).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 10, bottom: 12 })
  }
}

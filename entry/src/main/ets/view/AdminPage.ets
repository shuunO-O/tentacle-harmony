/**
 * 记忆库管理页：raw_messages / sessions / summaries / goals / tasks + SQL 控制台
 */

import { FieldDef, TableData } from '../model/Types';
import { TentacleApi } from '../service/TentacleApi';
import { EditDialog } from '../components/EditDialog';
import { FilesPage } from './FilesPage';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle, StatusPill } from '../components/UiKit';
import { BackupSettings } from '../components/SettingsExtras';

@Component
export struct AdminPage {
  @State tableName: string = 'raw_messages';
  @State tableData: TableData = new TableData();
  @State goalsCache: TableData = new TableData();
  @State pageTotal: number = 0;
  @State pageOffset: number = 0;
  @State limit: number = 10;
  @State fRole: string = '';
  @State fPlatform: string = '';
  @State fSession: string = '';
  @State fQ: string = '';
  @State errText: string = '';
  @State sqlInput: string = '';
  @State sqlResult: TableData = new TableData();
  @State sqlMsg: string = '';
  @State sqlOpen: boolean = false;
  @State renderKey: number = 0;
  private dialogController: CustomDialogController | null = null;
  private tabNames: string[] = ['raw_messages', 'sessions', 'summaries', 'goals', 'tasks', 'files', 'backups'];
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.load(false);
  }

  private tabTitle(name: string): string {
    const titles: Record<string, string> = { 'raw_messages': '消息', 'sessions': '会话', 'summaries': '摘要', 'goals': '目标', 'tasks': '任务', 'files': '文件', 'backups': '备份' };
    return titles[name] ?? name;
  }

  private fmtTime(ts: number): string {
    if (ts <= 0) {
      return '-';
    }
    const d = new Date(ts * 1000);
    const p = (n: number): string => n.toString().padStart(2, '0');
    return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  private clamp(s: string, n: number): string {
    if (s.length <= n) {
      return s;
    }
    return s.substring(0, n) + '…';
  }

  private async load(reset: boolean): Promise<void> {
    if (reset) {
      this.pageOffset = 0;
    }
    const seq = this.loadSeq + 1;
    this.loadSeq = seq;
    const target: string = this.tableName;
    if (target === 'files' || target === 'backups') { return; }
    const api = TentacleApi.getInstance();
    try {
      if (target === 'raw_messages') {
        const d = await api.getAdminMessages(this.pageOffset, this.limit, this.fRole, this.fPlatform, this.fSession, this.fQ);
        if (this.loadSeq === seq) {
          this.tableData = d;
          this.pageTotal = d.total;
          this.renderKey = this.renderKey + 1;
          this.errText = '';
        }
      } else if (target === 'sessions') {
        const d = await api.getAdminSessions(this.pageOffset, this.limit);
        if (this.loadSeq === seq) {
          this.tableData = d;
          this.pageTotal = d.total;
          this.renderKey = this.renderKey + 1;
          this.errText = '';
        }
      } else if (target === 'summaries') {
        const d = await api.getAdminSummaries(this.pageOffset, this.limit);
        if (this.loadSeq === seq) {
          this.tableData = d;
          this.pageTotal = d.total;
          this.renderKey = this.renderKey + 1;
          this.errText = '';
        }
      } else if (target === 'goals') {
        const d = await api.getAdminGoals();
        if (this.loadSeq === seq) {
          this.goalsCache = d;
          this.pageTotal = 0;
          this.renderKey = this.renderKey + 1;
          this.errText = '';
        }
      } else if (target === 'tasks') {
        const d = await api.getAdminTasks();
        if (this.loadSeq === seq) {
          this.tableData = d;
          this.pageTotal = 0;
          this.renderKey = this.renderKey + 1;
          this.errText = '';
        }
        if (this.goalsCache.columns.length === 0) {
          const g = await api.getAdminGoals();
          if (this.loadSeq === seq) {
            this.goalsCache = g;
            this.renderKey = this.renderKey + 1;
          }
        }
      }
    } catch (e) {
      if (this.loadSeq === seq) {
        this.errText = e.message;
      }
    }
  }

  // ---------- 分页 ----------

  private pageNo(): number {
    return Math.floor(this.pageOffset / this.limit) + 1;
  }

  private totalPages(): number {
    if (this.pageTotal <= 0) {
      return 1;
    }
    return Math.max(1, Math.ceil(this.pageTotal / this.limit));
  }

  private prevPage(): void {
    this.pageOffset = Math.max(0, this.pageOffset - this.limit);
    this.load(false);
  }

  private nextPage(): void {
    if (this.pageOffset + this.limit >= this.pageTotal) {
      return;
    }
    this.pageOffset = this.pageOffset + this.limit;
    this.load(false);
  }

  // ---------- 删除 ----------

  private onDeleteRow(kind: string, row: Array<string>): void {
    AlertDialog.show({
      title: '确认删除',
      message: '确认删除 ' + kind + ' #' + row[0] + '？此操作不可恢复。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: () => {
          this.doDelete(kind, Number(row[0]));
        }
      }
    });
  }

  private async doDelete(kind: string, id: number): Promise<void> {
    try {
      const api = TentacleApi.getInstance();
      if (kind === 'messages') {
        await api.deleteMessage(id);
      } else if (kind === 'summaries') {
        await api.deleteSummary(id);
      }
      this.load(false);
    } catch (e) {
      this.errText = e.message;
    }
  }

  // ---------- 对话框 ----------

  private newField(key: string, label: string, type: string, options: string[], value: string, placeholder: string): FieldDef {
    const f = new FieldDef();
    f.key = key;
    f.label = label;
    f.type = type;
    f.options = options;
    f.value = value;
    f.placeholder = placeholder;
    return f;
  }

  private fieldValue(fields: FieldDef[], key: string): string {
    for (let i = 0; i < fields.length; i++) {
      if (fields[i].key === key) {
        return fields[i].value;
      }
    }
    return '';
  }

  private openDialog(title: string, fields: FieldDef[], onConfirm: (fs: FieldDef[]) => void): void {
    const ctrl = new CustomDialogController({
      builder: EditDialog({ title: title, fields: fields, onConfirm: onConfirm }),
      autoCancel: true,
      customStyle: true,
      backgroundColor: Color.Transparent,
    });
    this.dialogController = ctrl;
    ctrl.open();
  }

  // ---------- goals ----------

  private goalOptions(): string[] {
    const opts: string[] = [];
    for (let i = 0; i < this.goalsCache.rows.length; i++) {
      const r = this.goalsCache.rows[i];
      if (r[3] === 'active') {
        opts.push('#' + r[0] + ' ' + this.clamp(r[1], 18));
      }
    }
    return opts;
  }

  private goalIdFromLabel(label: string): number {
    const sp = label.indexOf(' ');
    if (sp < 0) {
      return 0;
    }
    return Number(label.substring(1, sp));
  }

  private openGoalCreate(): void {
    const fields: FieldDef[] = [];
    fields.push(this.newField('description', '目标描述', 'textarea', [], '', ''));
    fields.push(this.newField('priority', '优先级', 'select', ['high', 'medium', 'low'], 'medium', ''));
    this.openDialog('新建 goal', fields, (fs: FieldDef[]) => {
      const desc = this.fieldValue(fs, 'description');
      if (desc.trim().length === 0) {
        return;
      }
      TentacleApi.getInstance().createGoal(desc, this.fieldValue(fs, 'priority'))
        .then(() => {
          this.load(true);
        }).catch((e: Error) => {
        this.errText = e.message;
      });
    });
  }

  private openGoalEdit(row: Array<string>): void {
    const fields: FieldDef[] = [];
    fields.push(this.newField('description', '目标描述', 'textarea', [], row[1], ''));
    fields.push(this.newField('priority', '优先级', 'select', ['high', 'medium', 'low'], row[2], ''));
    fields.push(this.newField('result', '结果记录', 'textarea', [], row[4], ''));
    fields.push(this.newField('status', '状态', 'select', ['active', 'inactive'], row[3], ''));
    this.openDialog('编辑 goal #' + row[0], fields, (fs: FieldDef[]) => {
      TentacleApi.getInstance().updateGoal(Number(row[0]),
        this.fieldValue(fs, 'description'), this.fieldValue(fs, 'priority'),
        this.fieldValue(fs, 'result'), this.fieldValue(fs, 'status'))
        .then(() => {
          this.load(true);
        }).catch((e: Error) => {
        this.errText = e.message;
      });
    });
  }

  private archiveGoal(row: Array<string>): void {
    AlertDialog.show({
      title: '归档 goal',
      message: '确认将 goal #' + row[0] + ' 归档（置为 inactive）？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '归档',
        action: () => {
          TentacleApi.getInstance().archiveGoal(Number(row[0]))
            .then(() => {
              this.load(false);
            }).catch((e: Error) => {
            this.errText = e.message;
          });
        }
      }
    });
  }

  // ---------- tasks ----------

  private openTaskCreate(): void {
    const opts = this.goalOptions();
    if (opts.length === 0) {
      AlertDialog.show({ message: '没有 active 的 goal，请先创建 goal' });
      return;
    }
    const fields: FieldDef[] = [];
    fields.push(this.newField('goal_id', '所属 goal', 'select', opts, opts[0], ''));
    fields.push(this.newField('content', '任务内容', 'textarea', [], '', ''));
    fields.push(this.newField('urgency', '紧急度', 'select', ['high', 'medium', 'low'], 'medium', ''));
    this.openDialog('新建 task', fields, (fs: FieldDef[]) => {
      const content = this.fieldValue(fs, 'content');
      if (content.trim().length === 0) {
        return;
      }
      TentacleApi.getInstance().createTask(this.goalIdFromLabel(this.fieldValue(fs, 'goal_id')),
        content, this.fieldValue(fs, 'urgency'))
        .then(() => {
          this.load(true);
        }).catch((e: Error) => {
        this.errText = e.message;
      });
    });
  }

  private openTaskEdit(row: Array<string>): void {
    const fields: FieldDef[] = [];
    fields.push(this.newField('content', '任务内容', 'textarea', [], row[1], ''));
    fields.push(this.newField('urgency', '紧急度', 'select', ['high', 'medium', 'low'], row[4], ''));
    fields.push(this.newField('status', '状态', 'select', ['pending', 'in_progress', 'completed'], row[2], ''));
    const opts = this.goalOptions();
    let curGoal = '#' + row[3] + ' ' + this.clamp(row[1], 18);
    let goalValue = '';
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].indexOf('#' + row[3] + ' ') === 0) {
        goalValue = opts[i];
      }
    }
    if (goalValue.length === 0 && opts.length > 0) {
      goalValue = opts[0];
    }
    fields.push(this.newField('goal_id', '所属 goal', 'select', opts, goalValue, ''));
    this.openDialog('编辑 task #' + row[0], fields, (fs: FieldDef[]) => {
      const status = this.fieldValue(fs, 'status');
      const goalLabel = this.fieldValue(fs, 'goal_id');
      TentacleApi.getInstance().updateTask(Number(row[0]),
        this.fieldValue(fs, 'content'), this.fieldValue(fs, 'urgency'),
        status, this.goalIdFromLabel(goalLabel))
        .then(() => {
          this.load(true);
        }).catch((e: Error) => {
        this.errText = e.message;
      });
    });
  }

  private deleteTask(row: Array<string>): void {
    AlertDialog.show({
      title: '删除 task',
      message: '确认删除 task #' + row[0] + '？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: () => {
          TentacleApi.getInstance().deleteTask(Number(row[0]))
            .then(() => {
              this.load(false);
            }).catch((e: Error) => {
            this.errText = e.message;
          });
        }
      }
    });
  }

  // ---------- SQL ----------

  private async runSql(): Promise<void> {
    const sql = this.sqlInput.trim();
    if (sql.length === 0) {
      return;
    }
    this.sqlMsg = '执行中…';
    try {
      const d = await TentacleApi.getInstance().runSql(sql);
      this.sqlResult = d;
      this.renderKey = this.renderKey + 1;
      this.sqlMsg = '返回 ' + d.row_count.toString() + ' 行' + (d.truncated ? '（已截断至 500 行）' : '');
    } catch (e) {
      this.sqlResult = new TableData();
      this.sqlMsg = '执行失败：' + e.message;
    }
  }

  // ---------- 渲染 ----------

  build() {
    Column() {
      Scroll() {
       Row({ space: 6 }) {
        ForEach(this.tabNames, (t: string, i: number) => {
          Text(this.tabTitle(t))
            .id('memory-' + t)
            .fontSize(12)
            .fontColor(t === this.tableName ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
            .fontWeight(t === this.tableName ? FontWeight.Medium : FontWeight.Normal)
            .textAlign(TextAlign.Center)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor(t === this.tableName ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_card'))
            .border({ width: 0.5, color: t === this.tableName ? Color.Transparent : $r('app.color.tentacle_border') })
            .onClick(() => {
              this.tableName = t;
              this.loadSeq++;
              this.load(true);
            })
        }, (t: string, i: number) => 'tab' + i.toString())
       }
      }
      .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      .width('100%')
      .padding({ left: 14, right: 14, top: 4, bottom: 8 })

      if (this.tableName === 'files') {
        Column() { FilesPage() }.width('100%').layoutWeight(1)
      } else if (this.tableName === 'backups') {
        Scroll() {
          Column() { BackupSettings() }.width('100%').padding({ left: 14, right: 14, top: 4, bottom: 20 })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      } else {
      Scroll() {
        Column({ space: 10 }) {
          if (this.tableName === 'raw_messages') {
            Column({ space: 6 }) {
              Row({ space: 6 }) {
                TextInput({ text: this.fRole, placeholder: 'role（如 user/assistant）' })
                  .onChange((v: string) => {
                    this.fRole = v;
                  })
                  .backgroundColor($r('app.color.tentacle_bg_input'))
                  .fontColor($r('app.color.tentacle_text'))
                  .layoutWeight(1)
                TextInput({ text: this.fPlatform, placeholder: 'platform' })
                  .onChange((v: string) => {
                    this.fPlatform = v;
                  })
                  .backgroundColor($r('app.color.tentacle_bg_input'))
                  .fontColor($r('app.color.tentacle_text'))
                  .layoutWeight(1)
              }
              .width('100%')
              Row({ space: 6 }) {
                TextInput({ text: this.fSession, placeholder: 'session_id' })
                  .onChange((v: string) => {
                    this.fSession = v;
                  })
                  .backgroundColor($r('app.color.tentacle_bg_input'))
                  .fontColor($r('app.color.tentacle_text'))
                  .layoutWeight(1)
                TextInput({ text: this.fQ, placeholder: '搜索内容…' })
                  .onChange((v: string) => {
                    this.fQ = v;
                  })
                  .backgroundColor($r('app.color.tentacle_bg_input'))
                  .fontColor($r('app.color.tentacle_text'))
                  .layoutWeight(1)
                ActionButton({
                  label: '筛选',
                  tone: 'primary',
                  compact: true,
                  onTap: () => { this.load(true); }
                })
              }
              .width('100%')
            }
            .width('100%')
            .padding(10)
            .backgroundColor($r('app.color.tentacle_bg_card'))
            .borderRadius(12)
            .border({ width: 0.5, color: $r('app.color.tentacle_border') })
          }

          if (this.tableName === 'goals') {
            Row() {
              ActionButton({
                label: '+ 新建 goal',
                tone: 'primary',
                compact: true,
                onTap: () => { this.openGoalCreate(); }
              })
              Blank()
            }
            .width('100%')
          } else if (this.tableName === 'tasks') {
            Row() {
              ActionButton({
                label: '+ 新建 task',
                tone: 'primary',
                compact: true,
                onTap: () => { this.openTaskCreate(); }
              })
              Blank()
            }
            .width('100%')
          }

          if (this.tableName === 'goals') {
            ForEach(this.goalsCache.rows, (row: Array<string>, gi: number) => {
              Column({ space: 6 }) {
                Row() {
                  Text(row[1])
                    .fontSize(15)
                    .fontColor($r('app.color.tentacle_text'))
                    .layoutWeight(1)
                  Text(row[3])
                    .fontSize(11)
                    .fontColor(row[3] === 'active' ? $r('app.color.tentacle_ok') : $r('app.color.tentacle_text_faint'))
                }
                .width('100%')

                Row() {
                  Text(row[2])
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_accent'))
                  Text('#' + row[0])
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_text_faint'))
                    .margin({ left: 8 })
                  Blank()
                  Text(this.fmtTime(Number(row[5])))
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_text_faint'))
                }
                .width('100%')

                if (row[4].length > 0) {
                  Text('结果：' + row[4])
                    .fontSize(12)
                    .fontColor($r('app.color.tentacle_text_dim'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }

                Row({ space: 8 }) {
                  ActionButton({
                    label: '编辑',
                    tone: 'secondary',
                    compact: true,
                    isEnabled: row[3] === 'active',
                    onTap: () => { this.openGoalEdit(row); }
                  })
                  if (row[3] === 'active') {
                    ActionButton({
                      label: '归档',
                      tone: 'danger',
                      compact: true,
                      onTap: () => { this.archiveGoal(row); }
                    })
                  }
                }
                .width('100%')
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.tentacle_bg_card'))
              .borderRadius(12)
              .border({ width: 0.5, color: $r('app.color.tentacle_border') })
            }, (row: Array<string>, gi: number) => this.renderKey.toString() + '_g' + gi.toString())
          } else if (this.tableName === 'tasks') {
            ForEach(this.tableData.rows, (row: Array<string>, ti: number) => {
              Column({ space: 6 }) {
                Row() {
                  Text(row[1])
                    .fontSize(15)
                    .fontColor($r('app.color.tentacle_text'))
                    .layoutWeight(1)
                  Text(row[2])
                    .fontSize(11)
                    .fontColor(row[2] === 'completed' ? $r('app.color.tentacle_text_faint') : $r('app.color.tentacle_accent'))
                }
                .width('100%')

                Row() {
                  Text(row[4])
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_ok'))
                  Text('goal #' + row[3])
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_text_faint'))
                    .margin({ left: 8 })
                  Blank()
                  Text(this.fmtTime(Number(row[5])))
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_text_faint'))
                }
                .width('100%')

                Row({ space: 8 }) {
                  ActionButton({
                    label: '编辑',
                    tone: 'secondary',
                    compact: true,
                    isEnabled: row[2] !== 'completed',
                    onTap: () => { this.openTaskEdit(row); }
                  })
                  ActionButton({
                    label: '删除',
                    tone: 'danger',
                    compact: true,
                    onTap: () => { this.deleteTask(row); }
                  })
                }
                .width('100%')
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.tentacle_bg_card'))
              .borderRadius(12)
              .border({ width: 0.5, color: $r('app.color.tentacle_border') })
            }, (row: Array<string>, ti: number) => this.renderKey.toString() + '_t' + ti.toString())
          } else {
            Scroll() {
              Column({ space: 8 }) {
                ForEach(this.tableData.rows, (row: Array<string>, ri: number) => {
                  Column({ space: 4 }) {
                    ForEach(this.tableData.columns, (col: string, ci: number) => {
                      Row() {
                        Text(col)
                          .fontSize(12)
                          .fontColor($r('app.color.tentacle_text_faint'))
                          .width(100)
                        Text(ci < row.length ? row[ci] : '')
                          .fontSize(12)
                          .fontColor($r('app.color.tentacle_text_dim'))
                          .layoutWeight(1)
                          .maxLines(3)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Top)
                    }, (col: string, ci: number) => this.renderKey.toString() + '_hc' + ci.toString())

                    if (this.tableName === 'raw_messages' || this.tableName === 'summaries') {
                      Row() {
                        Blank()
                        ActionButton({
                          label: '删除',
                          tone: 'danger',
                          compact: true,
                          onTap: () => {
                            const kind = this.tableName === 'raw_messages' ? 'messages' : 'summaries';
                            this.onDeleteRow(kind, row);
                          }
                        })
                      }
                      .width('100%')
                    }
                  }
                  .width('100%')
                  .padding(10)
                  .backgroundColor($r('app.color.tentacle_bg_card'))
                  .borderRadius(8)
                  .border({ width: 0.5, color: $r('app.color.tentacle_border') })
                }, (row: Array<string>, ri: number) => this.renderKey.toString() + '_hr' + ri.toString())
              }
              .width('100%')
              .padding(2)
            }
            .width('100%')
            .height(460)
            .scrollBar(BarState.Auto)
          }

          if (this.pageTotal > 0) {
            Row({ space: 10 }) {
              ActionButton({
                label: '上一页',
                tone: 'secondary',
                compact: true,
                isEnabled: this.pageOffset > 0,
                onTap: () => { this.prevPage(); }
              })
              Text('第 ' + this.pageNo().toString() + ' / ' + this.totalPages().toString() +
                ' 页 · 共 ' + this.pageTotal.toString() + ' 条')
                .fontSize(12)
                .fontColor($r('app.color.tentacle_text_dim'))
              ActionButton({
                label: '下一页',
                tone: 'secondary',
                compact: true,
                isEnabled: this.pageOffset + this.limit < this.pageTotal,
                onTap: () => { this.nextPage(); }
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }

          Column({ space: 8 }) {
            Row() {
              Text('SQL 控制台')
                .fontSize(14.5)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.tentacle_text'))
              Text('（仅 SELECT / WITH）')
                .fontSize(11)
                .fontColor($r('app.color.tentacle_text_faint'))
              Blank()
              ActionButton({
                label: this.sqlOpen ? '收起' : '展开',
                tone: 'ghost',
                compact: true,
                onTap: () => { this.sqlOpen = !this.sqlOpen; }
              })
            }
            .width('100%')
            .onClick(() => {
              this.sqlOpen = !this.sqlOpen;
            })

            if (this.sqlOpen) {
              TextArea({ text: this.sqlInput, placeholder: 'SELECT * FROM raw_messages ORDER BY id DESC LIMIT 10' })
                .onChange((v: string) => {
                  this.sqlInput = v;
                })
                .backgroundColor($r('app.color.tentacle_bg_input'))
                .fontColor($r('app.color.tentacle_text'))
                .border({ width: 0.5, color: $r('app.color.tentacle_border') })
                .borderRadius(10)
                .height(80)
                .width('100%')
              Row({ space: 10 }) {
                ActionButton({
                  label: '执行查询',
                  tone: 'primary',
                  compact: true,
                  onTap: () => { this.runSql(); }
                })
                Text(this.sqlMsg)
                  .fontSize(12)
                  .fontColor($r('app.color.tentacle_text_faint'))
              }
              .width('100%')
              if (this.sqlResult.columns.length > 0) {
                Scroll() {
                  Column({ space: 6 }) {
                    ForEach(this.sqlResult.rows, (row: Array<string>, ri: number) => {
                      Column({ space: 2 }) {
                        ForEach(this.sqlResult.columns, (col: string, ci: number) => {
                          Row() {
                            Text(col)
                              .fontSize(11)
                              .fontColor($r('app.color.tentacle_text_faint'))
                              .width(90)
                            Text(ci < row.length ? row[ci] : '')
                              .fontSize(11)
                              .fontColor($r('app.color.tentacle_text_dim'))
                              .layoutWeight(1)
                              .maxLines(2)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                          }
                          .width('100%')
                          .alignItems(VerticalAlign.Top)
                        }, (col: string, ci: number) => this.renderKey.toString() + '_sc' + ci.toString())
                      }
                      .width('100%')
                      .padding(8)
                      .backgroundColor($r('app.color.tentacle_bg_input'))
                      .borderRadius(8)
                    }, (row: Array<string>, ri: number) => this.renderKey.toString() + '_sr' + ri.toString())
                  }
                  .width('100%')
                  .padding(4)
                }
                .width('100%')
                .height(220)
                .scrollBar(BarState.Auto)
              }
            }
          }
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.tentacle_bg_card'))
          .borderRadius(12)
          .border({ width: 0.5, color: $r('app.color.tentacle_border') })

          if (this.errText.length > 0) {
            Text(this.errText)
              .fontSize(12)
              .fontColor($r('app.color.tentacle_danger'))
              .width('100%')
          }
        }
        .width('100%')
        .padding(12)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
  }
}

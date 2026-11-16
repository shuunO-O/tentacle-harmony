import { common, wantAgent } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { liveViewManager } from '@kit.LiveViewKit';
import { pushService } from '@kit.PushKit';
import { PhoneAction, validatePhoneAlarm } from '../model/PhoneProtocol';

export class PhoneNative {
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) { this.context = context; }

  async enableNotifications(): Promise<void> {
    await notificationManager.requestEnableNotification(this.context);
  }

  async pushToken(): Promise<string> { return pushService.getToken(); }

  async createAlarm(action: PhoneAction): Promise<number> {
    validatePhoneAlarm(action, Date.now());
    const date = new Date(action.at);
    const alarm: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate(),
        hour: date.getHours(), minute: date.getMinutes(), second: date.getSeconds()
      },
      title: 'Tentacle 闹钟', content: action.title, expiredContent: action.title,
      ringDuration: 60, snoozeTimes: 3, timeInterval: 300,
      notificationId: Math.floor(Math.random() * 2000000000) + 1,
      wantAgent: { pkgName: this.context.applicationInfo.name, abilityName: 'EntryAbility' },
      actionButton: [
        { title: '关闭', type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE },
        { title: '稍后提醒', type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_SNOOZE }
      ]
    };
    return reminderAgentManager.publishReminder(alarm);
  }

  async cancelAlarm(id: number): Promise<void> { await reminderAgentManager.cancelReminder(id); }

  private async view(id: number, title: string, finished: boolean): Promise<liveViewManager.LiveView> {
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: this.context.applicationInfo.name, abilityName: 'EntryAbility',
        parameters: { phoneOpenChat: true } }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: id,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    return {
      id: id, event: 'PROGRESS', sequence: finished ? 2 : 1, isMute: !finished,
      liveViewData: {
        primary: {
          title: title, content: [{ text: finished ? '点击返回会话查看结果' : '任务正在服务端处理' }],
          keepTime: finished ? 60 : 0, clickAction: agent,
          layoutData: { layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
            progress: finished ? 100 : 0, color: '#FFD97757' }
        },
        capsule: { type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: finished ? -1 : 1, icon: 'phone_status.svg', title: title, backgroundColor: '#FF332B21' }
      }
    };
  }

  async startLive(id: number): Promise<void> {
    if (!await liveViewManager.isLiveViewEnabled()) { throw new Error('请在系统设置中开启 Tentacle 实况窗'); }
    const result = await liveViewManager.startLiveView(await this.view(id, '思考中…', false));
    if (result.resultCode !== 0) { throw new Error('实况窗创建失败：' + result.resultCode.toString()); }
  }

  async finishLive(id: number, title: string): Promise<void> {
    const result = await liveViewManager.stopLiveView(await this.view(id, title, true));
    if (result.resultCode !== 0) { throw new Error('实况窗结束失败：' + result.resultCode.toString()); }
  }
}

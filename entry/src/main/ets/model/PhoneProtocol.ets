export interface PhoneRegistration {
  device_id: string;
  secret: string;
  push_token: string;
  timezone: string;
  alarms: boolean;
  live_view: boolean;
}

export interface PhoneRegistrationResult { registered: boolean; push_configured: boolean; }
export interface PhoneLiveMeta { activity_id: number; event: string; }
export interface PhoneAction { id: string; kind: string; title: string; at: number; expires_at: number; }
export interface PhoneReceipt { id: string; status: string; result: string; expiresAt?: number; }
export interface PhoneRoundState {
  request_id: string;
  activity_id: number;
  event: string;
  status: string;
  push_status: string;
}
export interface PhoneState { actions: PhoneAction[]; rounds: PhoneRoundState[]; }
export interface SavedPhoneRound { requestId: string; activityId: number; finished: boolean; }

export function validatePhoneAlarm(action: PhoneAction, now: number): void {
  if (!/^[a-f0-9]{32}$/.test(action.id) || action.kind !== 'alarm.create') {
    throw new Error('不支持的手机操作');
  }
  if (typeof action.title !== 'string' || action.title.trim().length === 0 || action.title.length > 100 ||
    !Number.isFinite(action.at) || !Number.isFinite(action.expires_at) ||
    action.expires_at <= now || action.at <= now + 5000 || action.at > now + 366 * 86400000) {
    throw new Error('闹钟参数无效或已过期');
  }
}

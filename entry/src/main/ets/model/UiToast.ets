/**
 * 全局轻提示触发辅助函数（纯 ArkTS/TS 模块，不依赖 ArkUI 组件装饰器）
 *
 * 通过 AppStorage 写入 appToastTone / appToastText / appToastSeq，
 * 由 Index 根容器统一渲染悬浮轻提示胶囊。
 */

let _toastCounter: number = 0;

export function notifyToast(message: string, tone: string = 'info'): void {
  const clean = message.trim();
  if (!clean) {
    return;
  }
  _toastCounter += 1;
  AppStorage.setOrCreate('appToastTone', tone);
  AppStorage.setOrCreate('appToastText', clean);
  AppStorage.setOrCreate('appToastSeq', _toastCounter);
}

/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, ThemeControl } from '@kit.ArkUI';
import { PhoneIntegration } from '../service/PhoneIntegration';
import { TentacleApi } from '../service/TentacleApi';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try { PhoneIntegration.getInstance().init(this.context); }
    catch (_) { AppStorage.setOrCreate('phoneStatus', '手机能力初始化失败，普通聊天仍可使用'); }
    this.handlePhoneWant(want);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      ThemeControl.setDefaultTheme({ colors: {
        brand: '#D97757', fontPrimary: '#E9E2D7', fontSecondary: '#B9AE9F', fontTertiary: '#A59B8D',
        fontFourth: '#A59B8D', fontEmphasize: '#D97757', fontOnPrimary: '#FFFFFF', iconEmphasize: '#D97757',
        backgroundPrimary: '#201B16', backgroundSecondary: '#29241E', backgroundTertiary: '#332B21',
        compBackgroundPrimary: '#332B21', compBackgroundSecondary: '#292219', compBackgroundTertiary: '#29241E',
        compBackgroundEmphasize: '#D97757', compEmphasizeSecondary: '#33D97757', compEmphasizeTertiary: '#1AD97757'
      } });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    PhoneIntegration.getInstance().foregroundChanged(false);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 窗口底色与状态栏前景适配暖棕深色主题
      windowStage.getMainWindow((werr, win) => {
        if (werr.code) {
          return;
        }
        try {
          win.setWindowBackgroundColor('#201B16');
          win.setWindowSystemBarProperties({ statusBarContentColor: '#E9E2D7' });
        } catch (e) {
          hilog.error(DOMAIN, 'testTag', 'Failed to set window appearance. Cause: %{public}s',
            JSON.stringify(e));
        }
      });
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    PhoneIntegration.getInstance().foregroundChanged(true);
    if (AppStorage.get<boolean>('connected') === true) { TentacleApi.getInstance().resumeChat(); }
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    PhoneIntegration.getInstance().foregroundChanged(false);
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void { this.handlePhoneWant(want); }

  private handlePhoneWant(want: Want): void {
    if (want.parameters?.phoneOpenChat === true) { AppStorage.setOrCreate('phoneOpenChat', Date.now()); }
  }
}

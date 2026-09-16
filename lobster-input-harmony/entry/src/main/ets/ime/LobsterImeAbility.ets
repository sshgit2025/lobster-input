/**
 * LobsterImeAbility.ets — 龙虾输入法 HarmonyOS 输入法扩展入口。
 * 对应安卓 LobsterIME : InputMethodService 的"服务声明与生命周期"部分;
 * 全部业务主体在 LobsterImeService.ets(LobsterIME.kt 的完整移植)。
 *
 * module.json5 已声明 extensionAbilities.srcEntry 指向本文件(name: LobsterImeAbility)。
 */
import { InputMethodExtensionAbility } from '@kit.IMEKit';
import { Want } from '@kit.AbilityKit';
import { AppInitializer } from '../common/AppInitializer';
import { Logger } from '../core/log/Logger';
import { LobsterImeService } from './LobsterImeService';

const TAG = 'LobsterImeAbility';

export default class LobsterImeAbility extends InputMethodExtensionAbility {
  onCreate(want: Want): void {
    Logger.i(TAG, 'onCreate');
    // 契约层统一初始化:所有需要 context 的单例(AppPreferences / SecureTokenStore /
    // MobileStrings / AuthSession / FileLog 等)在此就绪,业务侧直接 import 使用。
    try {
      AppInitializer.init(this.context);
    } catch (e) {
      Logger.e(TAG, 'AppInitializer.init failed: ' + (e as Error).message);
    }
    // 对应安卓 LobsterIME.onCreate():初始化录音器/打字栈/偏好,注册输入事件,创建软键盘 Panel
    LobsterImeService.getInstance().onCreate(this.context);
  }

  onDestroy(): void {
    Logger.i(TAG, 'onDestroy');
    // 对应安卓 LobsterIME.onDestroy():停连发、关 WS、释放录音器、销毁 Panel
    LobsterImeService.getInstance().onDestroy();
  }
}

// 公共基础设施:hilog 封装(契约见 PORTING_GUIDE)。
// 全项目统一通过 Logger.d/i/w/e(tag, msg) 打日志,替代安卓 android.util.Log。
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x00C7; // 龙虾输入法统一日志域

export class Logger {
  static d(tag: string, msg: string): void {
    hilog.debug(LOG_DOMAIN, tag, '%{public}s', msg);
  }

  static i(tag: string, msg: string): void {
    hilog.info(LOG_DOMAIN, tag, '%{public}s', msg);
  }

  static w(tag: string, msg: string): void {
    hilog.warn(LOG_DOMAIN, tag, '%{public}s', msg);
  }

  static e(tag: string, msg: string): void {
    hilog.error(LOG_DOMAIN, tag, '%{public}s', msg);
  }
}

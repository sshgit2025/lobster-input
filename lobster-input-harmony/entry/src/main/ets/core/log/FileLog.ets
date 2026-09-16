// 移植自 Android: core/log/FileLog.kt
//
// 落盘运行日志:写入应用沙箱 filesDir/logs/lobster-yyyy-MM-dd.log。
// - 按天切割:每天一个文件,跨天写入时自动滚动;
// - 保留 14 天:创建新日文件时清理更早的文件,避免撑爆磁盘;
// - 覆盖安装(在线升级)不清空:filesDir 只在卸载/清数据时被系统删除;
// - 串行写入(Promise 链模拟安卓单线程 executor),不阻塞调用方;写文件失败静默降级(仍打 hilog)。
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const RETENTION_DAYS: number = 14;
const PREFIX: string = 'lobster-';
const SUFFIX: string = '.log';

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function pad3(n: number): string {
  if (n < 10) {
    return `00${n}`;
  }
  return n < 100 ? `0${n}` : `${n}`;
}

/** yyyy-MM-dd */
function formatDay(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** HH:mm:ss.SSS */
function formatTime(d: Date): string {
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}.${pad3(d.getMilliseconds())}`;
}

export class FileLog {
  private static logDir: string | null = null;
  private static currentDay: string = '';
  private static currentFile: string | null = null;
  /** 串行写入队列(等价安卓单线程 executor)。 */
  private static queue: Promise<void> = Promise.resolve();

  static init(context: common.Context): void {
    if (FileLog.logDir !== null) {
      return;
    }
    const dir = `${context.filesDir}/logs`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      FileLog.logDir = dir;
    } catch (err) {
      Logger.w('FileLog', `创建日志目录失败: ${(err as Error).message}`);
    }
  }

  static i(tag: string, msg: string): void {
    FileLog.write('I', tag, msg);
    Logger.i(tag, msg);
  }

  static w(tag: string, msg: string): void {
    FileLog.write('W', tag, msg);
    Logger.w(tag, msg);
  }

  static e(tag: string, msg: string): void {
    FileLog.write('E', tag, msg);
    Logger.e(tag, msg);
  }

  private static write(level: string, tag: string, msg: string): void {
    const dir = FileLog.logDir;
    if (dir === null) {
      return;
    }
    const now = new Date();
    FileLog.queue = FileLog.queue.then(() => {
      try {
        const day = formatDay(now);
        if (day !== FileLog.currentDay || FileLog.currentFile === null) {
          FileLog.currentDay = day;
          FileLog.currentFile = `${dir}/${PREFIX}${day}${SUFFIX}`;
          FileLog.pruneOldLogs(dir);
        }
        const line = `${formatTime(now)} ${level}/${tag}: ${msg}\n`;
        const file = fs.openSync(FileLog.currentFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
        try {
          fs.writeSync(file.fd, line);
        } finally {
          fs.closeSync(file);
        }
      } catch (err) {
        // 写文件失败静默降级(仍打 hilog)
      }
    });
  }

  /** 只保留最近 RETENTION_DAYS 个日文件(按文件名中的日期字典序即时间序)。 */
  private static pruneOldLogs(dir: string): void {
    try {
      const files: string[] = fs.listFileSync(dir);
      const logFiles: string[] = [];
      for (let i = 0; i < files.length; i++) {
        if (files[i].startsWith(PREFIX) && files[i].endsWith(SUFFIX)) {
          logFiles.push(files[i]);
        }
      }
      // 按文件名降序(即日期从新到旧)
      logFiles.sort((a: string, b: string) => (a < b ? 1 : a > b ? -1 : 0));
      for (let i = RETENTION_DAYS; i < logFiles.length; i++) {
        try {
          fs.unlinkSync(`${dir}/${logFiles[i]}`);
        } catch (err) {
          // 单个删除失败忽略
        }
      }
    } catch (err) {
      // 清理失败忽略
    }
  }
}

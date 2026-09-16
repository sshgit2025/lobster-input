// 移植自 Android: core/history/MobileHistoryStore.kt
// 存储介质等价替换:安卓存 SharedPreferences(JSON 字符串) → 鸿蒙存同一 preferences 文件,
// key 与序列化字段名(Gson 直出的 Kotlin 属性名)完全一致,最多保留 100 条。
import { util } from '@kit.ArkTS';
import { AppPreferences } from '../../data/local/AppPreferences';
import { Logger } from '../log/Logger';

const TAG: string = 'MobileHistoryStore';
const KEY_RECORDS: string = 'mobile_history_records';
const MAX_RECORDS: number = 100;

/** 对应 Kotlin enum MobileHistoryStatus(Gson 序列化为枚举名)。 */
export enum MobileHistoryStatus {
  SUCCESS = 'SUCCESS',
  FAILED = 'FAILED',
}

/** 字段名与安卓 Gson 序列化结果一致(Kotlin 属性名,camelCase)。 */
export interface MobileHistoryRecord {
  id: string;
  operation: string;
  transcript: string | null;
  result: string | null;
  actionType: string | null;
  selectedText: string | null;
  errorMessage: string | null;
  status: MobileHistoryStatus;
  createdAt: number;
}

function asRecord(o: Object): Record<string, Object> {
  return o as Record<string, Object>;
}

function strOrNull(rec: Record<string, Object>, key: string): string | null {
  const v: Object | undefined = rec[key];
  return typeof v === 'string' ? v : null;
}

function recordFrom(rec: Record<string, Object>): MobileHistoryRecord {
  const statusRaw = strOrNull(rec, 'status');
  const createdAtRaw: Object | undefined = rec['createdAt'];
  const result: MobileHistoryRecord = {
    id: strOrNull(rec, 'id') ?? util.generateRandomUUID(),
    operation: strOrNull(rec, 'operation') ?? '',
    transcript: strOrNull(rec, 'transcript'),
    result: strOrNull(rec, 'result'),
    actionType: strOrNull(rec, 'actionType'),
    selectedText: strOrNull(rec, 'selectedText'),
    errorMessage: strOrNull(rec, 'errorMessage'),
    status: statusRaw === MobileHistoryStatus.SUCCESS ? MobileHistoryStatus.SUCCESS : MobileHistoryStatus.FAILED,
    createdAt: typeof createdAtRaw === 'number' ? createdAtRaw : Date.now(),
  };
  return result;
}

export class MobileHistoryStore {
  private prefs(): AppPreferences {
    return AppPreferences.getInstance();
  }

  records(): MobileHistoryRecord[] {
    const raw = this.prefs().getStringSync(KEY_RECORDS, null);
    if (raw === null) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as object;
      if (!(parsed instanceof Array)) {
        return [];
      }
      const arr = parsed as Object[];
      const out: MobileHistoryRecord[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push(recordFrom(asRecord(arr[i])));
      }
      return out;
    } catch (err) {
      Logger.w(TAG, `历史记录解析失败: ${(err as Error).message}`);
      return [];
    }
  }

  addSuccess(
    operation: string,
    transcript: string,
    result: string,
    actionType: string | null,
    selectedText: string | null
  ): void {
    const record: MobileHistoryRecord = {
      id: util.generateRandomUUID(),
      operation: operation,
      transcript: transcript,
      result: result,
      actionType: actionType,
      selectedText: selectedText,
      errorMessage: null,
      status: MobileHistoryStatus.SUCCESS,
      createdAt: Date.now(),
    };
    this.add(record);
  }

  addFailed(operation: string, errorMessage: string, selectedText: string | null): void {
    const record: MobileHistoryRecord = {
      id: util.generateRandomUUID(),
      operation: operation,
      transcript: null,
      result: null,
      actionType: null,
      selectedText: selectedText,
      errorMessage: errorMessage,
      status: MobileHistoryStatus.FAILED,
      createdAt: Date.now(),
    };
    this.add(record);
  }

  delete(id: string): void {
    this.save(this.records().filter((r: MobileHistoryRecord) => r.id !== id));
  }

  clearAll(): void {
    this.save([]);
  }

  private add(record: MobileHistoryRecord): void {
    const merged: MobileHistoryRecord[] = [record];
    const existing = this.records();
    for (let i = 0; i < existing.length; i++) {
      merged.push(existing[i]);
    }
    this.save(merged.slice(0, MAX_RECORDS));
  }

  private save(items: MobileHistoryRecord[]): void {
    this.prefs().putStringSync(KEY_RECORDS, JSON.stringify(items));
  }
}

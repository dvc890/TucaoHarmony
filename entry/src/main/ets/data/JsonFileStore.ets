/**
 * JSON 文件存储（files 目录）
 * - star.json / history.json / search_history.json / download_catalog.json 等
 * - 串行化写：同一文件的写请求按 promise 链排队，防止并发覆盖丢更新
 * - 原子写：先写 .tmp 再 rename，避免进程被杀留下半截文件
 * - 读为同步 fs（文件小、低频），写在异步队列中执行
 */
import { fileIo } from '@kit.CoreFileKit';
import { JsonCoerce } from '../model/entity/BaseEntities';

export class JsonFileStore {
  private static filesDir: string = '';
  /** 每文件一条写队列（尾部 promise） */
  private static writeQueues: Map<string, Promise<void>> = new Map<string, Promise<void>>();

  /** 初始化（EntryAbility onCreate 传入 context.filesDir） */
  static init(filesDir: string): void {
    JsonFileStore.filesDir = filesDir;
    try {
      if (!fileIo.accessSync(filesDir)) {
        fileIo.mkdirSync(filesDir, true);
      }
    } catch (err) {
      // 目录已存在等情况忽略
    }
  }

  /** 文件完整路径 */
  static pathOf(fileName: string): string {
    return `${JsonFileStore.filesDir}/${fileName}`;
  }

  /** 读对象数组（不存在/损坏返回空数组） */
  static loadArray(fileName: string): Object[] {
    const text: string = JsonFileStore.readText(fileName);
    if (text.length === 0) {
      return [];
    }
    return JsonCoerce.parseObjectArray(text);
  }

  /** 读单对象（不存在/损坏返回 undefined） */
  static loadObject(fileName: string): Record<string, Object> | undefined {
    const text: string = JsonFileStore.readText(fileName);
    if (text.length === 0) {
      return undefined;
    }
    return JsonCoerce.parseRecord(text);
  }

  /** 串行写对象数组 */
  static saveArray(fileName: string, items: Object[]): Promise<void> {
    const text: string = JSON.stringify(items);
    return JsonFileStore.enqueueWrite(fileName, (): Promise<void> => JsonFileStore.writeTextAtomic(fileName, text));
  }

  /** 串行写单对象 */
  static saveObject(fileName: string, record: Record<string, Object>): Promise<void> {
    const text: string = JSON.stringify(record);
    return JsonFileStore.enqueueWrite(fileName, (): Promise<void> => JsonFileStore.writeTextAtomic(fileName, text));
  }

  /** 删除文件（不存在则忽略） */
  static remove(fileName: string): void {
    try {
      const target: string = JsonFileStore.pathOf(fileName);
      if (fileIo.accessSync(target)) {
        fileIo.unlinkSync(target);
      }
    } catch (err) {
      // 忽略删除失败
    }
  }

  /** 同步读文本（异常/不存在返回空串） */
  private static readText(fileName: string): string {
    try {
      const target: string = JsonFileStore.pathOf(fileName);
      if (!fileIo.accessSync(target)) {
        return '';
      }
      return fileIo.readTextSync(target);
    } catch (err) {
      return '';
    }
  }

  /** 按文件排队写任务（前任完成（或失败）后才执行后任） */
  private static enqueueWrite(fileName: string, writeFn: () => Promise<void>): Promise<void> {
    const prev: Promise<void> = JsonFileStore.writeQueues.get(fileName) ?? Promise.resolve();
    const task: Promise<void> = prev.then(writeFn);
    // 队列尾吞掉异常，保证后续任务不被跳过；真实错误仍由 task 抛给调用方
    JsonFileStore.writeQueues.set(fileName, task.then(undefined, (): void => {
    }));
    return task;
  }

  /** 原子写：tmp → rename */
  private static writeTextAtomic(fileName: string, text: string): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (err: Object) => void) => {
      try {
        const target: string = JsonFileStore.pathOf(fileName);
        const tmpPath: string = `${target}.tmp`;
        const file: fileIo.File = fileIo.openSync(tmpPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(file.fd, text);
        } finally {
          fileIo.closeSync(file);
        }
        try {
          if (fileIo.accessSync(target)) {
            fileIo.unlinkSync(target);
          }
        } catch (err) {
          // 目标不存在属正常
        }
        fileIo.renameSync(tmpPath, target);
        resolve();
      } catch (err) {
        reject(err);
      }
    });
  }
}

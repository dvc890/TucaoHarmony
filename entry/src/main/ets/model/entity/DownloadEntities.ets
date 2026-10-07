/**
 * 下载域实体与工具（下载管理）
 * - DownloadTask：串行队列任务（vid 去重键 + 前台通知展示名）
 * - DownloadDirSetting / DownloadDirStore：用户自选下载目录（PersistenceV2 持久化）
 * - DownloadStateText / FileSizeText：状态文案与容量格式化
 * 状态机复用 BaseEntities.DownloadStatus：
 * READY → OBTAIN_URL → CONNECTING → DOWNLOADING ⇄ PAUSED/FAILED → COMPLETED
 */
import { PersistenceV2, ConnectOptions } from '@kit.ArkUI';
import { Video, Part, DownloadStatus } from './BaseEntities';
import { PrefKey } from '../../common/Constants';

/** 下载队列任务（引用 catalog 中的 Video 实例，绝不引用页面传入实例） */
export class DownloadTask {
  readonly video: Video;
  readonly partIndex: number;

  constructor(video: Video, partIndex: number) {
    this.video = video;
    this.partIndex = partIndex;
  }

  /** 任务键（分集 vid，直传分集为 {hid}{order}，见 VideoRepository.normalizeParts） */
  get key(): string {
    const part: Part | undefined = this.video.parts[this.partIndex];
    return part !== undefined && part.vid.length > 0 ? part.vid : `${this.video.hid}-${this.partIndex}`;
  }

  /** 通知展示名（分集标题，缺省回退合集标题） */
  get displayName(): string {
    const part: Part | undefined = this.video.parts[this.partIndex];
    return part !== undefined && part.title.length > 0 ? part.title : this.video.title;
  }
}

/** 用户自选下载目录设置（PersistenceV2：preferences:download_dir） */
@ObservedV2
export class DownloadDirSetting {
  /** 目录 uri（fileUri.FileUri 可解析；空 = 应用沙箱默认目录） */
  @Trace uri: string = '';
  /** 展示名（选择器返回路径的末段） */
  @Trace label: string = '';

  /** 是否已配置自选目录 */
  isCustom(): boolean {
    return this.uri.length > 0;
  }
}

/** 下载目录存取单例（懒初始化模式对齐 PreferenceStore） */
export class DownloadDirStore {
  private static instance: DownloadDirSetting | undefined = undefined;

  static get(): DownloadDirSetting {
    if (DownloadDirStore.instance === undefined) {
      const options: ConnectOptions<DownloadDirSetting> = {
        type: DownloadDirSetting,
        key: PrefKey.DOWNLOAD_DIR,
        defaultCreator: (): DownloadDirSetting => new DownloadDirSetting()
      };
      const connected: DownloadDirSetting | undefined = PersistenceV2.globalConnect(options);
      DownloadDirStore.instance = connected ?? new DownloadDirSetting();
    }
    return DownloadDirStore.instance;
  }

  /** 立即落盘（设置页修改后调用；@Trace 变更本会自动持久化） */
  static save(): void {
    try {
      PersistenceV2.save(PrefKey.DOWNLOAD_DIR);
    } catch (err) {
      // 忽略手动落盘失败
    }
  }
}

/** 下载状态文案（页面展示统一出口） */
export class DownloadStateText {
  static of(status: DownloadStatus): string {
    switch (status) {
      case DownloadStatus.READY:
        return '未下载';
      case DownloadStatus.OBTAIN_URL:
        return '解析中';
      case DownloadStatus.CONNECTING:
        return '连接中';
      case DownloadStatus.DOWNLOADING:
        return '下载中';
      case DownloadStatus.PAUSED:
        return '已暂停';
      case DownloadStatus.FAILED:
        return '下载失败';
      case DownloadStatus.COMPLETED:
        return '已缓存';
      default:
        return '';
    }
  }
}

/** 容量格式化（1 位小数，B/KB/MB/GB/TB） */
export class FileSizeText {
  static format(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return '0B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value: number = bytes;
    let unit: number = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return `${value.toFixed(1)}${units[unit]}`;
  }
}

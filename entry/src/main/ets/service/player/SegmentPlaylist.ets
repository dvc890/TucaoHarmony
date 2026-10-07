/**
 * 多段播放列表
 * 基于 API 26 AVPlayer 播放列表能力封装多段视频拼接（替代安卓版 concat/ffconcat）：
 * - 首段 setMediaSource（idle → initialized 可靠跃迁），余段 addPlaybackMediaSource
 *   （addPlaybackMediaSource 支持播放中动态增删，具备列表语义）
 * - onPlaybackContentChanged 回调 id → 分段索引，输出分段偏移（供  弹幕时间轴对齐）
 * - 总时位映射：total = offsetBefore(currentIndex) + player.currentTime；
 *   跨段 seek：advanceToMediaSource(id) + 段内 seek
 * - 本地分片：createMediaSourceWithFd（fd 全程保持打开，release 时统一关闭）
 * - 段长优先取 playurl XML 的 durl.length；缺失时以 durationUpdate 观测值渐进补齐
 * - 兜底开关（PlaybackMode.SEQUENTIAL，由 PlayerController 驱动）：
 *   逐段 setMediaSource + completed 手动推进，接缝有轻微停顿，仅在播放列表路径异常时使用
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { Durl } from '../../model/entity/BaseEntities';

/** 播放列表分段管理器（不自建状态机，状态由 PlayerController 统一驱动） */
export class SegmentPlaylist {
  private readonly player: media.AVPlayer;
  private segments: Durl[] = [];
  private sourceIds: string[] = [];
  private currentIndex: number = 0;
  /** 本地 fd 模式下保持打开的文件描述符 */
  private openedFds: number[] = [];
  /** 各段起始累计偏移 ms（length 未知时以观测 duration 渐进回填） */
  private startOffsetsMs: number[] = [];
  /** 各段已知时长 ms（0 = 未知） */
  private segmentDurationsMs: number[] = [];
  /** 是否发生过 http→https 同主机回退（错误文案显式说明用） */
  private hadHttpsFallback: boolean = false;
  /** 分段切换回调（索引变化时通知，含首段） */
  onSegmentChanged: ((index: number) => void) | null = null;

  constructor(player: media.AVPlayer) {
    this.player = player;
  }

  getPlayer(): media.AVPlayer {
    return this.player;
  }

  getSegments(): Durl[] {
    return this.segments;
  }

  getCurrentIndex(): number {
    return this.currentIndex;
  }

  /** 段源 id（advanceToMediaSource 用） */
  getSourceId(index: number): string {
    const id: string | undefined = this.sourceIds[index];
    return id ?? '';
  }

  /** 指定段已知时长 ms（0 = 未知；PlayerController 假完成守卫用） */
  knownSegmentDurationMs(index: number): number {
    const value: number | undefined = this.segmentDurationsMs[index];
    return value ?? 0;
  }

  /** 重置簿记（新一轮 load 前） */
  reset(): void {
    this.releaseLocalFds();
    this.segments = [];
    this.sourceIds = [];
    this.currentIndex = 0;
    this.startOffsetsMs = [];
    this.segmentDurationsMs = [];
    this.hadHttpsFallback = false;
  }

  /** 登记分段并构建首段源（url / fd 二选一） */
  begin(segments: Durl[]): media.MediaSource | undefined {
    this.reset();
    this.segments = segments;
    this.currentIndex = 0;
    for (let i = 0; i < segments.length; i++) {
      this.startOffsetsMs.push(0);
      this.segmentDurationsMs.push(segments[i].length > 0 ? segments[i].length : 0);
    }
    this.rebuildOffsets();
    return this.buildSource(0);
  }

  /** 追加一段并返回该段源（addPlaybackMediaSource 后由调用方登记 id） */
  appendSource(index: number): media.MediaSource | undefined {
    if (index < 0 || index >= this.segments.length) {
      return undefined;
    }
    return this.buildSource(index);
  }

  /** 登记 addPlaybackMediaSource 返回的源 id */
  registerSourceId(index: number, id: string): void {
    this.sourceIds[index] = id;
  }

  /** durationUpdate 观测：回填当前段时长并重建偏移表 */
  observeDuration(durationMs: number): void {
    if (durationMs <= 0) {
      return;
    }
    this.segmentDurationsMs[this.currentIndex] = durationMs;
    this.rebuildOffsets();
  }

  /** 播放内容切换（onPlaybackContentChanged 的 id → 索引映射） */
  handleContentChanged(sourceId: string): void {
    for (let i = 0; i < this.sourceIds.length; i++) {
      if (this.sourceIds[i] === sourceId) {
        if (i !== this.currentIndex) {
          this.currentIndex = i;
          if (this.onSegmentChanged !== null) {
            this.onSegmentChanged(i);
          }
        }
        return;
      }
    }
  }

  /** 当前段之前所有段的累计偏移 */
  offsetBeforeCurrentMs(): number {
    return this.offsetBeforeIndex(this.currentIndex);
  }

  /** 指定段之前的累计偏移 */
  offsetBeforeIndex(index: number): number {
    if (index <= 0 || index >= this.startOffsetsMs.length) {
      return 0;
    }
    const value: number | undefined = this.startOffsetsMs[index];
    return value ?? 0;
  }

  /** 已知总时长（末段偏移 + 末段已知时长；含未知段时为保守值） */
  knownTotalMs(): number {
    const count: number = this.segmentDurationsMs.length;
    if (count === 0) {
      return 0;
    }
    return this.offsetBeforeIndex(count - 1) + (this.segmentDurationsMs[count - 1] > 0
      ? this.segmentDurationsMs[count - 1] : 0);
  }

  /** 总时位：段偏移 + 段内 currentTime */
  totalPositionMs(): number {
    return this.offsetBeforeCurrentMs() + Math.round(this.player.currentTime);
  }

  /** 总时位 → (段索引, 段内时位) */
  mapTotal(totalMs: number): SegmentPosition {
    const result: SegmentPosition = new SegmentPosition();
    if (this.segments.length === 0) {
      return result;
    }
    for (let i = this.segments.length - 1; i >= 0; i--) {
      const offset: number = this.offsetBeforeIndex(i);
      if (totalMs >= offset) {
        // 段长未知时（本地无 length 记录），无法精确映射到后段，落在当前已知段
        if (i > this.currentIndex && this.segmentDurationsMs[i - 1] === 0) {
          result.index = this.currentIndex;
          result.withinMs = Math.round(this.player.currentTime);
          return result;
        }
        result.index = i;
        result.withinMs = totalMs - offset;
        return result;
      }
    }
    result.index = 0;
    result.withinMs = totalMs;
    return result;
  }

  /** 重建累计偏移表（未知段按 0 计，观测回填后重算） */
  private rebuildOffsets(): void {
    let acc: number = 0;
    for (let i = 0; i < this.segmentDurationsMs.length; i++) {
      this.startOffsetsMs[i] = acc;
      acc += this.segmentDurationsMs[i];
    }
  }

  /** 构建段源：远程 createMediaSourceWithUrl（携带 Referer 头；http 明文运行期 https 同主机回退，/） / 本地 createMediaSourceWithFd */
  private buildSource(index: number): media.MediaSource | undefined {
    const durl: Durl | undefined = this.segments[index];
    if (durl === undefined) {
      return undefined;
    }
    if (durl.cachePath.length > 0) {
      const fdSource: media.MediaSource | undefined = this.buildFdSource(durl.cachePath);
      if (fdSource !== undefined) {
        return fdSource;
      }
      // 本地文件缺失（已删除/未下载完）且保留远程地址：降级远程播放（兜底）
    }
    if (durl.url.length === 0) {
      return undefined;
    }
    // AVPlayer 自 API 23 拒绝明文（5411012），http 地址运行期回退 https 同主机
    let url: string = durl.url;
    if (url.startsWith('http://')) {
      url = `https://${url.substring('http://'.length)}`;
      this.hadHttpsFallback = true;
    }
    return media.createMediaSourceWithUrl(url, {
      'referer': 'https://www.tucao.my/'
    });
  }

  /** 是否发生过 http→https 同主机回退（PlayerController 错误文案显式说明用） */
  hasUsedHttpsFallback(): boolean {
    return this.hadHttpsFallback;
  }

  /** 本地文件 → fd 源（fd 保持打开，release 时关闭） */
  private buildFdSource(path: string): media.MediaSource | undefined {
    try {
      if (!fileIo.accessSync(path)) {
        return undefined;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      this.openedFds.push(file.fd);
      const stat: fileIo.Stat = fileIo.statSync(path);
      const descriptor: media.AVFileDescriptor = {
        fd: file.fd,
        offset: 0,
        length: stat.size
      };
      return media.createMediaSourceWithFd(descriptor);
    } catch (err) {
      return undefined;
    }
  }

  /** 关闭本地 fd（release/换源时调用，幂等） */
  releaseLocalFds(): void {
    for (let i = 0; i < this.openedFds.length; i++) {
      try {
        fileIo.closeSync(this.openedFds[i]);
      } catch (err) {
        // fd 已失效等情况忽略
      }
    }
    this.openedFds = [];
  }
}

/** 段内位置映射结果 */
export class SegmentPosition {
  index: number = 0;
  withinMs: number = 0;
}

/**
 * 本地收藏服务（star.json）
 * - 存储：files/star.json（JsonFileStore 串行原子写），对齐安卓 SP 键 star
 * - 排序：新收藏插队首（对齐安卓 HistoryHelpers.add(0, video)）
 * - 联动：toggle 后 postStarChanged，收藏页()与详情页星标即时刷新
 * - 服务端收藏同步属，本期仅本地持久化
 */
import { Video, JsonCoerce } from '../model/entity/BaseEntities';
import { StoreFile } from '../common/Constants';
import { JsonFileStore } from '../data/JsonFileStore';
import { EventBus } from '../common/EventBus';

/** 收藏单例 */
export class StarService {
  private static instance: StarService | undefined;

  static getInstance(): StarService {
    if (StarService.instance === undefined) {
      StarService.instance = new StarService();
    }
    return StarService.instance;
  }

  /** 内存缓存（读一次，写穿透） */
  private records: Video[] | null = null;

  private constructor() {
  }

  /** 读取全部收藏（新的在前） */
  loadStars(): Video[] {
    if (this.records !== null) {
      return this.records;
    }
    const raw: Object[] = JsonFileStore.loadArray(StoreFile.STAR);
    const result: Video[] = [];
    for (let i = 0; i < raw.length; i++) {
      const record: Record<string, Object> | undefined = JsonCoerce.asRecord(raw[i]);
      if (record !== undefined) {
        result.push(Video.fromLocalJson(record));
      }
    }
    this.records = result;
    return result;
  }

  /** 是否已收藏 */
  contains(hid: string): boolean {
    const list: Video[] = this.loadStars();
    for (let i = 0; i < list.length; i++) {
      if (list[i].hid === hid) {
        return true;
      }
    }
    return false;
  }

  /**
   * 切换收藏状态
   * @return 切换后的状态（true=已收藏）
   */
  toggle(video: Video): boolean {
    const list: Video[] = this.loadStars();
    const rest: Video[] = [];
    let existed: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].hid === video.hid) {
        existed = true;
      } else {
        rest.push(list[i]);
      }
    }
    if (existed) {
      this.records = rest;
      video.isStarred = false;
      this.persist();
      EventBus.postStarChanged(video.hid);
      return false;
    }
    video.isStarred = true;
    this.records = [video, ...rest];
    this.persist();
    EventBus.postStarChanged(video.hid);
    return true;
  }

  /** 移除收藏（收藏管理页用，扩展） */
  remove(hid: string): void {
    const list: Video[] = this.loadStars();
    this.records = list.filter((v: Video): boolean => v.hid !== hid);
    this.persist();
    EventBus.postStarChanged(hid);
  }

  /** 持久化（队列串行写） */
  private persist(): void {
    const list: Video[] = this.records !== null ? this.records : [];
    const items: Object[] = [];
    for (let i = 0; i < list.length; i++) {
      items.push(list[i].toLocalRecord());
    }
    JsonFileStore.saveArray(StoreFile.STAR, items);
  }
}

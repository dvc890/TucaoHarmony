/**
 * 收藏列表 VM
 * - 数据源：StarService（star.json，新收藏在前、hid 去重，写穿透）
 * - 联动：EventBus STAR_CHANGED（详情页开关收藏 → 列表即时刷新）
 * - 删除：StarService.remove（左滑/右键菜单触发）
 * - 页面级生命周期：aboutToAppear bind / aboutToDisappear unbind，防止泄漏
 */
import { Video } from '../model/entity/BaseEntities';
import { StarService } from '../service/StarService';
import { EventBus } from '../common/EventBus';

@ObservedV2
export class StarVM {
  /** 收藏列表快照（新的在前） */
  @Trace stars: Video[] = [];
  /** 条目计数文案 */
  @Trace summaryText: string = '';

  private readonly star: StarService = StarService.getInstance();
  private unsubscribe: (() => void) | null = null;

  /** 页面出现：加载数据并订阅收藏变化 */
  bind(): void {
    this.refresh();
    this.unsubscribe = EventBus.onStarChanged((): void => {
      this.refresh();
    });
  }

  /** 页面消失：解除订阅 */
  unbind(): void {
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }

  /** 刷新列表快照（StarService 内存缓存，读一次写穿透） */
  refresh(): void {
    this.stars = this.star.loadStars().slice();
    this.summaryText = this.stars.length > 0 ? `共 ${this.stars.length} 个收藏` : '';
  }

  /** 删除收藏（左滑/右键菜单） */
  remove(hid: string): void {
    this.star.remove(hid);
    this.refresh();
  }

  /** 是否空列表 */
  isEmpty(): boolean {
    return this.stars.length === 0;
  }
}

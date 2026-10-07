/**
 * 频道详情页
 * - 入口：首页频道宫格/榜单等（Router.goChannelDetail(tid)，父或子频道 id）
 * - 页签：父频道 + 同父子频道（如「新番/连载新番/天朝出品/OAD·OVA·剧场版/完结番组」）
 * - 排序：最近发布/人气最旺/弹幕最多（TagFilter）；视频卡片栅格 + 下拉刷新 + 触底加载
 * - 页面驱动各页签懒加载（切换页签时拉取，已加载过的页签直接复用缓存）
 * - 路由：router_map.json → ChannelDetailBuilder（param = tid 数字）
 */
import { Channel, ChannelTable } from '../common/Constants';
import { Router } from '../common/Router';
import { ChannelDetailVM } from '../viewmodel/ChannelDetailVM';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { Video } from '../model/entity/BaseEntities';
import { TagFilter } from '../components/TagFilter';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { EmptyView } from '../components/EmptyView';
import { VideoCardView } from '../views/home/VideoCardView';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function ChannelDetailBuilder(name: string, param: Object) {
  ChannelDetail({ routeParam: param })
}

@ComponentV2
struct ChannelDetail {
  /** 路由参数（tid 数字，aboutToAppear 收窄） */
  @Param routeParam: Object = new Object();
  /** 初始频道 tid（父或子） */
  @Local initialTid: number = 0;
  /** 页签列表（进入页面后固定） */
  @Local tabs: Channel[] = [];
  /** 选中页签下标 */
  @Local selectedTab: number = 0;

  private vm: ChannelDetailVM = ChannelDetailVM.shared();
  private tabsController: TabsController = new TabsController();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  aboutToAppear(): void {
    if (typeof this.routeParam === 'number') {
      this.initialTid = this.routeParam;
    }
    if (this.initialTid <= 0) {
      return;
    }
    this.tabs = ChannelDetailVM.tabsOf(this.initialTid);
    // 初始 tid 为子频道时定位到对应页签，否则落在父频道页签
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === this.initialTid) {
        this.selectedTab = i;
        break;
      }
    }
    this.vm.setup(this.currentTabTid());
    this.vm.loadChannel(this.currentTabTid());
  }

  private currentTabTid(): number {
    const channel: Channel | undefined = this.tabs[this.selectedTab];
    return channel !== undefined ? channel.id : this.initialTid;
  }

  /** 标题：父频道名 */
  private pageTitle(): string {
    const channel: Channel | undefined = ChannelTable.find(this.initialTid);
    const parentTid: number = channel !== undefined ? channel.getValidParentId() : this.initialTid;
    return ChannelTable.nameOf(parentTid);
  }

  /** 断点 → Grid 列模板（对齐首页频道列表） */
  private columnsTemplate(): string {
    const breakpoint: string = this.windowSize.breakpoint;
    if (breakpoint === 'xl') {
      return '1fr 1fr 1fr 1fr 1fr 1fr';
    }
    if (breakpoint === 'lg') {
      return '1fr 1fr 1fr 1fr';
    }
    if (breakpoint === 'md') {
      return '1fr 1fr 1fr';
    }
    return '1fr 1fr';
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（中性底） =====
        Row({ space: $r('app.float.space_sm') }) {
          Text('‹')
            .fontSize(28)
            .fontColor($r('app.color.text_primary'))
            .padding({
              left: $r('app.float.space_sm'),
              right: $r('app.float.space_sm')
            })
            .onClick((): void => {
              Router.back();
            })
          Text(this.pageTitle())
            .fontSize($r('app.float.font_size_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_md'),
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })
        // 全局沉浸：topbar 底色仅扩展绘制延伸到状态栏下（不改布局，内容绝对位置不变）
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

        // ===== 子频道页签 =====
        Tabs({ index: this.selectedTab, controller: this.tabsController }) {
          ForEach(this.tabs, (channel: Channel) => {
            TabContent() {
              ChannelDetailTabView({ tid: channel.id })
            }
            .tabBar(channel.name)
          }, (channel: Channel) => `${channel.id}`)
        }
        .barMode(BarMode.Scrollable)
        .layoutWeight(1)
        .width('100%')
        .onChange((index: number): void => {
          this.selectedTab = index;
          this.vm.setup(this.currentTabTid());
          this.vm.loadChannel(this.currentTabTid());
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
  }
}

/** 单子频道内容流（页面控制加载时机） */
@ComponentV2
struct ChannelDetailTabView {
  @Param tid: number = 0;
  private vm: ChannelDetailVM = ChannelDetailVM.shared();

  /** 当前排序下标 */
  private orderIndex(order: string): number {
    if (order === ChannelDetailVM.ORDER_VIEWS) {
      return 1;
    }
    if (order === ChannelDetailVM.ORDER_MUKIO) {
      return 2;
    }
    return 0;
  }

  build() {
    Refresh({ refreshing: this.vm.stateOf(this.tid).refreshing }) {
      Column() {
        // ===== 排序切换 =====
        TagFilter({
          labels: [
            ChannelDetailVM.orderText(ChannelDetailVM.ORDER_DATE),
            ChannelDetailVM.orderText(ChannelDetailVM.ORDER_VIEWS),
            ChannelDetailVM.orderText(ChannelDetailVM.ORDER_MUKIO)
          ],
          selectedIndex: this.orderIndex(this.vm.stateOf(this.tid).order),
          onSelect: (index: number) => {
            const picked: string | undefined = ChannelDetailVM.ORDERS[index];
            if (picked !== undefined) {
              this.vm.changeOrder(this.tid, picked);
            }
          }
        })

        if (this.vm.stateOf(this.tid).loading) {
          LoadingState({ message: '正在加载频道内容…' })
        } else if (this.vm.stateOf(this.tid).error.length > 0
          && this.vm.stateOf(this.tid).videos.length === 0) {
          ErrorRetry({
            message: this.vm.stateOf(this.tid).error,
            onRetry: (): void => {
              this.vm.refreshChannel(this.tid);
            }
          })
        } else if (this.vm.stateOf(this.tid).videos.length === 0) {
          EmptyView({ message: '本频道暂无内容' })
        } else {
          Grid() {
            Repeat(this.vm.stateOf(this.tid).videos)
              .each((repeatItem: RepeatItem<Video>) => {
                GridItem() {
                  VideoCardView({ video: repeatItem.item })
                }
              })
              .key((card: Video, index: number) => `${card.hid}-${index}`)
              .virtualScroll({ totalCount: this.vm.stateOf(this.tid).videos.length })
          }
          .columnsTemplate(this.columnsTemplate())
          .columnsGap($r('app.float.space_sm'))
          .rowsGap($r('app.float.space_sm'))
          .width('100%')
          .layoutWeight(1)
          .onReachEnd(() => {
            this.vm.loadMoreChannel(this.tid);
          })

          // 加载更多尾态
          if (this.vm.stateOf(this.tid).loadingMore) {
            LoadingState({ message: '加载中…' })
          } else if (this.vm.stateOf(this.tid).error.length > 0) {
            Text(this.vm.stateOf(this.tid).error)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .padding($r('app.float.space_sm'))
          } else if (!this.vm.stateOf(this.tid).hasMore) {
            Text('没有更多了')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .padding($r('app.float.space_sm'))
          }
        }
      }
      .width('100%')
      .height('100%')
    }
    .onRefreshing(() => {
      this.vm.refreshChannel(this.tid);
    })
    .width('100%')
    .height('100%')
  }

  /** 断点 → Grid 列模板（对齐首页频道列表） */
  private columnsTemplate(): string {
    const breakpoint: string = GlobalState.windowSizeInfo().breakpoint;
    if (breakpoint === 'xl') {
      return '1fr 1fr 1fr 1fr 1fr 1fr';
    }
    if (breakpoint === 'lg') {
      return '1fr 1fr 1fr 1fr';
    }
    if (breakpoint === 'md') {
      return '1fr 1fr 1fr';
    }
    return '1fr 1fr';
  }
}

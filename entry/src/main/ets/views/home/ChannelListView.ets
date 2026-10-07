/**
 * 内容频道列表视图
 * - 新番/影剧/游戏/动画四频道内容流（api_v2 list.php）
 * - Grid + Repeat + virtualScroll：多列自适应栅格 + 按需创建（大分页列表虚拟化）
 * - 排序切换（TagFilter：发布时间/弹幕数/播放数）、下拉刷新、触底加载更多、错误态重试
 */
import { HomeVM } from '../../viewmodel/HomeVM';
import { SortOrder, SortOrderText } from '../../common/Constants';
import { GlobalState, WindowSizeInfo } from '../../common/GlobalState';
import { Router } from '../../common/Router';
import { TagFilter } from '../../components/TagFilter';
import { ErrorRetry } from '../../components/ErrorRetry';
import { LoadingState } from '../../components/LoadingState';
import { EmptyView } from '../../components/EmptyView';
import { VideoCardView } from './VideoCardView';
import { Video } from '../../model/entity/BaseEntities';

@ComponentV2
export struct ChannelListView {
  /** 频道 tid（新番24/影剧23/游戏21/动画19） */
  @Param tid: number = 0;
  /** 所属 Tab 是否激活（手机形态懒加载门控） */
  @Param active: boolean = false;
  private vm: HomeVM = HomeVM.shared();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  aboutToAppear(): void {
    if (this.active) {
      this.vm.loadChannel(this.tid);
    }
  }

  @Monitor('active')
  onActiveChange(): void {
    if (this.active) {
      this.vm.loadChannel(this.tid);
    }
  }

  /** 断点 → Grid 列模板（手机 2 列 / 中屏 3 列 / 大屏 4 列 / 超大屏 6 列） */
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

  /** 当前排序下标 */
  private orderIndex(order: SortOrder): number {
    if (order === SortOrder.MUKIO) {
      return 1;
    }
    if (order === SortOrder.PLAY) {
      return 2;
    }
    return 0;
  }

  build() {
    // lg/xl 大屏全宽铺满（去掉 8/2 缩进，充分利用屏幕空间）
    GridRow({ columns: 12 }) {
      GridCol({
        span: { xs: 12, sm: 12, md: 12, lg: 12, xl: 12 },
        offset: { xs: 0, sm: 0, md: 0, lg: 0, xl: 0 }
      }) {
        Refresh({ refreshing: this.vm.feedOf(this.tid).refreshing }) {
      Column() {
        // 新番频道头部入口（对齐安卓 BangumiViewModel：放送表/历史新番）
        if (this.tid === 24) {
          Row({ space: $r('app.float.space_md') }) {
            Blank()
            Text('放送表')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.brand'))
              .padding({
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .onClick(() => {
                Router.goShowtime();
              })
            Text('历史新番')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.brand'))
              .padding({
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .onClick(() => {
                Router.goAnimeTime();
              })
          }
          .width('100%')
          .padding({ top: $r('app.float.space_xs') })
        }

        TagFilter({
          labels: [SortOrderText.of(SortOrder.DATE), SortOrderText.of(SortOrder.MUKIO), SortOrderText.of(SortOrder.PLAY)],
          selectedIndex: this.orderIndex(this.vm.feedOf(this.tid).order),
          onSelect: (index: number) => {
            const orders: SortOrder[] = [SortOrder.DATE, SortOrder.MUKIO, SortOrder.PLAY];
            const picked: SortOrder | undefined = orders[index];
            if (picked !== undefined) {
              this.vm.changeOrder(this.tid, picked);
            }
          }
        })

        if (this.vm.feedOf(this.tid).loading) {
          LoadingState({ message: '正在加载频道内容…' })
        } else if (this.vm.feedOf(this.tid).error.length > 0 && this.vm.feedOf(this.tid).videos.length === 0) {
          ErrorRetry({
            message: this.vm.feedOf(this.tid).error,
            onRetry: (): void => {
              this.vm.refreshChannel(this.tid);
            }
          })
        } else if (this.vm.feedOf(this.tid).videos.length === 0) {
          EmptyView({ message: '本频道暂无内容' })
        } else {
          Grid() {
            Repeat(this.vm.feedOf(this.tid).videos)
              .each((repeatItem: RepeatItem<Video>) => {
                GridItem() {
                  VideoCardView({ video: repeatItem.item })
                }
              })
              .key((card: Video, index: number) => `${card.hid}-${index}`)
              .virtualScroll({ totalCount: this.vm.feedOf(this.tid).videos.length })
          }
          .columnsTemplate(this.columnsTemplate())
          .columnsGap($r('app.float.space_sm'))
          .rowsGap($r('app.float.space_sm'))
          .width('100%')
          .layoutWeight(1)
          .onReachEnd(() => {
            this.vm.loadMoreChannel(this.tid);
          })
        }

        // 加载更多尾态
        if (this.vm.feedOf(this.tid).loadingMore) {
          LoadingState({ message: '加载中…' })
        } else if (this.vm.feedOf(this.tid).error.length > 0 && this.vm.feedOf(this.tid).videos.length > 0) {
          Text(this.vm.feedOf(this.tid).error)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_tertiary'))
            .padding($r('app.float.space_sm'))
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
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}

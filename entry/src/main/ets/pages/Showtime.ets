/**
 * 放送表页
 * - 九组放送（周末/周一..周六/剧场/天朝）：List + ListItemGroup 分组吸顶，
 *   页签（TagFilter）点击定位到对应组
 * - 默认定位今日组（站点 li.now 标记，兜底按星期推算）
 * - 组内条目为竖版海报墙（3/4/6/8 列随断点），封面底部叠加「更新N话」状态
 * - 点击条目：有 hid 进视频详情（海报卡 hero 采集，失败降级普通跳转）；无 hid 降级为关键词搜索
 * - 路由：router_map.json → ShowtimeBuilder（无参数；Router.goShowtime()）
 */
import { Router } from '../common/Router';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { ShowtimeEntry, ShowtimeGroup, ShowtimeVM } from '../viewmodel/ShowtimeVM';
import { TagFilter } from '../components/TagFilter';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { EmptyView } from '../components/EmptyView';
import { NetworkImage } from '../components/NetworkImage';
import { HeroCardParam, HeroRectUtils, HeroSource, HeroSourceState, HeroTransition, RectPx } from '../common/HeroTransition';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function ShowtimeBuilder(name: string, param: Object) {
  Showtime()
}

/** 海报卡 hero 转场起始圆角：与封面 borderRadius(radius_card=12fp) 一致 */
const SHOWTIME_CARD_CORNER_RADIUS: number = 12;

@ComponentV2
struct Showtime {
  /** 选中的星期组下标（TagFilter 联动） */
  @Local selectedGroup: number = 0;
  private vm: ShowtimeVM = ShowtimeVM.shared();
  private scroller: Scroller = new Scroller();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  aboutToAppear(): void {
    this.vm.load().then((): void => {
      if (this.vm.state.defaultGroupIndex > 0) {
        this.selectedGroup = this.vm.state.defaultGroupIndex;
        // 布局完成后定位到今日组
        setTimeout((): void => {
          this.scroller.scrollToIndex(this.selectedGroup, false);
        }, 100);
      }
    });
  }

  /** 断点 → 海报墙列数 */
  private chunkSize(): number {
    const breakpoint: string = this.windowSize.breakpoint;
    if (breakpoint === 'xl') {
      return 8;
    }
    if (breakpoint === 'lg') {
      return 6;
    }
    if (breakpoint === 'md') {
      return 4;
    }
    return 3;
  }

  /** 条目按列数切分为行 */
  private chunkEntries(entries: ShowtimeEntry[], size: number): ShowtimeEntry[][] {
    const rows: ShowtimeEntry[][] = [];
    for (let i = 0; i < entries.length; i += size) {
      const row: ShowtimeEntry[] = [];
      for (let j = i; j < i + size && j < entries.length; j++) {
        row.push(entries[j]);
      }
      rows.push(row);
    }
    return rows;
  }

  /** 组标题文案（今日组附「今天」标记） */
  private groupLabels(): string[] {
    const labels: string[] = [];
    for (let i = 0; i < this.vm.state.groups.length; i++) {
      labels.push(this.vm.state.groups[i].isToday
        ? `${this.vm.state.groups[i].title}·今天`
        : this.vm.state.groups[i].title);
    }
    return labels;
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
          Text('放送表')
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

        // ===== 星期组页签 =====
        TagFilter({
          labels: this.groupLabels(),
          selectedIndex: this.selectedGroup,
          onSelect: (index: number) => {
            this.selectedGroup = index;
            this.scroller.scrollToIndex(index, false);
          }
        })

        // ===== 分组海报墙 =====
        if (this.vm.state.loading) {
          LoadingState({ message: '正在加载放送表…' })
        } else if (this.vm.state.error.length > 0) {
          ErrorRetry({
            message: this.vm.state.error,
            onRetry: (): void => {
              this.vm.refresh();
            }
          })
        } else if (this.vm.state.groups.length === 0) {
          EmptyView({ message: '暂无放送内容' })
        } else {
          Refresh({ refreshing: this.vm.state.refreshing }) {
            List({ scroller: this.scroller }) {
              ForEach(this.vm.state.groups, (group: ShowtimeGroup) => {
                ListItemGroup({ header: (): void => {
                  this.groupHeader(group)
                } }) {
                  ForEach(this.chunkEntries(group.entries, this.chunkSize()),
                    (row: ShowtimeEntry[]) => {
                      ListItem() {
                        Row({ space: $r('app.float.space_sm') }) {
                          ForEach(row, (entry: ShowtimeEntry) => {
                            ShowtimeCardView({ entry: entry })
                          }, (entry: ShowtimeEntry) => `${entry.hid}-${entry.title}`)
                        }
                        .width('100%')
                      }
                    }, (row: ShowtimeEntry[], index: number) =>
                      `${index}-${row[0] !== undefined ? row[0].title : ''}`)
                }
              }, (group: ShowtimeGroup) => group.title)
            }
            .sticky(StickyStyle.Header)
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)
          }
          .onRefreshing(() => {
            this.vm.refresh();
          })
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
  }

  /** 组头（吸顶）：组名 + 今日高亮 */
  @Builder
  groupHeader(group: ShowtimeGroup) {
    Row({ space: $r('app.float.space_xs') }) {
      Text(group.title)
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Bold)
        .fontColor(group.isToday ? $r('app.color.brand') : $r('app.color.text_primary'))
      if (group.isToday) {
        Text('今天')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius($r('app.float.radius_button'))
          .padding({
            left: $r('app.float.space_sm'),
            right: $r('app.float.space_sm'),
            top: 1,
            bottom: 1
          })
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_lg'),
      right: $r('app.float.space_lg'),
      top: $r('app.float.space_sm'),
      bottom: $r('app.float.space_sm')
    })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.page_background'))
  }
}

/** 放送海报卡片：竖版封面 + 更新状态角标 + 标题；点击进详情（hero 采集，失败降级普通跳转） */
@ComponentV2
struct ShowtimeCardView {
  @Param entry: ShowtimeEntry = new ShowtimeEntry('', '', '', '');
  /** hero 转场源状态（activeToken 命中本卡实例时隐藏封面/标题，避免与飞行画面双重露出） */
  @Local heroSource: HeroSourceState = HeroSource.getState();
  /** 本卡实例 token（构造时一次性取号；同 hid 多卡时区分采集与隐藏目标） */
  private heroToken: string = HeroTransition.nextSourceToken();

  /** hero 封面节点 id（hid + 实例 token，全树唯一） */
  private coverNodeId(): string {
    return `showtime-card-cover-${this.entry.hid}-${this.heroToken}`;
  }

  /** hero 标题节点 id（hid + 实例 token，全树唯一） */
  private titleNodeId(): string {
    return `showtime-card-title-${this.entry.hid}-${this.heroToken}`;
  }

  /** 点击进详情：双 rect 采集成功 → hero 连续缩放转场；任一失败 → 普通跳转（照搬 VideoCardView 契约） */
  private openDetail(): void {
    const coverRect: RectPx | null =
      HeroRectUtils.captureRectPx(this.getUIContext(), this.coverNodeId());
    const titleRect: RectPx | null =
      HeroRectUtils.captureRectPx(this.getUIContext(), this.titleNodeId());
    if (coverRect === null || titleRect === null) {
      Router.goVideoDetail(this.entry.hid);
      return;
    }
    const heroParam: HeroCardParam = new HeroCardParam();
    heroParam.coverRect = coverRect;
    heroParam.titleRect = titleRect;
    heroParam.title = this.entry.title;
    heroParam.coverUrl = this.entry.thumb;
    heroParam.cornerRadius = SHOWTIME_CARD_CORNER_RADIUS;
    heroParam.coverId = this.coverNodeId();
    heroParam.titleId = this.titleNodeId();
    heroParam.sourceToken = this.heroToken;
    this.heroSource.markSource(this.heroToken);
    Router.goVideoDetailWithTransition(this.entry.hid, heroParam);
  }

  build() {
    Column({ space: $r('app.float.space_xs') }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        NetworkImage({
          url: this.entry.thumb,
          imageWidth: '100%',
          imageHeight: '100%',
          fit: ImageFit.Cover
        })
          .width('100%')
          .aspectRatio(0.75)
          .borderRadius($r('app.float.radius_card'))
          .clip(true)

        if (this.entry.status.length > 0) {
          Text(this.entry.status)
            .fontSize(10)
            .fontColor(Color.White)
            .backgroundColor('rgba(0,0,0,0.55)')
            .borderRadius($r('app.float.radius_button'))
            .padding({
              left: $r('app.float.space_xs'),
              right: $r('app.float.space_xs'),
              top: 1,
              bottom: 1
            })
            .margin($r('app.float.space_xs'))
        }
      }
      .width('100%')
      .id(this.coverNodeId())
      .visibility(this.heroSource.activeToken === this.heroToken
        ? Visibility.Hidden : Visibility.Visible)

      Text(this.entry.title)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .height(32)
        .width('100%')
        .id(this.titleNodeId())
        .visibility(this.heroSource.activeToken === this.heroToken
          ? Visibility.Hidden : Visibility.Visible)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      if (this.entry.hid.length > 0) {
        this.openDetail();
      } else if (this.entry.title.length > 0) {
        Router.goSearch(this.entry.title);
      }
    })
  }
}

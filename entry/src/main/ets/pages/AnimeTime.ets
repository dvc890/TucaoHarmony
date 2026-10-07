/**
 * 历史新番页（大屏 UX 适配 → 大屏网格化）
 * - 年代/季度筛选（Select 下拉，对齐安卓筛选项）+ 结果计数「共 N 个相关结果」
 * - SM 条目行：封面 + 标题 + 播放数/UP 主；点击行卡 hero 采集进详情（失败降级普通跳转）；
 *   下拉刷新 + 触底加载更多（50 条/页）
 * - MD/LG/XL：复用 VideoGridView 视频卡网格（SM2/MD3/LG4/XL6 全应用惯例列数，
 *   照搬 Search/Star 网格写法；触底加载与尾态保持，筛选/导航逻辑零变化）
 * - 路由：router_map.json → AnimeTimeBuilder（无参数；Router.goAnimeTime()）
 */
import { Router } from '../common/Router';
import { AnimeTimeVM, FilterOption } from '../viewmodel/AnimeTimeVM';
import { Video } from '../model/entity/BaseEntities';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { EmptyView } from '../components/EmptyView';
import { NetworkImage } from '../components/NetworkImage';
import { VideoGridView } from '../components/VideoGridView';
import { PlayCountText } from '../views/home/VideoCardView';
import { HeroCardParam, HeroRectUtils, HeroSource, HeroSourceState, HeroTransition, RectPx } from '../common/HeroTransition';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function AnimeTimeBuilder(name: string, param: Object) {
  AnimeTime()
}

/** 行卡 hero 转场起始圆角：与封面 borderRadius(radius_card=12fp) 一致 */
const ANIME_ROW_CORNER_RADIUS: number = 12;

@ComponentV2
struct AnimeTime {
  private vm: AnimeTimeVM = AnimeTimeVM.shared();
  /** 窗口断点（SM 行式 / MD+ 网格切换） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  aboutToAppear(): void {
    this.vm.initDefaultFilter();
    this.vm.load();
  }

  /** 筛选项 → Select 选项 */
  private toSelectOptions(options: FilterOption[]): SelectOption[] {
    const result: SelectOption[] = [];
    for (let i = 0; i < options.length; i++) {
      const option: SelectOption = { value: options[i].label };
      result.push(option);
    }
    return result;
  }

  /** 当前筛选值 → 选中下标 */
  private optionIndex(options: FilterOption[], value: string): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return i;
      }
    }
    return 0;
  }

  /** 当前筛选值显示文案 */
  private optionLabel(options: FilterOption[], value: string): string {
    const index: number = this.optionIndex(options, value);
    return options[index] !== undefined ? options[index].label : '';
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
          Text('历史新番')
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

        // ===== 筛选行 + 计数（全宽，两形态共用） =====
        Row({ space: $r('app.float.space_sm') }) {
          Select(this.toSelectOptions(AnimeTimeVM.yearOptions()))
            .selected(this.optionIndex(AnimeTimeVM.yearOptions(), this.vm.year))
            .value(this.optionLabel(AnimeTimeVM.yearOptions(), this.vm.year))
            .font({ size: $r('app.float.font_size_caption') })
            .selectedOptionFont({ size: $r('app.float.font_size_caption') })
            .optionFont({ size: $r('app.float.font_size_caption') })
            .onSelect((index: number) => {
              const options: FilterOption[] = AnimeTimeVM.yearOptions();
              const picked: FilterOption | undefined = options[index];
              if (picked !== undefined) {
                this.vm.changeYear(picked.value);
              }
            })

          Select(this.toSelectOptions(AnimeTimeVM.monthOptions()))
            .selected(this.optionIndex(AnimeTimeVM.monthOptions(), this.vm.month))
            .value(this.optionLabel(AnimeTimeVM.monthOptions(), this.vm.month))
            .font({ size: $r('app.float.font_size_caption') })
            .selectedOptionFont({ size: $r('app.float.font_size_caption') })
            .optionFont({ size: $r('app.float.font_size_caption') })
            .onSelect((index: number) => {
              const options: FilterOption[] = AnimeTimeVM.monthOptions();
              const picked: FilterOption | undefined = options[index];
              if (picked !== undefined) {
                this.vm.changeMonth(picked.value);
              }
            })

          if (this.vm.state.loadedOnce) {
            Text(`共 ${this.vm.state.total} 个相关结果`)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
              .textAlign(TextAlign.End)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({
          left: $r('app.float.space_lg'),
          right: $r('app.float.space_lg'),
          top: $r('app.float.space_xs'),
          bottom: $r('app.float.space_xs')
        })

        // ===== 列表 =====
        if (this.vm.state.loading) {
          LoadingState({ message: '正在加载番组…' })
        } else if (this.vm.state.error.length > 0 && this.vm.state.videos.length === 0) {
          ErrorRetry({
            message: this.vm.state.error,
            onRetry: (): void => {
              this.vm.refresh();
            }
          })
        } else if (this.vm.state.videos.length === 0) {
          EmptyView({ message: '没有找到相关番组' })
        } else if (this.windowSize.isCompact()) {
          // SM 基线：行式列表（零退化）
          Refresh({ refreshing: this.vm.state.refreshing }) {
            List({ space: 12 }) {
              Repeat(this.vm.state.videos)
                .each((repeatItem: RepeatItem<Video>) => {
                  ListItem() {
                    AnimeTimeRowView({ video: repeatItem.item })
                  }
                })
                .key((video: Video, index: number) => `${video.hid}-${index}`)
                .virtualScroll({ totalCount: this.vm.state.videos.length })

              // 加载更多尾态
              if (this.vm.state.loadingMore) {
                ListItem() {
                  LoadingState({ message: '加载中…' })
                }
              } else if (!this.vm.state.hasMore) {
                ListItem() {
                  Text('没有更多了')
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding($r('app.float.space_md'))
                }
              }
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)
            .onReachEnd(() => {
              this.vm.loadMore();
            })
          }
          .onRefreshing(() => {
            this.vm.refresh();
          })
          .width('100%')
          .layoutWeight(1)

          // 追加失败提示（列表非空时的错误）
          if (this.vm.state.error.length > 0) {
            Text(this.vm.state.error)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .padding($r('app.float.space_sm'))
          }
        } else {
          // MD/LG/XL：复用 VideoGridView 视频卡网格（3/4/6 列全应用惯例）
          Refresh({ refreshing: this.vm.state.refreshing }) {
            Column() {
              VideoGridView({
                videos: this.vm.state.videos,
                onReachEnd: (): void => {
                  this.vm.loadMore();
                }
              })

              // 加载更多尾态
              if (this.vm.state.loadingMore) {
                LoadingState({ message: '加载中…' })
              } else if (!this.vm.state.hasMore) {
                Text('没有更多了')
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding($r('app.float.space_md'))
              }

              // 追加失败提示（列表非空时的错误）
              if (this.vm.state.error.length > 0) {
                Text(this.vm.state.error)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding($r('app.float.space_sm'))
              }
            }
            .width('100%')
            .height('100%')
            .padding({
              left: $r('app.float.space_lg'),
              right: $r('app.float.space_lg')
            })
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
}

/** 番组行：封面 + 标题 + 播放数/UP 主（SM 行式形态）；点击进详情（hero 采集，失败降级普通跳转） */
@ComponentV2
struct AnimeTimeRowView {
  @Param video: Video = new Video();
  /** hero 转场源状态（activeToken 命中本行实例时隐藏封面/文字块，避免与飞行画面双重露出） */
  @Local heroSource: HeroSourceState = HeroSource.getState();
  /** 本行实例 token（构造时一次性取号；同 hid 多实例时区分采集与隐藏目标） */
  private heroToken: string = HeroTransition.nextSourceToken();

  /** hero 封面节点 id（hid + 实例 token，全树唯一） */
  private coverNodeId(): string {
    return `anime-row-cover-${this.video.hid}-${this.heroToken}`;
  }

  /** hero 标题节点 id（hid + 实例 token，全树唯一） */
  private titleNodeId(): string {
    return `anime-row-title-${this.video.hid}-${this.heroToken}`;
  }

  /** 点击进详情：双 rect 采集成功 → hero 连续缩放转场；任一失败 → 普通跳转（照搬 Rank 行卡契约） */
  private openDetail(): void {
    const coverRect: RectPx | null =
      HeroRectUtils.captureRectPx(this.getUIContext(), this.coverNodeId());
    const titleRect: RectPx | null =
      HeroRectUtils.captureRectPx(this.getUIContext(), this.titleNodeId());
    if (coverRect === null || titleRect === null) {
      Router.goVideoDetail(this.video.hid);
      return;
    }
    const heroParam: HeroCardParam = new HeroCardParam();
    heroParam.coverRect = coverRect;
    heroParam.titleRect = titleRect;
    heroParam.title = this.video.title;
    heroParam.coverUrl = this.video.thumb;
    heroParam.cornerRadius = ANIME_ROW_CORNER_RADIUS;
    heroParam.coverId = this.coverNodeId();
    heroParam.titleId = this.titleNodeId();
    heroParam.sourceToken = this.heroToken;
    this.heroSource.markSource(this.heroToken);
    Router.goVideoDetailWithTransition(this.video.hid, heroParam);
  }

  build() {
    Row({ space: $r('app.float.space_md') }) {
      NetworkImage({
        url: this.video.thumb,
        imageWidth: '100%',
        imageHeight: '100%',
        fit: ImageFit.Cover
      })
        .width(120)
        .aspectRatio(1.6)
        .borderRadius($r('app.float.radius_card'))
        .id(this.coverNodeId())
        .visibility(this.heroSource.activeToken === this.heroToken
          ? Visibility.Hidden : Visibility.Visible)

      Column({ space: $r('app.float.space_xs') }) {
        Text(this.video.title)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .id(this.titleNodeId())
        Row({ space: $r('app.float.space_sm') }) {
          Text(`▶ ${PlayCountText.format(this.video.play)}`)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_tertiary'))
          if (this.video.user.length > 0) {
            Text(this.video.user)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .visibility(this.heroSource.activeToken === this.heroToken
        ? Visibility.Hidden : Visibility.Visible)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('app.float.space_lg'),
      right: $r('app.float.space_lg')
    })
    .onClick((): void => {
      if (this.video.hid.length > 0) {
        this.openDetail();
      }
    })
  }
}

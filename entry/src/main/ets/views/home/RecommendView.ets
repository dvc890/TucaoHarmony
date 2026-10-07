/**
 * 推荐页视图
 * - 下拉刷新 + 整页滚动：轮播 Banner（自动播放）+ 分组视频卡片（GridRow 多列自适应）
 * - Banner 形态分支：SM 手机端全宽单卡 Swiper（内建滑动/自动播放/指示器），
 *   MD+ 维持 coverflow 多卡叠加；轮播统一在数据到达/hero 返回/手势结束后启动
 * - Banner 卡（中卡/侧卡）点击 hero 采集进详情：rect 点击瞬间采集，侧滑中/离屏卡
 *   采集失败降级普通跳转；转场期间隐藏源卡，避免与飞行画面双重露出；
 *   hero 点位 id 携带实例 token（本视图 token + banner 序号），同 hid 多卡不串扰
 * - 首页分组数据量小（≤6 组 × 8 条），非虚拟化栅格；内容频道的虚拟滚动在 ChannelListView 落实
 * - active 门控：手机形态 TabContent 预创建，仅在切至本 Tab 时才发起首次加载
 */
import { Video } from '../../model/entity/BaseEntities';
import { RecommendGroup } from '../../model/repository/VideoRepository';
import { HomeVM } from '../../viewmodel/HomeVM';
import { Router } from '../../common/Router';
import { GlobalState, WindowSizeInfo, WidthBreakpoint } from '../../common/GlobalState';
import { NetworkImage } from '../../components/NetworkImage';
import { ErrorRetry } from '../../components/ErrorRetry';
import { LoadingState } from '../../components/LoadingState';
import { VideoCardView } from './VideoCardView';
import { HeroCardParam, HeroRectUtils, HeroSource, HeroSourceState, HeroTransition, RectPx } from '../../common/HeroTransition';

/** banner 卡 hero 转场起始圆角：与卡片 borderRadius(radius_card=12fp) 一致 */
const BANNER_CORNER_RADIUS: number = 12;

@ComponentV2
export struct RecommendView {
  /** 所属 Tab 是否激活（手机形态懒加载门控） */
  @Param active: boolean = false;
  private vm: HomeVM = HomeVM.shared();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  /** 分组栅格列数（按窗口断点，与 ChannelListView.columnsTemplate 对齐：手机2/中屏3/大屏4/超大6） */
  private gridColumns(): number {
    const breakpoint: WidthBreakpoint = this.windowSize.breakpoint;
    if (breakpoint === WidthBreakpoint.XL) {
      return 6;
    }
    if (breakpoint === WidthBreakpoint.LG) {
      return 4;
    }
    if (breakpoint === WidthBreakpoint.MD) {
      return 3;
    }
    return 2;
  }

  aboutToAppear(): void {
    if (this.active) {
      // 轮播修复①：数据到达后再启动——loadRecommend 返回 Promise，loadedOnce 早退时
      // 数据已在、then 立即触发（幂等）；原先启动时 banners 必空，启动恒为 no-op 死路
      this.vm.loadRecommend(false).then((): void => {
        this.bannerStartAutoPlay();
      });
    }
  }

  @Monitor('active')
  onActiveChange(): void {
    if (this.active) {
      // 轮播修复①：同 aboutToAppear，数据到达后再启动
      this.vm.loadRecommend(false).then((): void => {
        this.bannerStartAutoPlay();
      });
    } else {
      this.bannerStopAutoPlay();
    }
  }

  /** 轮播修复②：hero 返回恢复——activeToken 归空（POP 清除/1600ms 兜底自清）且本 Tab
   *  可见时重启轮播；转场前 openBannerDetail 的 stop 保留，防飞行中换卡双重露出 */
  @Monitor('heroSource.activeToken')
  onHeroSourceChange(): void {
    if (this.heroSource.activeToken.length === 0 && this.active) {
      this.bannerStartAutoPlay();
    }
  }

  aboutToDisappear(): void {
    this.bannerStopAutoPlay();
  }

  build() {
    // lg/xl 大屏全宽铺满（去掉 8/2 缩进，充分利用屏幕空间）
    GridRow({ columns: 12 }) {
      GridCol({
        span: { xs: 12, sm: 12, md: 12, lg: 12, xl: 12 },
        offset: { xs: 0, sm: 0, md: 0, lg: 0, xl: 0 }
      }) {
        Refresh({ refreshing: this.vm.recommend.refreshing }) {
          Scroll() {
            Column() {
              if (this.vm.recommend.loading) {
                LoadingState({ message: '正在加载推荐…' })
              } else if (this.vm.recommend.error.length > 0) {
                ErrorRetry({
                  message: this.vm.recommend.error,
                  onRetry: (): void => {
                    this.vm.loadRecommend(true);
                  }
                })
              } else if (this.vm.recommend.groups.length === 0 && this.vm.recommend.banners.length === 0) {
                LoadingState({ message: '暂无推荐内容' })
              } else {
                // 头部入口行：排行（对齐安卓 RecommendViewModel.onClickRank）
                Row() {
                  Blank()
                  Text('排行 ›')
                    .fontSize($r('app.float.font_size_body'))
                    .fontColor($r('app.color.brand'))
                    .padding({
                      top: $r('app.float.space_xs'),
                      bottom: $r('app.float.space_xs')
                    })
                    .onClick(() => {
                      Router.goRank();
                    })
                }
                .width('100%')

                // banner 形态分支：SM 手机端单卡 Swiper；MD+ coverflow 零改动维持现状
                if (this.windowSize.isCompact()) {
                  this.SmBannerSwiper()
                } else {
                  this.BannerSection()
                }
                ForEach(this.vm.recommend.groups, (group: RecommendGroup) => {
                  this.GroupSection(group)
                }, (group: RecommendGroup) => `${group.tid}-${group.title}`)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({
              left: $r('app.float.space_md'),
              right: $r('app.float.space_md'),
              top: $r('app.float.space_sm'),
              bottom: $r('app.float.space_lg')
            })
          }
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)
          .width('100%')
          .height('100%')
        }
        .onRefreshing(() => {
          // 刷新完成后重跑轮播：数据整体替换由 effectiveCurrent 取模兜底防索引越界，
          // 同时治愈"刷新前轮播已停"（如加载竞态）的场景
          this.vm.refreshRecommend().then((): void => {
            this.bannerStartAutoPlay();
          });
        })
        .width('100%')
        .height('100%')
      }
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** 轮播区（3D 堆叠卡片轮播，MD+ 专用；SM 手机端走 SmBannerSwiper 单卡）——
   *  全宽布局（去掉平板 1100 限宽，消除左右黑边），当前卡居中最大、两侧卡
   *  缩小/透视旋转/后移堆叠露出，形成 coverflow 3D 堆叠观感；手动动画实现
   *  （本 SDK 无 stackEffects API）；
   *  中屏侧卡间距更近、大屏更开阔。 */
  @Local currentBanner: number = 0;
  /** 容器实测宽度（vp），用于计算卡宽 */
  @Local bannerAreaW: number = 0;
  /** hero 转场源状态（activeToken 命中本卡时隐藏 banner 源卡，避免与飞行画面双重露出） */
  @Local heroSource: HeroSourceState = HeroSource.getState();
  /** 本视图实例 token：banner 为 ForEach 内联项（非子组件实例），以「视图 token + 序号」
   *  组合出每个 banner 项的专属 token，替代原 hid 键控（同 hid 多卡会串扰） */
  private bannerToken: string = HeroTransition.nextSourceToken();
  /** SM 单卡 Swiper 自动播放开关：hero 转场/Tab 离开期间置 false 暂停，恢复轮播时置回 true */
  @Local smSwiperAutoPlay: boolean = true;
  private bannerTimer: number = -1;

  private bannerCount(): number {
    return this.vm.recommend.banners.length;
  }

  /** 安全索引：数据变更后 currentBanner 可能越界，各处统一取模 */
  private effectiveCurrent(): number {
    const n: number = this.bannerCount();
    if (n <= 0) {
      return 0;
    }
    return ((this.currentBanner % n) + n) % n;
  }

  /** 循环归约距离（如 n=8: index 7 相对 current 0 是 -1 而不是 7） */
  private bannerDelta(index: number): number {
    const n: number = this.bannerCount();
    let d: number = index - this.effectiveCurrent();
    if (n > 0) {
      const half: number = Math.floor(n / 2);
      while (d > half) {
        d -= n;
      }
      while (d < -half) {
        d += n;
      }
    }
    return d;
  }

  /** 各卡片相对当前卡的位移/缩放/角度（delta = bannerDelta(index)） */
  private bannerTx(delta: number): number {
    const cw: number = this.bannerCardWidth();
    const factor: number = this.windowSize.isExpanded() ? 0.62 : 0.55;
    return delta * cw * factor;
  }

  private bannerScale(delta: number): number {
    const d: number = Math.abs(delta);
    if (d <= 1) {
      return 1 - d * 0.18;
    }
    return 1 - 0.18 - (d - 1) * 0.16;
  }

  private bannerRotate(delta: number): number {
    const d: number = Math.abs(delta);
    const deg: number = d * 14;
    return delta < 0 ? -deg : deg;
  }

  private bannerCardWidth(): number {
    const ratio: number = this.windowSize.isExpanded() ? 0.48 : 0.56;
    return this.bannerAreaW * ratio;
  }

  private bannerOpacity(index: number): number {
    const d: number = Math.abs(this.bannerDelta(index));
    if (d === 0) {
      return 1;
    }
    if (d === 1) {
      return 0.92;
    }
    if (d === 2) {
      return 0.68;
    }
    return 0;
  }

  private bannerZIndex(index: number): number {
    return 20 - Math.abs(this.bannerDelta(index));
  }

  private bannerStep(): void {
    const n: number = this.bannerCount();
    if (n <= 1) {
      return;
    }
    const target: number = (this.currentBanner + 1) % n;
    animateTo({ duration: 420, curve: Curve.EaseOut }, () => {
      this.currentBanner = target;
    });
  }

  private bannerStartAutoPlay(): void {
    this.bannerStopAutoPlay();
    if (this.windowSize.isCompact()) {
      // SM 单卡：Swiper 内建 autoPlay 由标志驱动（绑定 .autoPlay 参数），无需手动定时器
      this.smSwiperAutoPlay = true;
      return;
    }
    // MD+ coverflow：setInterval 手动推进（本 SDK 无 stackEffects API，动画手动实现）
    if (this.bannerCount() > 1) {
      this.bannerTimer = setInterval(() => {
        this.bannerStep();
      }, 4000);
    }
  }

  private bannerStopAutoPlay(): void {
    if (this.bannerTimer >= 0) {
      clearInterval(this.bannerTimer);
      this.bannerTimer = -1;
    }
    // SM 单卡同步暂停（MD+ 下该标志无渲染消费方，置 false 无副作用）
    this.smSwiperAutoPlay = false;
  }

  /** banner 项 hero 点位 token：视图实例 token + banner 序号（ForEach 内联项无实例身份，序号充当） */
  private bannerItemToken(index: number): string {
    return `${this.bannerToken}-${index}`;
  }

  /** banner 项封面节点 id（hid + 项 token，全树唯一） */
  private bannerCoverNodeId(hid: string, token: string): string {
    return `banner-cover-${hid}-${token}`;
  }

  /** banner 项标题节点 id（hid + 项 token，全树唯一） */
  private bannerTitleNodeId(hid: string, token: string): string {
    return `banner-title-${hid}-${token}`;
  }

  /** 点击 banner 卡进详情：双 rect 采集成功 → hero 连续缩放转场；任一失败 → 普通跳转。
   *  中卡/侧卡同构，统一走本方法发射；coverflow 侧卡位置随轮播/侧滑实时变化，
   *  rect 在点击瞬间采集天然取到当前位置；离屏卡不构建、滑动中卡采集异常，
   *  均由 null 分支降级普通跳转兜底 */
  private openBannerDetail(banner: Video, token: string): void {
    // 路由前清场：停掉自动轮播，避免转场期间 currentBanner 继续推进
    this.bannerStopAutoPlay();
    const coverId: string = this.bannerCoverNodeId(banner.hid, token);
    const titleId: string = this.bannerTitleNodeId(banner.hid, token);
    const coverRect: RectPx | null = HeroRectUtils.captureRectPx(this.getUIContext(), coverId);
    const titleRect: RectPx | null = HeroRectUtils.captureRectPx(this.getUIContext(), titleId);
    if (coverRect === null || titleRect === null) {
      Router.goVideoDetail(banner.hid);
      return;
    }
    const heroParam: HeroCardParam = new HeroCardParam();
    heroParam.coverRect = coverRect;
    heroParam.titleRect = titleRect;
    heroParam.title = banner.title;
    heroParam.coverUrl = banner.thumb;
    heroParam.cornerRadius = BANNER_CORNER_RADIUS;
    heroParam.coverId = coverId;
    heroParam.titleId = titleId;
    heroParam.sourceToken = token;
    this.heroSource.markSource(token);
    Router.goVideoDetailWithTransition(banner.hid, heroParam);
  }

  /** SM 手机端单卡轮播（banner 形态分支，isCompact() 时替代 BannerSection）：
   *  恢复 96d3874 coverflow 重构前的首版形态（0d81cc9）——全宽单卡、aspectRatio 2.35、
   *  内建自动播放/循环/圆点指示器（brand 配色），消除侧卡溢出对"排行"行与圆点的遮挡。
   *  卡片内部结构与 MD+ coverflow 同构：hero 点位 id（banner-cover- 与 banner-title-
   *  前缀 + 项 token）+ 渐变浮层 + heroSource 转场隐藏 + openBannerDetail 点击进详情。
   *  不挂 PanGesture（Swiper 自带滑切手势）；自动播放经 smSwiperAutoPlay 标志启停 */
  @Builder
  SmBannerSwiper() {
    if (this.bannerCount() > 0) {
      Swiper() {
        ForEach(this.vm.recommend.banners, (banner: Video, index: number) => {
          Stack({ alignContent: Alignment.BottomStart }) {
            NetworkImage({
              url: banner.thumb,
              imageWidth: '100%',
              imageHeight: '100%',
              fit: ImageFit.Cover
            })
            Column({ space: 2 }) {
              Text(banner.title)
                .fontSize($r('app.float.font_size_title'))
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .id(this.bannerTitleNodeId(banner.hid, this.bannerItemToken(index)))
              if (banner.description.length > 0) {
                Text(banner.description)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor('rgba(255,255,255,0.85)')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding($r('app.float.space_md'))
            .linearGradient({
              angle: 180,
              colors: [['rgba(0,0,0,0.55)', 0.0], ['rgba(0,0,0,0)', 1.0]]
            })
          }
          .aspectRatio(2.35)
          .width('100%')
          .borderRadius($r('app.float.radius_card'))
          .clip(true)
          .id(this.bannerCoverNodeId(banner.hid, this.bannerItemToken(index)))
          .visibility(this.heroSource.activeToken === this.bannerItemToken(index)
            ? Visibility.Hidden : Visibility.Visible)
          .onClick(() => {
            if (banner.hid.length > 0) {
              this.openBannerDetail(banner, this.bannerItemToken(index));
            }
          })
        }, (banner: Video) => banner.hid)
      }
      .autoPlay(this.smSwiperAutoPlay)
      .interval(4000)
      .loop(true)
      .indicator(Indicator.dot()
        .color($r('app.color.text_tertiary'))
        .selectedColor($r('app.color.brand')))
      .width('100%')
    }
  }

  @Builder
  BannerSection() {
    if (this.bannerCount() > 0) {
      Column({ space: $r('app.float.space_md') }) {
        Stack({ alignContent: Alignment.Center }) {
          ForEach(this.vm.recommend.banners, (banner: Video, index: number) => {
            if (this.bannerOpacity(index) > 0) {
              Stack({ alignContent: Alignment.BottomStart }) {
                NetworkImage({
                  url: banner.thumb,
                  imageWidth: '100%',
                  imageHeight: '100%',
                  fit: ImageFit.Cover
                })
                Column({ space: 2 }) {
                  Text(banner.title)
                    .fontSize($r('app.float.font_size_title'))
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Color.White)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .id(this.bannerTitleNodeId(banner.hid, this.bannerItemToken(index)))
                  if (banner.description.length > 0) {
                    Text(banner.description)
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor('rgba(255,255,255,0.85)')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding($r('app.float.space_md'))
                .linearGradient({
                  angle: 180,
                  colors: [['rgba(0,0,0,0.55)', 0.0], ['rgba(0,0,0,0)', 1.0]]
                })
              }
              .width(this.bannerCardWidth())
              .aspectRatio(this.windowSize.isExpanded() ? 2.8 : 2.35)
              .borderRadius($r('app.float.radius_card'))
              .clip(true)
              .translate({
                x: this.bannerTx(this.bannerDelta(index)),
                y: 0
              })
              .scale({
                x: this.bannerScale(this.bannerDelta(index)),
                y: this.bannerScale(this.bannerDelta(index))
              })
              .rotate({
                x: 0,
                y: 1,
                z: 0,
                angle: this.bannerRotate(this.bannerDelta(index)),
                centerX: '50%',
                centerY: '50%'
              })
              .zIndex(this.bannerZIndex(index))
              .opacity(this.bannerOpacity(index))
              .id(this.bannerCoverNodeId(banner.hid, this.bannerItemToken(index)))
              .visibility(this.heroSource.activeToken === this.bannerItemToken(index)
                ? Visibility.Hidden : Visibility.Visible)
              .onClick(() => {
                if (banner.hid.length > 0) {
                  this.openBannerDetail(banner, this.bannerItemToken(index));
                }
              })
            }
          }, (banner: Video) => banner.hid)
        }
        .width('100%')
        .height(this.bannerCardWidth() / (this.windowSize.isExpanded() ? 2.8 : 2.35))
        .clip(false)
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          const w: number = Number(newValue.width);
          if (w > 0 && Math.abs(w - this.bannerAreaW) > 0.5) {
            this.bannerAreaW = w;
          }
        })
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
            .onActionStart(() => {
              this.bannerStopAutoPlay();
            })
            .onActionEnd((event: GestureEvent) => {
              const n: number = this.bannerCount();
              if (n <= 1) {
                return;
              }
              const dx: number = Number(event.offsetX);
              let target: number = this.currentBanner;
              if (dx < -30) {
                target = (this.currentBanner + 1) % n;
              } else if (dx > 30) {
                target = (this.currentBanner - 1 + n) % n;
              }
              animateTo({ duration: 420, curve: Curve.EaseOut }, () => {
                this.currentBanner = target;
              });
              this.bannerStartAutoPlay();
            })
        )

        Row({ space: 6 }) {
          ForEach(this.vm.recommend.banners, (banner: Video, index: number) => {
            Circle({ width: index === this.effectiveCurrent() ? 8 : 6, height: index === this.effectiveCurrent() ? 8 : 6 })
              .fill(index === this.effectiveCurrent() ? $r('app.color.brand') : $r('app.color.text_tertiary'))
          }, (banner: Video) => `${banner.hid}-dot`)
        }
        .alignSelf(ItemAlign.Center)
      }
    }
  }

  /** 分组区：标题 + 更多入口 + GridRow 多列卡片 */
  @Builder
  GroupSection(group: RecommendGroup) {
    Column({ space: $r('app.float.space_md') }) {
      Row() {
        Text(group.title)
          .fontSize($r('app.float.font_size_title_lg'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        if (group.tid > 0) {
          Text('更多 ›')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.brand'))
            .onClick(() => {
              Router.goChannelDetail(group.tid);
            })
        }
      }
      .width('100%')

      GridRow({ columns: this.gridColumns(), gutter: 8 }) {
        ForEach(group.videos, (card: Video) => {
          GridCol({ span: 1 }) {
            VideoCardView({ video: card })
          }
        }, (card: Video) => card.hid)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: $r('app.float.space_lg') })
  }
}

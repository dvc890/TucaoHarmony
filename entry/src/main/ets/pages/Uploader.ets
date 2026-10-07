/**
 * UP 主空间页（大屏 UX 适配；头部重做）
 * - 头部不常驻：banner 全宽（SM/MD 110vp、LG/XL 宽度 5:1），左上浮层半透明返回箭头，
 *   滚动后顶部品牌色小条（‹ + 昵称反白）淡入；头像/昵称/统计/私信/签名信息区保持内容宽度
 * - 「私信」按钮：提示性交互（toast「不发不发就不发σ`∀´)」，对齐安卓）
 * - 投稿列表：封面 + 标题 + 播放数；计数「共 N 个投稿」；触底加载更多；行卡点击 hero 进详情 + 悬停帧轮播
 *   （SM 保持单列行基线；MD/LG/XL → VideoCardView 网格 3/4/6 列）
 * - 路由：router_map.json → UploaderBuilder（param = userId 字符串）
 */
import { Router } from '../common/Router';
import { UploaderVM } from '../viewmodel/UploaderVM';
import { Video } from '../model/entity/BaseEntities';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { ContentWidth } from '../common/BreakpointLayout';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { EmptyView } from '../components/EmptyView';
import { NetworkImage } from '../components/NetworkImage';
import { VideoGridView } from '../components/VideoGridView';
import { PlayCountText, HoverPreviewController } from '../views/home/VideoCardView';
import { HeroCardParam, HeroRectUtils, HeroSource, HeroSourceState, HeroTransition, RectPx } from '../common/HeroTransition';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function UploaderBuilder(name: string, param: Object) {
  Uploader({ routeParam: param })
}

/** 投稿行卡 hero 转场起始圆角：与封面 borderRadius(radius_card=12fp) 一致 */
const UPLOADER_ROW_CORNER_RADIUS: number = 12;

/**  展开态 banner 高（SM/MD；LG/XL 按宽度 5:1 自适应） */
const UPLOADER_BANNER_HEIGHT: number = 110;
/**  顶部折叠小条高度（品牌色底 ‹ + 昵称） */
const UPLOADER_MINI_BAR_HEIGHT: number = 52;
/**  小条淡入跨度（offset 超过 banner 高后经此距离渐入到 1） */
const UPLOADER_MINI_BAR_FADE_SPAN: number = 60;
/**  MD+ 信息区收缩基准高（头像行 + 签名 + 计数的保守估值，驱动高度插值） */
const UPLOADER_MD_INFO_HEIGHT: number = 136;
/**  MD+ 信息区收缩淡出跨度（offset 前 120vp 内收缩并淡出） */
const UPLOADER_MD_INFO_FADE: number = 120;

@ComponentV2
struct Uploader {
  /** 路由参数（userId 字符串，aboutToAppear 收窄） */
  @Param routeParam: Object = new Object();
  @Local userId: string = '';
  /**  顶部小条不透明度（onDidScroll 每帧插值驱动，不用 animateTo） */
  @Local miniBarOpacity: number = 0;
  /**  MD+ 网格累计滚动偏移（VideoGridView.onScrollOffset 冒泡，驱动头部收缩） */
  @Local collapseOffset: number = 0;

  private vm: UploaderVM = UploaderVM.shared();
  /** 窗口断点（banner 适配与 SM/MD+ 分支切换） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();
  /**  SM 列表滚动器（onDidScroll 读取累计偏移驱动小条淡入） */
  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    if (typeof this.routeParam === 'string') {
      this.userId = this.routeParam;
    }
    if (this.userId.length > 0) {
      this.vm.load(this.userId);
    }
  }

  /** 私信：提示性交互（站点私信需登录态，先 toast 对齐安卓行为） */
  private onClickSendMessage(): void {
    this.getUIContext().getPromptAction().showToast({ message: '不发不发就不发σ`∀´)' });
  }

  /**  小条当前不透明度（首屏加载/错误态无 banner，常显小条保证返回可达） */
  private miniBarAlpha(): number {
    if (!this.vm.feed.loadedOnce) {
      return 1;
    }
    return this.miniBarOpacity;
  }

  /**  SM 列表滚动 → 小条每帧插值（offset 超过 banner 高后线性渐入） */
  private onSmListScroll(): void {
    const offset: number = this.listScroller.currentOffset().yOffset;
    const fade: number = (offset - UPLOADER_BANNER_HEIGHT) / UPLOADER_MINI_BAR_FADE_SPAN;
    this.miniBarOpacity = Math.min(Math.max(fade, 0), 1);
  }

  /**  MD+ 展开态 banner 高（SM/MD 110；LG/XL 全宽 5:1 自适应） */
  private mdBannerExpandedHeight(): number {
    if (this.windowSize.isExpanded() && this.windowSize.windowWidthVp > 0) {
      return this.windowSize.windowWidthVp / 5;
    }
    return UPLOADER_BANNER_HEIGHT;
  }

  /**  MD+ 折叠进度 0..1（offset 达展开高即完全折叠，每帧插值） */
  private mdCollapseRatio(): number {
    const expanded: number = this.mdBannerExpandedHeight();
    return Math.min(Math.max(this.collapseOffset / expanded, 0), 1);
  }

  /**  MD+ banner 现高 = lerp(展开高, 0, 折叠进度) */
  private mdBannerHeight(): number {
    return this.mdBannerExpandedHeight() * (1 - this.mdCollapseRatio());
  }

  /**  MD+ 信息区收缩透明度（offset 前 120vp 内平滑收缩淡出，无布局跳变） */
  private mdInfoAlpha(): number {
    return Math.min(Math.max(1 - this.collapseOffset / UPLOADER_MD_INFO_FADE, 0), 1);
  }

  /**  MD+ 网格滚动偏移回调 → banner 高度 + 信息区 + 小条三路每帧插值 */
  private onMdGridScroll(offset: number): void {
    this.collapseOffset = offset;
    this.miniBarOpacity = this.mdCollapseRatio();
  }

  /**  banner 现高（SM 恒 110；MD+ 随折叠进度插值）。修复：@Builder 按值传参不随状态刷新，改为 builder 内直读 */
  private currentBannerHeight(): number {
    return this.windowSize.isCompact() ? UPLOADER_BANNER_HEIGHT : this.mdBannerHeight();
  }

  /**  banner 全宽区（高由 builder 内直读组件状态：SM 恒 110，MD+ 随收缩插值） */
  @Builder
  UploaderHeadBanner() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.vm.header.banner.length > 0) {
        NetworkImage({
          url: this.vm.header.banner,
          imageWidth: '100%',
          imageHeight: '100%',
          fit: ImageFit.Cover
        })
      }
      // 底部轻微黑渐变遮罩（交界过渡 + 浮层内容可读性）
      Column()
        .width('100%')
        .height('45%')
        .linearGradient({
          angle: 180,
          colors: [['rgba(0,0,0,0)', 0.0], ['rgba(0,0,0,0.25)', 1.0]]
        })
        .position({ x: 0, y: '55%' })
      // 浮层返回钮（黑 30% 圆底白箭头；MD+ 随 banner 收缩消失，由顶部小条接管）
      Text('‹')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .backgroundColor('rgba(0,0,0,0.3)')
        .borderRadius(20)
        .margin({
          left: $r('app.float.space_sm'),
          top: $r('app.float.space_sm')
        })
        .onClick((): void => {
          Router.back();
        })
    }
    .width('100%')
    .height(this.currentBannerHeight())
    // 修复: MD+ 收缩至 0 时浮层箭头/渐变会溢出渲染与小条叠影，裁剪掉
    .clip(true)
    .backgroundColor($r('app.color.brand_surface'))
  }

  /**  信息区（头像/昵称/统计/私信/签名/计数，SM 与 MD+ 共用） */
  @Builder
  UploaderHeadInfo() {
    Column() {
      Row({ space: $r('app.float.space_md') }) {
        // 头像（压在 banner 上）
        NetworkImage({
          url: this.vm.header.avatar,
          imageWidth: '100%',
          imageHeight: '100%',
          fit: ImageFit.Cover
        })
          .width(56)
          .height(56)
          .borderRadius(28)
          .border({ width: 2, color: Color.White })
          .margin({ top: -28 })

        Column({ space: $r('app.float.space_xs') }) {
          Text(this.vm.header.nickname)
            .fontSize($r('app.float.font_size_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.vm.header.stats.length > 0) {
            Text(this.vm.header.stats)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: $r('app.float.space_sm') })

        // 私信按钮
        Text('私信')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.brand'))
          .borderRadius($r('app.float.radius_button'))
          .border({ width: 1, color: $r('app.color.brand') })
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            top: $r('app.float.space_xs'),
            bottom: $r('app.float.space_xs')
          })
          .margin({ top: $r('app.float.space_sm') })
          .onClick(() => {
            this.onClickSendMessage();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.vm.header.signature.length > 0) {
        Text(this.vm.header.signature)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ top: $r('app.float.space_sm') })
      }

      // 投稿计数
      if (this.vm.feed.loadedOnce) {
        Text(`共 ${this.vm.feed.total} 个投稿`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: $r('app.float.space_md') })
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_lg'),
      right: $r('app.float.space_lg'),
      bottom: $r('app.float.space_sm')
    })
  }

  /**
   *  头部卡片（SM 用）——banner 全宽 + 信息区原内边距，随列表自然滚出
   */
  @Builder
  UploaderHeadCard() {
    Column() {
      this.UploaderHeadBanner()
      this.UploaderHeadInfo()
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
  }

  /**
   *  MD+ 折叠头部——banner 全宽固定在网格上方，高度随网格 offset 从展开高插值收到 0；
   * 信息区 840 限宽居中，随收缩平滑淡出；收缩完成后顶部仅剩小条
   */
  @Builder
  UploaderMdHeader() {
    Column() {
      this.UploaderHeadBanner()
      // 信息区限宽居中（约定），高度随收缩插值 + 裁剪淡出
      Column() {
        this.UploaderHeadInfo()
      }
      .width('100%')
      .constraintSize({ maxWidth: ContentWidth.cap(840, this.windowSize.isExpanded()) })
      .height(UPLOADER_MD_INFO_HEIGHT * this.mdInfoAlpha())
      .clip(true)
      .opacity(this.mdInfoAlpha())
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
  }

  /**  顶部折叠小条（品牌色底，‹ + 昵称反白；opacity 随滚动插值淡入） */
  @Builder
  UploaderMiniBar() {
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
      Text(this.vm.header.loaded && this.vm.header.nickname.length > 0
        ? this.vm.header.nickname : 'UP主空间')
        .fontSize($r('app.float.font_size_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(UPLOADER_MINI_BAR_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.page_background'))
    .padding({
      left: $r('app.float.space_sm'),
      right: $r('app.float.space_md')
    })
    .opacity(this.miniBarAlpha())
    .hitTestBehavior(this.miniBarAlpha() > 0.01 ? HitTestMode.Default : HitTestMode.None)
    // 全局沉浸：小条可见时 topbar 底色仅扩展绘制延伸到状态栏下（不改布局；隐藏态 opacity 0 无绘制）
    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  build() {
    NavDestination() {
      // 头部不常驻——内容铺满，顶部小条浮层随滚动淡入（初始态仅 banner 上的浮层箭头）
      Stack({ alignContent: Alignment.TopStart }) {
        // ===== 内容区 =====
        Column() {
          if (this.vm.feed.loading && !this.vm.feed.loadedOnce) {
            LoadingState({ message: '正在加载空间…' })
          } else if (this.vm.feed.error.length > 0 && !this.vm.feed.loadedOnce) {
            ErrorRetry({
              message: this.vm.feed.error,
              onRetry: (): void => {
                this.vm.refresh();
              }
            })
          } else {
            Refresh({ refreshing: this.vm.feed.refreshing }) {
              if (this.windowSize.isCompact()) {
                // SM 基线：头部卡片 + 单列行列表（头卡随列表自然滚出）
                List({ space: 12, scroller: this.listScroller }) {
                  // ===== 头部卡片 =====
                  ListItem() {
                    this.UploaderHeadCard()
                  }

                  // ===== 投稿列表 =====
                  if (this.vm.feed.videos.length === 0) {
                    ListItem() {
                      EmptyView({ message: '还没有投稿内容' })
                    }
                  } else {
                    Repeat(this.vm.feed.videos)
                      .each((repeatItem: RepeatItem<Video>) => {
                        ListItem() {
                          UploaderRowView({ video: repeatItem.item })
                        }
                      })
                      .key((video: Video, index: number) => `${video.hid}-${index}`)
                      .virtualScroll({ totalCount: this.vm.feed.videos.length })
                  }

                  // 加载更多尾态
                  if (this.vm.feed.loadingMore) {
                    ListItem() {
                      LoadingState({ message: '加载中…' })
                    }
                  } else if (!this.vm.feed.hasMore && this.vm.feed.videos.length > 0) {
                    ListItem() {
                      Text('没有更多了')
                        .fontSize($r('app.float.font_size_caption'))
                        .fontColor($r('app.color.text_tertiary'))
                        .width('100%')
                        .textAlign(TextAlign.Center)
                        .padding($r('app.float.space_md'))
                    }
                  }

                  // 追加失败提示（列表非空时的错误）
                  if (this.vm.feed.error.length > 0) {
                    ListItem() {
                      Text(this.vm.feed.error)
                        .fontSize($r('app.float.font_size_caption'))
                        .fontColor($r('app.color.text_tertiary'))
                        .width('100%')
                        .textAlign(TextAlign.Center)
                        .padding($r('app.float.space_sm'))
                    }
                  }
                }
                .width('100%')
                .layoutWeight(1)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.None)
                .onDidScroll((): void => {
                  this.onSmListScroll();
                })
                .onReachEnd(() => {
                  this.vm.loadMore();
                })
              } else {
                // MD/LG/XL — 折叠头部固定在网格上方 + 视频卡网格 3/4/6 列（随滚动收缩）
                Column() {
                  // banner 全宽固定（信息区 840 限宽居中），高度随网格 offset 插值收缩
                  this.UploaderMdHeader()

                  Refresh({ refreshing: this.vm.feed.refreshing }) {
                    Column() {
                      if (this.vm.feed.videos.length === 0) {
                        Column() {
                          EmptyView({ message: '还没有投稿内容' })
                        }
                        .width('100%')
                        .layoutWeight(1)
                        .justifyContent(FlexAlign.Center)
                      } else {
                        VideoGridView({
                          videos: this.vm.feed.videos,
                          onReachEnd: (): void => {
                            this.vm.loadMore();
                          },
                          onScrollOffset: (offset: number): void => {
                            this.onMdGridScroll(offset);
                          }
                        })
                      }

                      // 加载更多尾态
                      if (this.vm.feed.loadingMore) {
                        LoadingState({ message: '加载中…' })
                      } else if (!this.vm.feed.hasMore && this.vm.feed.videos.length > 0) {
                        Text('没有更多了')
                          .fontSize($r('app.float.font_size_caption'))
                          .fontColor($r('app.color.text_tertiary'))
                          .width('100%')
                          .textAlign(TextAlign.Center)
                          .padding($r('app.float.space_md'))
                      }

                      // 追加失败提示（列表非空时的错误）
                      if (this.vm.feed.error.length > 0) {
                        Text(this.vm.feed.error)
                          .fontSize($r('app.float.font_size_caption'))
                          .fontColor($r('app.color.text_tertiary'))
                          .width('100%')
                          .textAlign(TextAlign.Center)
                          .padding($r('app.float.space_sm'))
                      }
                    }
                    .width('100%')
                    .height('100%')
                  }
                  .onRefreshing(() => {
                    this.vm.refresh();
                  })
                  .width('100%')
                  .layoutWeight(1)
                }
                .width('100%')
                .height('100%')
              }
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

        // 顶部固定小条（滚动后淡入，压在内容上方）
        this.UploaderMiniBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
  }
}

/** 投稿行：封面 + 标题 + 播放数；点击进详情（hero 采集 + 悬停帧轮播） */
@ComponentV2
struct UploaderRowView {
  @Param video: Video = new Video();
  /** hero 转场源状态（activeToken 命中本行实例时隐藏封面/标题/播放数） */
  @Local heroSource: HeroSourceState = HeroSource.getState();
  /** 本行实例 token（构造时一次性取号；同 hid 多实例时区分采集与隐藏目标） */
  private heroToken: string = HeroTransition.nextSourceToken();
  /** 悬停帧轮播控制器（空间投稿解析在 UploaderVM，暂无 previewFrames 字段时空数组休眠） */
  private hoverPreview: HoverPreviewController = new HoverPreviewController();
  /** 长按触发轮播后抑制随后的 onClick（长按成功后释放仍会派发点击）；下次按下复位 */
  private suppressClickAfterLongPress: boolean = false;

  /** hero 封面节点 id（hid + 实例 token，全树唯一） */
  private coverNodeId(): string {
    return `uploader-row-cover-${this.video.hid}-${this.heroToken}`;
  }

  /** hero 标题节点 id（hid + 实例 token，全树唯一） */
  private titleNodeId(): string {
    return `uploader-row-title-${this.video.hid}-${this.heroToken}`;
  }

  aboutToDisappear(): void {
    this.hoverPreview.stop();
  }

  /** 虚拟滚动节点换绑条目时终止旧轮播，防止帧地址串卡 */
  @Monitor('video')
  onItemRebind(): void {
    this.hoverPreview.stop();
  }

  /** 点击进详情：双 rect 采集成功 → hero 连续缩放转场；任一失败 → 普通跳转 */
  private openDetail(): void {
    // 路由前清场：终止本行（或全局任意卡）悬停轮播
    HoverPreviewController.stopActive();
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
    heroParam.cornerRadius = UPLOADER_ROW_CORNER_RADIUS;
    heroParam.coverId = this.coverNodeId();
    heroParam.titleId = this.titleNodeId();
    heroParam.sourceToken = this.heroToken;
    this.heroSource.markSource(this.heroToken);
    Router.goVideoDetailWithTransition(this.video.hid, heroParam);
  }

  build() {
    Row({ space: $r('app.float.space_md') }) {
      // 尺寸挂 Stack（内置节点）而非 NetworkImage 宿主：轮播换帧重建 option 时宿主
      // 测量会退化为内容尺寸，fit-content Stack 随之撑满父行、标题列被挤没（对齐
      // VideoCardView 网格卡模式）
      Stack({ alignContent: Alignment.TopEnd }) {
        NetworkImage({
          url: this.hoverPreview.displayUrl(this.video.thumb),
          imageWidth: '100%',
          imageHeight: '100%',
          fit: ImageFit.Cover
        })
          .aspectRatio(1.6)
          .borderRadius($r('app.float.radius_card'))

        // 悬停轮播帧进度指示（底部细进度条，静态封面态不渲染）
        if (this.hoverPreview.state.frameIndex >= 0 && this.hoverPreview.state.frameCount > 0) {
          Row() {
            Blank()
            Progress({
              value: this.hoverPreview.state.frameIndex + 1,
              total: this.hoverPreview.state.frameCount,
              type: ProgressType.Linear
            })
              .width('38%')
              .height(3)
              .color(Color.White)
              .backgroundColor('rgba(255,255,255,0.35)')
              .borderRadius(2)
          }
          .width('100%')
          .padding($r('app.float.space_xs'))
          .position({ x: 0, y: '100%' })
          .markAnchor({ x: 0, y: '100%' })
        }
      }
      .width(120)
      .aspectRatio(1.6)
      .id(this.coverNodeId())
      .visibility(this.heroSource.activeToken === this.heroToken
        ? Visibility.Hidden : Visibility.Visible)

      Text(this.video.title)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .id(this.titleNodeId())
        .visibility(this.heroSource.activeToken === this.heroToken
          ? Visibility.Hidden : Visibility.Visible)

      Text(`▶ ${PlayCountText.format(this.video.play)}`)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
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
      if (this.suppressClickAfterLongPress) {
        this.suppressClickAfterLongPress = false;
        return;
      }
      if (this.video.hid.length > 0) {
        this.openDetail();
      }
    })
    .onHover((isHover: boolean) => {
      if (isHover) {
        this.hoverPreview.start(this.video.previewFrames);
      } else {
        this.hoverPreview.stop();
      }
    })
    // 长按即看：触屏无悬停能力，长按 500ms 直接触发预览轮播；松手/滚动手势打断即停
    .parallelGesture(LongPressGesture({ repeat: false, duration: 500 })
      .onAction((): void => {
        this.suppressClickAfterLongPress = true;
        this.hoverPreview.start(this.video.previewFrames, true);
      })
      .onActionEnd((): void => {
        this.hoverPreview.stop();
      })
      .onActionCancel((): void => {
        this.hoverPreview.stop();
      }))
    // 按下即复位长按抑制标志：滚动打断长按（无点击派发）后标志不残留
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.suppressClickAfterLongPress = false;
      }
    })
  }
}

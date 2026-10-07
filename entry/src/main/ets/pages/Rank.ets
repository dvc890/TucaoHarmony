/**
 * 排行榜页（重做：api_v2 rank.php 已被站点废弃，改走站点 hot.html 网页体系；大屏 UX 适配）
 * - 8 榜 chip：排行榜/追番榜/弹幕榜/在线/神评论/无人区/u榜/热搜榜（全部单页全量）
 * - 主榜（排行榜）支持分类 chip 过滤（?p=：全站/连载新番/完结番组/剧场版/电影/电视剧/天朝出品）
 * - SM：单 List 平铺渲染（分区标题行 + 条目行）+ 虚拟滚动 + 下拉刷新（基线不变）
 * - MD/LG/XL：分区块 + 卡片网格 3/4/6 列（对齐首页 RecommendView 分组惯例）：
 *   视频榜 → VideoCardView 插槽（左上角名次/指标徽标，前三名品牌色；神评论/指标副文案）、
 *   u榜 → 用户卡（头像+昵称+指标小卡）、热搜 → 关键词小卡
 * - 条目点击：视频卡走 VideoCardView 内置 hero 转场 / 视频行→播放页（行卡 hero 采集 + 悬停帧轮播接线）
 *   / u榜→UP主页 / 热搜→搜索页（非视频条目不加 hero）
 * - kind 切换保留各榜缓存；主榜分类切换只清主榜缓存后重拉（数据保鲜）
 * - 弹幕榜保持服务器原始顺序渲染（严禁按数值重排；分组/网格只按行序切形态，天然不重排）
 * - 路由：router_map.json → RankBuilder（无参数；Router.goRank()）
 */
import { RankCategory } from '../common/Constants';
import { Router } from '../common/Router';
import { RankVM, RankKindMeta, RankRow, RankRowType } from '../viewmodel/RankVM';
import {
  RankKind,
  RankVideoItem,
  RankUserItem,
  RankKeywordItem
} from '../service/api/RankHtmlParser';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { VideoGridColumns } from '../common/BreakpointLayout';
import { Video } from '../model/entity/BaseEntities';
import { VideoCardView, HoverPreviewController } from '../views/home/VideoCardView';
import { HeroCardParam, HeroRectUtils, HeroSource, HeroSourceState, HeroTransition, RectPx } from '../common/HeroTransition';
import { TagFilter } from '../components/TagFilter';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { EmptyView } from '../components/EmptyView';
import { NetworkImage } from '../components/NetworkImage';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function RankBuilder(name: string, param: Object) {
  Rank()
}

/** 行卡 hero 转场起始圆角：与封面 borderRadius(radius_card=12fp) 一致 */
const RANK_ROW_CORNER_RADIUS: number = 12;

@ComponentV2
struct Rank {
  private vm: RankVM = RankVM.shared();

  aboutToAppear(): void {
    this.vm.loadRank(this.vm.currentKind, this.vm.currentCategory);
  }

  /** 主榜分类 chip 文案 */
  private categoryLabels(): string[] {
    const labels: string[] = [];
    for (let i = 0; i < RankCategory.ALL.length; i++) {
      labels.push(RankCategory.ALL[i].label);
    }
    return labels;
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（中性底）=====
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
          Text('排行')
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

        // ===== 榜单 chip（8 榜）=====
        TagFilter({
          labels: RankKindMeta.KIND_LABELS,
          selectedIndex: RankKindMeta.indexOfKind(this.vm.currentKind),
          onSelect: (index: number) => {
            const kind: RankKind = RankKindMeta.kindAt(index);
            this.vm.changeKind(kind);
            this.vm.loadRank(kind, this.vm.currentCategory);
          }
        })

        // ===== 主榜分类 chip（仅排行榜显示）=====
        if (this.vm.currentKind === RankKind.HOT) {
          TagFilter({
            labels: this.categoryLabels(),
            selectedIndex: RankCategory.indexOfCategory(this.vm.currentCategory),
            onSelect: (index: number) => {
              const category: RankCategory = RankCategory.at(index);
              this.vm.changeCategory(category);
              this.vm.loadRank(this.vm.currentKind, category);
            }
          })
        }

        // ===== 榜单内容 =====
        Column() {
          RankFeedView({ kind: this.vm.currentKind })
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
  }
}

/** 榜单内容区：加载/错误/空态 + 平铺行列表 + 下拉刷新（SM 单列行 / MD+ 分区块卡片网格） */
@ComponentV2
struct RankFeedView {
  @Param kind: RankKind = RankKind.HOT;
  private vm: RankVM = RankVM.shared();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  /** MD+ 分区块（HEADER 行 → 区块标题 + 其后条目行；无头行归匿名组；保持服务器顺序） */
  private sectionGroups(rows: RankRow[]): RankSectionGroup[] {
    const groups: RankSectionGroup[] = [];
    let current: RankSectionGroup | undefined = undefined;
    for (let i = 0; i < rows.length; i++) {
      const row: RankRow = rows[i];
      if (row.type === RankRowType.HEADER) {
        current = new RankSectionGroup(row.title);
        groups.push(current);
      } else {
        if (current === undefined) {
          current = new RankSectionGroup('');
          groups.push(current);
        }
        current.rows.push(row);
      }
    }
    const result: RankSectionGroup[] = [];
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].rows.length > 0) {
        result.push(groups[i]);
      }
    }
    return result;
  }

  build() {
    Refresh({ refreshing: this.vm.feedOf(this.kind, this.vm.currentCategory).refreshing }) {
      Column() {
        if (this.vm.feedOf(this.kind, this.vm.currentCategory).loading) {
          LoadingState({ message: '正在加载榜单…' })
        } else if (this.vm.feedOf(this.kind, this.vm.currentCategory).error.length > 0) {
          ErrorRetry({
            message: this.vm.feedOf(this.kind, this.vm.currentCategory).error,
            onRetry: (): void => {
              this.vm.refreshRank(this.kind, this.vm.currentCategory);
            }
          })
        } else if (this.vm.feedOf(this.kind, this.vm.currentCategory).rows.length === 0) {
          EmptyView({ message: '暂无上榜内容' })
        } else if (this.windowSize.isCompact()) {
          // SM 基线：单 List 平铺行（List space 参数仅收 string|number，取 space_md 数值 12vp）
          List({ space: 12 }) {
            Repeat(this.vm.feedOf(this.kind, this.vm.currentCategory).rows)
              .each((repeatItem: RepeatItem<RankRow>) => {
                ListItem() {
                  RankRowView({ row: repeatItem.item, kind: this.kind })
                }
              })
              .key((row: RankRow, index: number) => `${row.type}-${index}`)
              .virtualScroll({ totalCount: this.vm.feedOf(this.kind, this.vm.currentCategory).rows.length })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
        } else {
          // MD/LG/XL 分区块 + 卡片网格 3/4/6 列（对齐首页 RecommendView 分组惯例）
          Scroll() {
            Column({ space: $r('app.float.space_md') }) {
              ForEach(this.sectionGroups(this.vm.feedOf(this.kind, this.vm.currentCategory).rows),
                (group: RankSectionGroup) => {
                  Column({ space: $r('app.float.space_sm') }) {
                    if (group.title.length > 0) {
                      RankSectionHeaderView({ headerTitle: group.title })
                    }
                    GridRow({
                      columns: VideoGridColumns.count(this.windowSize.breakpoint),
                      gutter: 8
                    }) {
                      ForEach(group.rows, (row: RankRow) => {
                        GridCol({ span: 1 }) {
                          RankGridItemView({ row: row, kind: this.kind })
                        }
                      }, (row: RankRow, index: number) => `${row.type}-${index}`)
                    }
                    .width('100%')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }, (group: RankSectionGroup, index: number) => `${group.title}-${index}`)
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
      }
      .width('100%')
      .height('100%')
    }
    .onRefreshing(() => {
      this.vm.refreshRank(this.kind, this.vm.currentCategory);
    })
    .width('100%')
    .height('100%')
  }
}

/** 平铺行分发：按行类型渲染分区标题/视频/用户/关键词行 */
@ComponentV2
struct RankRowView {
  @Param row: RankRow = RankRow.header('');
  @Param kind: RankKind = RankKind.HOT;

  build() {
    if (this.row.type === RankRowType.HEADER) {
      RankSectionHeaderView({ headerTitle: this.row.title })
    } else if (this.row.type === RankRowType.VIDEO) {
      RankVideoRowView({ videoItem: this.row.video, rank: this.row.rank, kind: this.kind })
    } else if (this.row.type === RankRowType.USER) {
      RankUserRowView({ userItem: this.row.user, rank: this.row.rank })
    } else if (this.row.type === RankRowType.KEYWORD) {
      RankKeywordRowView({ kwItem: this.row.keyword })
    }
  }
}

/** 分区标题行：品牌色竖条 + 加粗标题（今天/本周/本月/今年、无人区分类、u榜栏目） */
@ComponentV2
struct RankSectionHeaderView {
  @Param headerTitle: string = '';

  build() {
    Row({ space: $r('app.float.space_sm') }) {
      Row()
        .width(3)
        .height(14)
        .borderRadius(2)
        .backgroundColor($r('app.color.brand'))
      Text(this.headerTitle)
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('app.float.space_lg'),
      right: $r('app.float.space_lg')
    })
  }
}

/** 视频行：名次 + 封面（角标）+ 标题/次指标/神评论/UP主；点击进播放页（hero 采集 + 悬停帧轮播） */
@ComponentV2
struct RankVideoRowView {
  @Param videoItem: RankVideoItem = new RankVideoItem();
  @Param rank: number = 0;
  @Param kind: RankKind = RankKind.HOT;
  /** hero 转场源状态（activeToken 命中本行实例时隐藏封面/文字块，避免与飞行画面双重露出） */
  @Local heroSource: HeroSourceState = HeroSource.getState();
  /** 本行实例 token（构造时一次性取号；多榜 Tab 同 hid 多实例时区分采集与隐藏目标） */
  private heroToken: string = HeroTransition.nextSourceToken();
  /** 悬停帧轮播控制器（与 VideoCardView 同模式；行卡数据暂无帧列表时休眠） */
  private hoverPreview: HoverPreviewController = new HoverPreviewController();
  /** 长按触发轮播后抑制随后的 onClick（长按成功后释放仍会派发点击）；下次按下复位 */
  private suppressClickAfterLongPress: boolean = false;

  /** hero 封面节点 id（hid + 实例 token，全树唯一） */
  private coverNodeId(): string {
    return `rank-row-cover-${this.videoItem.hid}-${this.heroToken}`;
  }

  /** hero 标题节点 id（hid + 实例 token，全树唯一） */
  private titleNodeId(): string {
    return `rank-row-title-${this.videoItem.hid}-${this.heroToken}`;
  }

  aboutToDisappear(): void {
    this.hoverPreview.stop();
  }

  /** 虚拟滚动节点换绑条目时终止旧轮播，防止帧地址串卡 */
  @Monitor('videoItem')
  onItemRebind(): void {
    this.hoverPreview.stop();
  }

  /** 行卡悬停帧列表：RankHtmlParser 已抽取 data-img（多数条目为空数组，轮播自然休眠） */
  private rowPreviewFrames(): string[] {
    return this.videoItem.previewFrames;
  }

  /** 前三名名次字号 */
  private rankFontSize(): number {
    if (this.rank === 1) {
      return 24;
    }
    if (this.rank === 2) {
      return 22;
    }
    if (this.rank === 3) {
      return 20;
    }
    return 16;
  }

  /** 前三名名次配色 */
  private rankColor(): Resource {
    if (this.rank <= 3) {
      return $r('app.color.brand');
    }
    return $r('app.color.text_tertiary');
  }

  /** 角标可见：弹幕/在线/神评论/无人区（主榜/追番的 p 角标为名次数字，与名次列重复，不显示） */
  private badgeVisible(): boolean {
    return (this.kind === RankKind.DANMU || this.kind === RankKind.ONLINE
      || this.kind === RankKind.DIGG || this.kind === RankKind.ZERO)
      && this.videoItem.badgeText.length > 0;
  }

  /** 次指标行文案（无人区文本自带「人错过」语义，无前缀） */
  private metricLine(): string {
    return this.videoItem.metricLabel.length > 0
      ? `${this.videoItem.metricLabel}：${this.videoItem.metricText}`
      : this.videoItem.metricText;
  }

  /** 点击进详情：双 rect 采集成功 → hero 连续缩放转场；任一失败 → 普通跳转（照搬 VideoCardView 契约） */
  private openDetail(): void {
    // 路由前清场：终止本行（或全局任意卡）悬停轮播
    HoverPreviewController.stopActive();
    const coverRect: RectPx | null =
      HeroRectUtils.captureRectPx(this.getUIContext(), this.coverNodeId());
    const titleRect: RectPx | null =
      HeroRectUtils.captureRectPx(this.getUIContext(), this.titleNodeId());
    if (coverRect === null || titleRect === null) {
      Router.goVideoDetail(this.videoItem.hid);
      return;
    }
    const heroParam: HeroCardParam = new HeroCardParam();
    heroParam.coverRect = coverRect;
    heroParam.titleRect = titleRect;
    heroParam.title = this.videoItem.title;
    heroParam.coverUrl = this.videoItem.cover;
    heroParam.cornerRadius = RANK_ROW_CORNER_RADIUS;
    heroParam.coverId = this.coverNodeId();
    heroParam.titleId = this.titleNodeId();
    heroParam.sourceToken = this.heroToken;
    this.heroSource.markSource(this.heroToken);
    Router.goVideoDetailWithTransition(this.videoItem.hid, heroParam);
  }

  build() {
    Row({ space: $r('app.float.space_md') }) {
      // 名次列（无人区无名次序号，整列隐藏）
      if (this.kind !== RankKind.ZERO) {
        Text(`${this.rank}`)
          .fontSize(this.rankFontSize())
          .fontWeight(FontWeight.Bold)
          .fontColor(this.rankColor())
          .width(32)
          .textAlign(TextAlign.Center)
      }
      // 封面 + 角标（弹幕数/在线人数/点赞数/尘封N天）
      // 尺寸挂 Stack（内置节点）而非 NetworkImage 宿主：轮播换帧重建 option 时宿主
      // 测量会退化为内容尺寸，fit-content Stack 随之撑满父行、标题列被挤没（对齐
      // VideoCardView 网格卡模式：显式定宽锚定 + 进度条 100% 百分比有确定参照）
      Stack({ alignContent: Alignment.TopEnd }) {
        NetworkImage({
          url: this.hoverPreview.displayUrl(this.videoItem.cover),
          imageWidth: '100%',
          imageHeight: '100%',
          fit: ImageFit.Cover
        })
          .aspectRatio(1.6)
          .borderRadius($r('app.float.radius_card'))
        if (this.badgeVisible()) {
          Text(this.videoItem.badgeText)
            .fontSize(10)
            .fontColor($r('app.color.text_on_brand'))
            .backgroundColor($r('app.color.mask'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 112 })
            .borderRadius({
              topLeft: 0,
              topRight: 12,
              bottomLeft: 12,
              bottomRight: 0
            })
            .padding({
              left: 6,
              right: 6,
              top: 2,
              bottom: 2
            })
        }
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
      // 标题 / 次指标 / 神评论 / UP主
      Column({ space: $r('app.float.space_xs') }) {
        Text(this.videoItem.title)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .id(this.titleNodeId())
        if (this.videoItem.metricText.length > 0) {
          Text(this.metricLine())
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
        if (this.videoItem.commentText.length > 0) {
          Text() {
            Span(this.videoItem.commentUser)
              .fontColor($r('app.color.brand'))
            Span(this.videoItem.commentText)
              .fontColor($r('app.color.text_secondary'))
          }
          .fontSize($r('app.float.font_size_caption'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.videoItem.upName.length > 0) {
          Text(this.videoItem.upName)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
        }
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
      if (this.suppressClickAfterLongPress) {
        this.suppressClickAfterLongPress = false;
        return;
      }
      if (this.videoItem.hid.length > 0) {
        this.openDetail();
      }
    })
    .onHover((isHover: boolean) => {
      if (isHover) {
        this.hoverPreview.start(this.rowPreviewFrames());
      } else {
        this.hoverPreview.stop();
      }
    })
    // 长按即看：触屏无悬停能力，长按 500ms 直接触发预览轮播；松手/滚动手势打断即停
    .parallelGesture(LongPressGesture({ repeat: false, duration: 500 })
      .onAction((): void => {
        this.suppressClickAfterLongPress = true;
        this.hoverPreview.start(this.rowPreviewFrames(), true);
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

/** u榜用户行：名次 + 圆形头像 + 用户名/趣味指标；点击进 UP 主页 */
@ComponentV2
struct RankUserRowView {
  @Param userItem: RankUserItem = new RankUserItem();
  @Param rank: number = 0;

  /** 前三名名次字号 */
  private rankFontSize(): number {
    if (this.rank === 1) {
      return 24;
    }
    if (this.rank === 2) {
      return 22;
    }
    if (this.rank === 3) {
      return 20;
    }
    return 16;
  }

  /** 前三名名次配色 */
  private rankColor(): Resource {
    if (this.rank <= 3) {
      return $r('app.color.brand');
    }
    return $r('app.color.text_tertiary');
  }

  /** 名次文本：u榜 p 角标优先（与 DOM 序号一致），缺省回退行号 */
  private rankText(): string {
    return this.userItem.badgeText.length > 0 ? this.userItem.badgeText : `${this.rank}`;
  }

  build() {
    Row({ space: $r('app.float.space_md') }) {
      Text(this.rankText())
        .fontSize(this.rankFontSize())
        .fontWeight(FontWeight.Bold)
        .fontColor(this.rankColor())
        .width(32)
        .textAlign(TextAlign.Center)
      NetworkImage({
        url: this.userItem.avatar,
        imageWidth: 48,
        imageHeight: 48,
        radius: 24
      })
      Column({ space: $r('app.float.space_xs') }) {
        Text(this.userItem.userName)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.userItem.metricText.length > 0) {
          Text(this.userItem.metricText)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('app.float.space_lg'),
      right: $r('app.float.space_lg')
    })
    .onClick((): void => {
      if (this.userItem.userId.length > 0) {
        Router.goUploader(this.userItem.userId);
      }
    })
  }
}

/** 热搜行：排名 + 关键词 + 热度；点击带关键词进搜索页 */
@ComponentV2
struct RankKeywordRowView {
  @Param kwItem: RankKeywordItem = new RankKeywordItem();

  /** 前三名排名字号 */
  private rankFontSize(): number {
    if (this.kwItem.rank === 1) {
      return 24;
    }
    if (this.kwItem.rank === 2) {
      return 22;
    }
    if (this.kwItem.rank === 3) {
      return 20;
    }
    return 16;
  }

  /** 前三名排名配色 */
  private rankColor(): Resource {
    if (this.kwItem.rank <= 3) {
      return $r('app.color.brand');
    }
    return $r('app.color.text_tertiary');
  }

  build() {
    Row({ space: $r('app.float.space_md') }) {
      Text(`${this.kwItem.rank}`)
        .fontSize(this.rankFontSize())
        .fontWeight(FontWeight.Bold)
        .fontColor(this.rankColor())
        .width(32)
        .textAlign(TextAlign.Center)
      Text(this.kwItem.keyword)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.kwItem.heatText.length > 0) {
        Text(this.kwItem.heatText)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('app.float.space_lg'),
      right: $r('app.float.space_lg')
    })
    .onClick((): void => {
      Router.goSearch(this.kwItem.keyword);
    })
  }
}

/** MD+ 分区块：HEADER 行折叠为区块标题，其后条目行归入本组（见 RankFeedView.sectionGroups） */
class RankSectionGroup {
  readonly title: string;
  readonly rows: RankRow[] = [];

  constructor(title: string) {
    this.title = title;
  }
}

/** 网格条目分发：按行类型渲染视频卡/用户卡/关键词小卡（HEADER 行不进入网格） */
@ComponentV2
struct RankGridItemView {
  @Param row: RankRow = RankRow.header('');
  @Param kind: RankKind = RankKind.HOT;

  build() {
    if (this.row.type === RankRowType.VIDEO) {
      RankVideoCardView({ videoItem: this.row.video, rank: this.row.rank, kind: this.kind })
    } else if (this.row.type === RankRowType.USER) {
      RankUserCardView({ userItem: this.row.user, rank: this.row.rank })
    } else if (this.row.type === RankRowType.KEYWORD) {
      RankKeywordCardView({ kwItem: this.row.keyword })
    }
  }
}

/** 视频卡（MD+ 网格）：RankVideoItem → VideoCardView 插槽映射；点击走卡片内置 hero 转场 */
@ComponentV2
struct RankVideoCardView {
  @Param videoItem: RankVideoItem = new RankVideoItem();
  @Param rank: number = 0;
  @Param kind: RankKind = RankKind.HOT;

  /** 徽标：主榜/追番/在线 = 名次序号；弹幕/神评论/无人区 = 解析器 p 角标（弹幕数/点赞数/尘封N天） */
  private badgeText(): string {
    if (this.kind === RankKind.DANMU || this.kind === RankKind.DIGG || this.kind === RankKind.ZERO) {
      return this.videoItem.badgeText;
    }
    return `${this.rank}`;
  }

  /** 徽标高亮：名次序号类 = top3 标记或前三名；指标角标类 = 解析器 n123 标记 */
  private badgeHighlight(): boolean {
    if (this.kind === RankKind.DANMU || this.kind === RankKind.DIGG || this.kind === RankKind.ZERO) {
      return this.videoItem.top3;
    }
    return this.videoItem.top3 || (this.rank >= 1 && this.rank <= 3);
  }

  /** 副文案：神评论 = 评论摘要（用户名自带尾冒号）；在线榜 = 在线人数；其余 = 次指标行，缺省回退 UP 主 */
  private subCaption(): string {
    if (this.kind === RankKind.DIGG && this.videoItem.commentText.length > 0) {
      return `${this.videoItem.commentUser}${this.videoItem.commentText}`;
    }
    if (this.videoItem.metricText.length > 0) {
      return this.videoItem.metricLabel.length > 0
        ? `${this.videoItem.metricLabel}：${this.videoItem.metricText}`
        : this.videoItem.metricText;
    }
    if (this.kind === RankKind.ONLINE && this.videoItem.badgeText.length > 0) {
      return this.videoItem.badgeText;
    }
    return this.videoItem.upName;
  }

  /** RankVideoItem → Video 映射（play/mukio 缺省 0；播放数浮层已由插槽关闭） */
  private mappedVideo(): Video {
    const v: Video = new Video();
    v.hid = this.videoItem.hid;
    v.title = this.videoItem.title;
    v.thumb = this.videoItem.cover;
    v.user = this.videoItem.upName;
    // 悬停预览帧透传（VideoCardView 的 hover 钩子读 video.previewFrames）
    v.previewFrames = this.videoItem.previewFrames;
    return v;
  }

  build() {
    VideoCardView({
      video: this.mappedVideo(),
      badgeText: this.badgeText(),
      badgeHighlight: this.badgeHighlight(),
      subCaption: this.subCaption(),
      showDanmakuCount: false,
      showPlayCount: false
    })
  }
}

/** u榜用户卡（MD+ 网格）：头像 + 名次徽标 + 昵称 + 指标小卡；点击进 UP 主页 */
@ComponentV2
struct RankUserCardView {
  @Param userItem: RankUserItem = new RankUserItem();
  @Param rank: number = 0;

  /** 名次文本：u榜 p 角标优先（与 DOM 序号一致），缺省回退行号 */
  private rankText(): string {
    return this.userItem.badgeText.length > 0 ? this.userItem.badgeText : `${this.rank}`;
  }

  /** 前三名高亮（解析器 n123 标记或行序前三） */
  private top3(): boolean {
    return this.userItem.top3 || (this.rank >= 1 && this.rank <= 3);
  }

  build() {
    Column({ space: $r('app.float.space_sm') }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          NetworkImage({
            url: this.userItem.avatar,
            imageWidth: 64,
            imageHeight: 64,
            radius: 32
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: $r('app.float.space_sm') })

        Text(this.rankText())
          .fontSize($r('app.float.font_size_caption'))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.top3() ? $r('app.color.text_on_brand') : Color.White)
          .backgroundColor(this.top3() ? $r('app.color.brand') : $r('app.color.mask'))
          .borderRadius($r('app.float.radius_button'))
          .padding({
            left: $r('app.float.space_sm'),
            right: $r('app.float.space_sm'),
            top: 2,
            bottom: 2
          })
          .maxLines(1)
          .position({ x: $r('app.float.space_xs'), y: $r('app.float.space_xs') })
      }
      .width('100%')

      Text(this.userItem.userName)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.userItem.metricText.length > 0) {
        Text(this.userItem.metricText)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({
            left: $r('app.float.space_sm'),
            right: $r('app.float.space_sm'),
            top: $r('app.float.space_xs'),
            bottom: $r('app.float.space_xs')
          })
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.radius_button'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: $r('app.float.space_sm') })
    .onClick((): void => {
      if (this.userItem.userId.length > 0) {
        Router.goUploader(this.userItem.userId);
      }
    })
  }
}

/** 热搜关键词小卡（MD+ 网格）：排名 + 关键词 + 热度；点击带关键词进搜索页 */
@ComponentV2
struct RankKeywordCardView {
  @Param kwItem: RankKeywordItem = new RankKeywordItem();

  build() {
    Row({ space: $r('app.float.space_sm') }) {
      Text(`${this.kwItem.rank}`)
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.kwItem.top3 ? $r('app.color.brand') : $r('app.color.text_tertiary'))
        .width(24)
        .textAlign(TextAlign.Center)
      Text(this.kwItem.keyword)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.kwItem.heatText.length > 0) {
        Text(this.kwItem.heatText)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md'),
      top: $r('app.float.space_sm'),
      bottom: $r('app.float.space_sm')
    })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .onClick((): void => {
      Router.goSearch(this.kwItem.keyword);
    })
  }
}

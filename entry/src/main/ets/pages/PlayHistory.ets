/**
 * 播放历史页（大屏 UX 适配）
 * - 列表行：缩略图 + 标题 + 记忆续播文案（看到第x集 xx:xx）；点击进详情（行卡 hero 采集 + 悬停帧轮播，
 *   自动断点续播/提示条）
 *   （SM 行式基线；MD/LG/XL → 视频卡网格 3/4/6 列，右键删除保留）
 * - 删除：手机左滑（swipeAction）；大屏鼠标右键菜单（bindContextMenu）；顶栏"清空"（确认弹窗）
 * - 空态：EmptyView 友好提示
 * - 路由：router_map.json → PlayHistoryBuilder（无参数；Router.goPlayHistory()）
 */
import { Video } from '../model/entity/BaseEntities';
import { HistoryVM } from '../viewmodel/HistoryVM';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { EmptyView } from '../components/EmptyView';
import { NetworkImage } from '../components/NetworkImage';
import { VideoGridView } from '../components/VideoGridView';
import { HoverPreviewController } from '../views/home/VideoCardView';
import { HeroCardParam, HeroRectUtils, HeroSource, HeroSourceState, HeroTransition, RectPx } from '../common/HeroTransition';
import { Router } from '../common/Router';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function PlayHistoryBuilder(name: string, param: Object) {
  PlayHistory()
}

/** 历史行卡 hero 转场起始圆角：与缩略图 radius(8) 一致 */
const HISTORY_ROW_CORNER_RADIUS: number = 8;

@ComponentV2
struct PlayHistory {
  @Local vm: HistoryVM = new HistoryVM();
  /** 窗口断点（SM 行式 / MD+ 网格切换） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  aboutToAppear(): void {
    this.vm.bind();
  }

  aboutToDisappear(): void {
    this.vm.unbind();
  }

  /** 删除单条 */
  private removeHistory(hid: string): void {
    this.vm.remove(hid);
    this.getUIContext().getPromptAction().showToast({ message: '已删除该记录' });
  }

  /** 清空确认弹窗 */
  private confirmClearAll(): void {
    if (this.vm.isEmpty()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '清空播放历史',
      message: '确定清空全部播放记录吗？该操作不可恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.vm.clearAll();
          this.getUIContext().getPromptAction().showToast({ message: '已清空播放历史' });
        }
      },
      cancel: (): void => {
      }
    });
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
          Text('播放历史')
            .fontSize($r('app.float.font_size_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          if (!this.vm.isEmpty()) {
            Text('清空')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_primary'))
              .padding($r('app.float.space_sm'))
              .onClick((): void => {
                this.confirmClearAll();
              })
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_sm'),
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })
        // 全局沉浸：topbar 底色仅扩展绘制延伸到状态栏下（不改布局，内容绝对位置不变）
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

        // ===== 列表 / 空态 =====
        if (this.vm.isEmpty()) {
          Column() {
            EmptyView({ message: '暂无播放历史，看完的视频会出现在这里' })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.windowSize.isCompact()) {
          // SM 基线：行式列表（左滑/右键删除；行卡 hero + 悬停轮播见 HistoryVideoRowView）
          List({ space: 4 }) {
            ForEach(this.vm.histories, (video: Video) => {
              ListItem() {
                HistoryVideoRowView({
                  video: video,
                  resumeText: this.vm.resumeTextOf(video)
                })
              }
              .bindContextMenu(this.buildDeleteMenu(video), ResponseType.RightClick)
              .swipeAction({
                end: this.buildDeleteSwipe(video)
              })
            }, (video: Video): string => video.hid)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            bottom: $r('app.float.space_md')
          })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        } else {
          // MD/LG/XL 视频卡网格 3/4/6 列（右键删除保留）
          Column() {
            VideoGridView({
              videos: this.vm.histories,
              contextMenuText: '删除该记录',
              onContextMenuAction: (video: Video): void => {
                this.removeHistory(video.hid);
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            bottom: $r('app.float.space_md')
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_background'))
  }

  /** 左滑删除按钮（手机形态） */
  @Builder
  private buildDeleteSwipe(video: Video) {
    Row() {
      Text('删除')
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_on_brand'))
        .padding({
          left: $r('app.float.space_lg'),
          right: $r('app.float.space_lg')
        })
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.error'))
        .borderRadius($r('app.float.radius_card'))
        .onClick((): void => {
          this.removeHistory(video.hid);
        })
    }
    .height('100%')
    .justifyContent(FlexAlign.End)
  }

  /** 右键删除菜单（大屏/鼠标形态） */
  @Builder
  private buildDeleteMenu(video: Video) {
    Menu() {
      MenuItem({ content: '删除该记录' })
        .onClick((): void => {
          this.removeHistory(video.hid);
        })
    }
  }
}

/** 历史行：缩略图 + 标题 + 记忆续播文案；点击进详情（hero 采集 + 悬停帧轮播） */
@ComponentV2
struct HistoryVideoRowView {
  @Param video: Video = new Video();
  /** 记忆续播文案（看到第x集 xx:xx），由页面 HistoryVM.resumeTextOf 计算 */
  @Param resumeText: string = '';
  /** hero 转场源状态（activeToken 命中本行实例时隐藏封面/文字块） */
  @Local heroSource: HeroSourceState = HeroSource.getState();
  /** 本行实例 token（构造时一次性取号；同 hid 多实例时区分采集与隐藏目标） */
  private heroToken: string = HeroTransition.nextSourceToken();
  /** 悬停帧轮播控制器（本地历史记录暂无 previewFrames 字段时空数组休眠） */
  private hoverPreview: HoverPreviewController = new HoverPreviewController();
  /** 长按触发轮播后抑制随后的 onClick（长按成功后释放仍会派发点击）；下次按下复位 */
  private suppressClickAfterLongPress: boolean = false;

  /** hero 封面节点 id（hid + 实例 token，全树唯一） */
  private coverNodeId(): string {
    return `history-row-cover-${this.video.hid}-${this.heroToken}`;
  }

  /** hero 标题节点 id（hid + 实例 token，全树唯一） */
  private titleNodeId(): string {
    return `history-row-title-${this.video.hid}-${this.heroToken}`;
  }

  aboutToDisappear(): void {
    this.hoverPreview.stop();
  }

  /** 节点换绑条目时终止旧轮播，防止帧地址串卡 */
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
    heroParam.cornerRadius = HISTORY_ROW_CORNER_RADIUS;
    heroParam.coverId = this.coverNodeId();
    heroParam.titleId = this.titleNodeId();
    heroParam.sourceToken = this.heroToken;
    this.heroSource.markSource(this.heroToken);
    Router.goVideoDetailWithTransition(this.video.hid, heroParam);
  }

  build() {
    Row({ space: $r('app.float.space_md') }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        NetworkImage({
          url: this.hoverPreview.displayUrl(this.video.thumb),
          imageWidth: 128,
          imageHeight: 80,
          radius: 8
        })

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
        if (this.resumeText.length > 0) {
          Text(this.resumeText)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.brand'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .visibility(this.heroSource.activeToken === this.heroToken
        ? Visibility.Hidden : Visibility.Visible)
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.card_background'))
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

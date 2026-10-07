/**
 * 共享视频网格（大屏 UX 适配：列表页 MD+ 内容网格化）
 * - 供搜索/UP 主投稿/收藏/播放历史等页面在 MD+ 复用频道页网格惯例：
 *   Grid + Repeat + virtualScroll（SM 2 / MD 3 / LG 4 / XL 6 列）
 * - 页面级 padding/限宽由调用方处理；根节点即 Grid，layoutWeight 撑满父容器剩余高度
 * - 右键菜单条件化：contextMenuText 为空时不绑定（避免空菜单，对齐 Star 页右键惯例）
 */
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { VideoGridColumns } from '../common/BreakpointLayout';
import { VideoCardView } from '../views/home/VideoCardView';
import { Video } from '../model/entity/BaseEntities';

@ComponentV2
export struct VideoGridView {
  /** 网格数据源 */
  @Param videos: Video[] = [];
  /** 卡片是否展示弹幕数（各页现状差异由调用方决定） */
  @Param showDanmakuCount: boolean = true;
  /** 卡片是否展示播放数浮层（指标由外部 caption 承载时传 false） */
  @Param showPlayCount: boolean = true;
  /** 右键菜单文案（空串 = 不启用右键菜单） */
  @Param contextMenuText: string = '';
  /** 右键菜单动作（contextMenuText 非空时生效） */
  @Event onContextMenuAction: (video: Video) => void = (_video: Video) => {};
  /** 触底回调（加载更多） */
  @Event onReachEnd: () => void = () => {};
  /**  滚动偏移冒泡（每帧回调累计纵向偏移；不传默认空实现，既有调用方零影响） */
  @Event onScrollOffset: (offset: number) => void = (_offset: number) => {};
  /**  网格滚动器（读累计偏移，避免 delta 自行累加的漂移/复位问题） */
  private scroller: Scroller = new Scroller();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  build() {
    // 本 SDK Grid 构造直收 Scroller（挂滚动器读累计偏移，不改变既有滚动行为）
    Grid(this.scroller) {
      Repeat(this.videos)
        .each((repeatItem: RepeatItem<Video>) => {
          GridItem() {
            if (this.contextMenuText.length > 0) {
              Column() {
                VideoCardView({
                  video: repeatItem.item,
                  showDanmakuCount: this.showDanmakuCount,
                  showPlayCount: this.showPlayCount
                })
              }
              .width('100%')
              .bindContextMenu(this.contextMenu(repeatItem.item), ResponseType.RightClick)
            } else {
              VideoCardView({
                video: repeatItem.item,
                showDanmakuCount: this.showDanmakuCount,
                showPlayCount: this.showPlayCount
              })
            }
          }
        })
        .key((video: Video, index: number): string => `${video.hid}-${index}`)
        .virtualScroll({ totalCount: this.videos.length })
    }
    .columnsTemplate(VideoGridColumns.template(this.windowSize.breakpoint))
    .columnsGap($r('app.float.space_sm'))
    .rowsGap($r('app.float.space_sm'))
    .width('100%')
    .layoutWeight(1)
    // 滚动容器通用行为（官方 FAQ faqs-arkui-725）：高度受限且内容不足视口时默认垂直居中，
    // 搜索结果少时整片网格悬空错乱 → 顶部对齐修正
    // （本组件被搜索/UP 主投稿/收藏/播放历史共用，一处修复全端生效）
    .align(Alignment.Top)
    .onReachEnd(() => {
      this.onReachEnd();
    })
    // 每帧冒泡累计偏移（onScrollOffset 未传时为默认空实现，零开销）
    .onDidScroll((_scrollOffset: number, _scrollState: ScrollState): void => {
      this.onScrollOffset(this.scroller.currentOffset().yOffset);
    })
  }

  /** 右键菜单（大屏/鼠标形态；调用方经 contextMenuText 启用） */
  @Builder
  contextMenu(video: Video) {
    Menu() {
      MenuItem({ content: this.contextMenuText })
        .onClick((): void => {
          this.onContextMenuAction(video);
        })
    }
  }
}

/**
 * 视频卡片（增强；大屏 UX 插槽扩展）
 * - 竖版栅格卡片：封面（16:10）+ 播放数浮层 + 标题两行
 * - 插槽（默认值零影响既有调用方）：badgeText/badgeHighlight 左上角徽标
 *   （排行榜名次/尘封天数）、subCaption 标题下副文案（神评论/指标行）、
 *   showPlayCount 播放数浮层开关（指标由外部承载时隐藏）
 * - 点击带 hid 跳详情（Router 参数纪律：hid + hero 轻量 rect 参数）
 * - 播放/弹幕计数万位缩写（对齐安卓「1.1万」文案习惯）
 * - hover 连续缩放锚点：封面/标题加 id（hid + 实例 token，全树唯一），点击时
 *   componentUtils 采集 rect → HeroCardParam 随路由传入 VideoDetail；采集失败降级
 *   普通跳转；转场期间（heroSource.activeToken 命中本卡实例）隐藏封面/标题
 *   （及副文案）避免与飞行画面双重露出
 * - hoverEffect + focusable（PC/平板悬停缩放反馈与键盘可达性）
 * - 悬停帧轮播：onHover（鼠标与手写笔悬停均触发，SDK common.d.ts 明确覆盖 stylus）
 *   500ms 防抖后每 700ms 循环换 previewFrames 帧；离开/卸载/路由即恢复静态封面；
 *   全局同时仅一张卡激活；previewFrames 为空无操作
 * - 长按即看（触屏）：LongPressGesture 500ms 立即轮播（跳过防抖），松手/滚动
 *   打断即停 —— 触屏设备无悬停事件的等价入口
 */
import { Video } from '../../model/entity/BaseEntities';
import { Router } from '../../common/Router';
import { NetworkImage } from '../../components/NetworkImage';
import { HeroCardParam, HeroRectUtils, HeroSource, HeroSourceState, HeroTransition, RectPx } from '../../common/HeroTransition';

/** hero 转场的起始圆角：与封面 borderRadius(radius_card=12fp) 一致 */
const CARD_CORNER_RADIUS: number = 12;

/** 计数文案：>=1万 → x.x万（去尾零） */
export class PlayCountText {
  static format(count: number): string {
    if (count >= 10000) {
      const wan: number = Math.round(count / 1000) / 10;
      const text: string = `${wan}`;
      return text.endsWith('.0') ? `${text.substring(0, text.length - 2)}万` : `${text}万`;
    }
    return `${count}`;
  }
}

/** 悬停帧轮播 UI 状态（@ObservedV2：帧地址切换与进度指示的直接驱动源） */
@ObservedV2
export class HoverPreviewState {
  /** 当前帧地址（空串 = 静态封面） */
  @Trace frameUrl: string = '';
  /** 当前帧下标（-1 = 轮播未激活） */
  @Trace frameIndex: number = -1;
  /** 帧总数（进度指示分母） */
  @Trace frameCount: number = 0;
}

/**
 * 悬停帧轮播控制器（网格卡与五页行卡共用）
 * - start：500ms 防抖后每 700ms 循环换帧；帧列表为空直接无操作
 * - stop：清防抖与轮播定时器并恢复静态封面（悬停离开/组件卸载/路由跳转）
 * - 全局单活：新卡 start 时先 stop 旧激活卡；stopActive 供点击路由前统一清场
 */
export class HoverPreviewController {
  /** 悬停启动防抖 ms */
  static readonly START_DELAY_MS: number = 500;
  /** 帧切换间隔 ms */
  static readonly FRAME_INTERVAL_MS: number = 700;
  /** 全局唯一激活控制器 */
  private static active: HoverPreviewController | undefined = undefined;

  /** UI 绑定状态（组件直接读取驱动封面切换与进度指示） */
  readonly state: HoverPreviewState = new HoverPreviewState();
  private frames: string[] = [];
  private delayTimer: number = -1;
  private frameTimer: number = -1;

  /** 悬停进入：防抖后启动循环换帧（空帧列表无操作；新悬停先停掉全局旧卡）
   *  immediate：长按等显式手势路径传 true，跳过防抖立即换帧（手势本身已含确认时长） */
  start(frames: string[], immediate: boolean = false): void {
    if (frames.length === 0) {
      return;
    }
    if (HoverPreviewController.active !== undefined && HoverPreviewController.active !== this) {
      HoverPreviewController.active.stop();
    }
    HoverPreviewController.active = this;
    this.frames = frames;
    this.state.frameCount = frames.length;
    if (this.delayTimer >= 0) {
      clearTimeout(this.delayTimer);
    }
    if (immediate) {
      this.delayTimer = -1;
      this.beginCycle();
      return;
    }
    this.delayTimer = setTimeout((): void => {
      this.delayTimer = -1;
      this.beginCycle();
    }, HoverPreviewController.START_DELAY_MS);
  }

  /** 悬停离开/组件卸载：清定时器恢复静态封面 */
  stop(): void {
    if (this.delayTimer >= 0) {
      clearTimeout(this.delayTimer);
      this.delayTimer = -1;
    }
    if (this.frameTimer >= 0) {
      clearInterval(this.frameTimer);
      this.frameTimer = -1;
    }
    this.frames = [];
    this.state.frameUrl = '';
    this.state.frameIndex = -1;
    this.state.frameCount = 0;
    if (HoverPreviewController.active === this) {
      HoverPreviewController.active = undefined;
    }
  }

  /** 清掉全局激活卡（页面路由前统一清场，无论激活的是哪张卡） */
  static stopActive(): void {
    if (HoverPreviewController.active !== undefined) {
      HoverPreviewController.active.stop();
    }
  }

  /** 当前轮播地址（空串 = 静态封面），封面 NetworkImage url 取值入口 */
  displayUrl(cover: string): string {
    return this.state.frameUrl.length > 0 ? this.state.frameUrl : cover;
  }

  private beginCycle(): void {
    if (this.frames.length === 0) {
      return;
    }
    let index: number = 0;
    this.state.frameIndex = index;
    this.state.frameUrl = this.frames[index];
    if (this.frameTimer >= 0) {
      clearInterval(this.frameTimer);
    }
    this.frameTimer = setInterval((): void => {
      index = (index + 1) % this.frames.length;
      this.state.frameIndex = index;
      this.state.frameUrl = this.frames[index];
    }, HoverPreviewController.FRAME_INTERVAL_MS);
  }
}

@ComponentV2
export struct VideoCardView {
  @Param video: Video = new Video();
  /** 卡片宽度来源：栅格列宽，组件自身撑满 */
  @Param showDanmakuCount: boolean = true;
  /** 左上角徽标文案（空 = 不显示；排行榜名次/尘封天数） */
  @Param badgeText: string = '';
  /** 徽标是否高亮（前三名品牌色底，否则半透明黑底） */
  @Param badgeHighlight: boolean = false;
  /** 标题下副文案（空 = 不显示；排行榜神评论/指标行，最多两行） */
  @Param subCaption: string = '';
  /** 是否展示播放数浮层（默认展示；指标由徽标/副文案承载时传 false） */
  @Param showPlayCount: boolean = true;
  /** hero 转场源状态（activeToken 命中本卡实例时隐藏封面/标题，保留占位防列表重排） */
  @Local heroSource: HeroSourceState = HeroSource.getState();
  /** 本卡实例 token（构造时一次性取号；同屏同 hid 多卡时区分 rect 采集与隐藏目标） */
  private heroToken: string = HeroTransition.nextSourceToken();
  /** 悬停帧轮播控制器（鼠标/手写笔 onHover 驱动；previewFrames 为空时休眠） */
  private hoverPreview: HoverPreviewController = new HoverPreviewController();
  /** 长按触发轮播后抑制随后的 onClick（长按成功后释放仍会派发点击）；下次按下复位 */
  private suppressClickAfterLongPress: boolean = false;

  /** hero 封面节点 id（hid + 实例 token，全树唯一） */
  private coverNodeId(): string {
    return `cover-${this.video.hid}-${this.heroToken}`;
  }

  /** hero 标题节点 id（hid + 实例 token，全树唯一） */
  private titleNodeId(): string {
    return `title-${this.video.hid}-${this.heroToken}`;
  }

  aboutToDisappear(): void {
    this.hoverPreview.stop();
  }

  /** 虚拟滚动节点换绑视频时终止旧轮播，防止帧地址串卡 */
  @Monitor('video')
  onVideoRebind(): void {
    this.hoverPreview.stop();
  }

  build() {
    Column({ space: $r('app.float.space_sm') }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        NetworkImage({
          url: this.hoverPreview.displayUrl(this.video.thumb),
          imageWidth: '100%',
          imageHeight: '100%',
          fit: ImageFit.Cover
        })
          .aspectRatio(1.6)
        // 左上角徽标（position 相对封面 Stack 左上角，不受 BottomStart 对齐影响）
        if (this.badgeText.length > 0) {
          Text(this.badgeText)
            .fontSize($r('app.float.font_size_caption'))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.badgeHighlight ? $r('app.color.text_on_brand') : Color.White)
            .backgroundColor(this.badgeHighlight ? $r('app.color.brand') : 'rgba(0,0,0,0.55)')
            .borderRadius($r('app.float.radius_button'))
            .padding({
              left: $r('app.float.space_sm'),
              right: $r('app.float.space_sm'),
              top: 2,
              bottom: 2
            })
            .maxLines(1)
            .position({ x: $r('app.float.space_sm'), y: $r('app.float.space_sm') })
        }
        if (this.showPlayCount) {
          Row({ space: $r('app.float.space_xs') }) {
            Text(`▶ ${PlayCountText.format(this.video.play)}`)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor(Color.White)
            if (this.showDanmakuCount && this.video.mukio > 0) {
              Text(`· ${PlayCountText.format(this.video.mukio)}`)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor('rgba(255,255,255,0.85)')
            }
          }
          .backgroundColor('rgba(0,0,0,0.45)')
          .borderRadius($r('app.float.radius_button'))
          .padding({
            left: $r('app.float.space_sm'),
            right: $r('app.float.space_sm'),
            top: 2,
            bottom: 2
          })
          .margin($r('app.float.space_xs'))
        }
        // 悬停轮播帧进度指示（底部右侧细进度条，静态封面态不渲染）
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
        }
      }
      .width('100%')
      .borderRadius($r('app.float.radius_card'))
      .clip(true)
      .id(this.coverNodeId())
      .visibility(this.heroSource.activeToken === this.heroToken
        ? Visibility.Hidden : Visibility.Visible)

      Text(this.video.title)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .height(42)
        .id(this.titleNodeId())
        .visibility(this.heroSource.activeToken === this.heroToken
          ? Visibility.Hidden : Visibility.Visible)

      // 标题下副文案（排行榜神评论/指标行；转场期间随封面/标题一同隐藏）
      if (this.subCaption.length > 0) {
        Text(this.subCaption)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .visibility(this.heroSource.activeToken === this.heroToken
            ? Visibility.Hidden : Visibility.Visible)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
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
    .hoverEffect(HoverEffect.Scale)
    .focusable(true)
  }

  /** 点击进详情：双 rect 采集成功 → hero 连续缩放转场；任一失败 → 普通跳转 */
  private openDetail(): void {
    // 路由前清场：终止本卡（或全局任意卡）悬停轮播，恢复静态封面
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
    heroParam.cornerRadius = CARD_CORNER_RADIUS;
    heroParam.coverId = this.coverNodeId();
    heroParam.titleId = this.titleNodeId();
    heroParam.sourceToken = this.heroToken;
    this.heroSource.markSource(this.heroToken);
    Router.goVideoDetailWithTransition(this.video.hid, heroParam);
  }
}

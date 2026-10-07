/**
 * 双指自由变换共享状态（在线 Player / 离线 OfflinePlayer 两页共用）
 * - 捏合缩放 [1.0, 3.0] + 双指拖移平移，松手保持当前变换（无回弹）
 * - 变换原点 = 视频区中心；锚点数学保持手指中点处画面不动
 * - 位移钳制 |offset| ≤ (scale-1)/2 × 区域边长：任何缩放下画面恒铺满视频区（无缝黑边）
 * - 缩放指示器：手势进行中常显，松手停留 800ms 后隐藏
 * 页面接线约定：
 *   - 画面 + 弹幕包一层内层 Stack，.scale({x,y}).translate({x,y}) 驱动；手势/控件/指示器在包裹层外
 *   - 手势组内 PinchGesture / PanGesture(fingers:2) 推进本状态
 *   - 现有单指处理器入口以 gestureActive 短路（双指进行中单指冻结）
 *   - 切集 / 进出全屏 / 设置面板"画面复位"调 reset()
 */
@ObservedV2
export class VideoZoomState {
  /** 缩放倍率（钳制 [1.0, 3.0]） */
  @Trace scale: number = 1.0;
  /** 水平位移 vp（视频区中心基准） */
  @Trace offsetXVp: number = 0;
  /** 垂直位移 vp（视频区中心基准） */
  @Trace offsetYVp: number = 0;
  /** 双指手势进行中（页面单指手势处理器据此短路冻结） */
  @Trace gestureActive: boolean = false;
  /** 缩放指示器可见 */
  @Trace indicatorVisible: boolean = false;
  /** 缩放指示器文案（1 位小数 + x，如 "1.5x"） */
  @Trace indicatorText: string = '1.0x';

  /** 本次捏合起点倍率（onPinchStart 快照，update 以 baseScale×factor 推进） */
  private baseScale: number = 1.0;
  /** 指示器 800ms 隐藏计时器 */
  private indicatorTimer: number = -1;

  /** 捏合开始：快照当前倍率为基准，标记双指手势进行中 */
  onPinchStart(): void {
    this.gestureActive = true;
    this.baseScale = this.scale;
    this.showIndicator();
  }

  /**
   * 捏合更新：factor 为本次手势累计倍率（起点 1.0）；
   * anchor = 手指中点（vp，视频区左上角原点），保持中点处画面不动
   */
  onPinchUpdate(factor: number, anchorXVp: number, anchorYVp: number, areaWVp: number, areaHVp: number): void {
    const newScale: number = Math.min(3.0, Math.max(1.0, this.baseScale * factor));
    // 锚点数学（变换原点 = 视频区中心）：offset += (anchor - center) × (scale - newScale)
    const centerXVp: number = areaWVp / 2;
    const centerYVp: number = areaHVp / 2;
    const rawXVp: number = this.offsetXVp + (anchorXVp - centerXVp) * (this.scale - newScale);
    const rawYVp: number = this.offsetYVp + (anchorYVp - centerYVp) * (this.scale - newScale);
    this.scale = newScale;
    this.clampOffset(rawXVp, rawYVp, areaWVp, areaHVp);
    this.updateIndicatorText();
  }

  /** 双指拖移开始：标记双指手势进行中（事件增量基准由页面记录） */
  onTwoPanStart(): void {
    this.gestureActive = true;
    this.showIndicator();
  }

  /** 双指拖移更新：dXVp/dYVp 为本次事件增量（vp），累加后钳制 */
  onTwoPanUpdate(dXVp: number, dYVp: number, areaWVp: number, areaHVp: number): void {
    this.clampOffset(this.offsetXVp + dXVp, this.offsetYVp + dYVp, areaWVp, areaHVp);
  }

  /** 双指手势结束：松手不回弹，指示器停留 800ms 后隐藏 */
  onGestureEnd(): void {
    this.gestureActive = false;
    this.cancelIndicatorTimer();
    this.indicatorTimer = setTimeout((): void => {
      this.indicatorTimer = -1;
      this.indicatorVisible = false;
    }, 800);
  }

  /** 复位：回 1x + 居中（切集 / 进出全屏 / 设置面板"画面复位"触发） */
  reset(): void {
    this.scale = 1.0;
    this.baseScale = 1.0;
    this.offsetXVp = 0;
    this.offsetYVp = 0;
    this.cancelIndicatorTimer();
    this.indicatorVisible = false;
    this.updateIndicatorText();
  }

  /** 位移钳制：|offset| ≤ (scale-1)/2 × 区域边长（缩放画面恒覆盖整个视频区） */
  private clampOffset(rawXVp: number, rawYVp: number, areaWVp: number, areaHVp: number): void {
    const maxXVp: number = (this.scale - 1.0) / 2 * areaWVp;
    const maxYVp: number = (this.scale - 1.0) / 2 * areaHVp;
    this.offsetXVp = Math.min(maxXVp, Math.max(-maxXVp, rawXVp));
    this.offsetYVp = Math.min(maxYVp, Math.max(-maxYVp, rawYVp));
  }

  /** 手势进行中：指示器常显（清未决隐藏计时）并同步文案 */
  private showIndicator(): void {
    this.cancelIndicatorTimer();
    this.indicatorVisible = true;
    this.updateIndicatorText();
  }

  /** 指示器文案：1 位小数 + x */
  private updateIndicatorText(): void {
    this.indicatorText = `${this.scale.toFixed(1)}x`;
  }

  private cancelIndicatorTimer(): void {
    if (this.indicatorTimer >= 0) {
      clearTimeout(this.indicatorTimer);
      this.indicatorTimer = -1;
    }
  }
}

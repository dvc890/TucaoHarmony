/**
 * 视频进度滑杆
 * - 自绘轨道（4vp 细条，拖动时 6vp + 圆形滑块），替代系统 Slider 的粗样式
 * - 拖动期间仅本地预览，松手一次性 onSeek（避免拖动中连续 seek 卡顿）
 * - 拖动起点取组件实时宽度（onAreaChange），适配全屏/半屏两种宽度
 */
@ComponentV2
export struct MediaSlider {
  /** 当前时位 ms */
  @Param value: number = 0;
  /** 总时长 ms */
  @Param maxValue: number = 0;
  /** 松手 seek 回调 */
  @Param onSeek: (ms: number) => void = (_ms: number): void => {
  };
  /** 交互通知（父级用于重置控制层自动隐藏计时器） */
  @Param onInteraction: () => void = (): void => {
  };

  /** 拖动中 */
  @Local dragging: boolean = false;
  /** 拖动预览值 ms */
  @Local dragValue: number = 0;
  /** 轨道宽度 vp */
  @Local trackWidth: number = 0;
  /** 手势起始值 */
  private startValue: number = 0;

  private effectiveValue(): number {
    return this.dragging ? this.dragValue : this.value;
  }

  private progressPercent(): number {
    if (this.maxValue <= 0) {
      return 0;
    }
    const percent: number = this.effectiveValue() / this.maxValue;
    return Math.min(1, Math.max(0, percent));
  }

  private clampValue(ms: number): number {
    if (this.maxValue <= 0) {
      return 0;
    }
    return Math.min(this.maxValue, Math.max(0, ms));
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      // 底轨（y 偏移实现 24vp 命中区内垂直居中；Stack 无 justifyContent/alignItems 属性）
      Column()
        .width('100%')
        .height(this.dragging ? 6 : 4)
        .borderRadius(3)
        .backgroundColor('rgba(255,255,255,0.30)')
        .offset({ y: this.dragging ? 9 : 10 })
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const widthVp: number = newArea.width as number;
          if (typeof widthVp === 'number' && widthVp > 0) {
            this.trackWidth = widthVp;
          }
        })
      // 已播进度
      Column()
        .width(`${(this.progressPercent() * 100).toFixed(2)}%`)
        .height(this.dragging ? 6 : 4)
        .borderRadius(3)
        .backgroundColor($r('app.color.brand'))
        .offset({ y: this.dragging ? 9 : 10 })
      // 滑块（拖动时可见）
      if (this.dragging) {
        Circle()
          .width(14)
          .height(14)
          .fill(Color.White)
          .offset({
            x: Math.max(0, this.progressPercent() * this.trackWidth - 7),
            y: 5
          })
      }
    }
    .width('100%')
    .height(24)
    // 拖动手势：PanGesture.offsetX 即相对按下位置的 vp 位移，直接换算进度增量
    .gesture(
      PanGesture({ fingers: 1, distance: 0 })
        .onActionStart((event: GestureEvent): void => {
          if (this.maxValue <= 0 || this.trackWidth <= 0) {
            return;
          }
          this.dragging = true;
          this.startValue = this.value;
          this.dragValue = this.value;
          this.onInteraction();
        })
        .onActionUpdate((event: GestureEvent): void => {
          if (!this.dragging) {
            return;
          }
          const deltaMs: number = event.offsetX / this.trackWidth * this.maxValue;
          this.dragValue = this.clampValue(this.startValue + deltaMs);
          this.onInteraction();
        })
        .onActionEnd((): void => {
          if (!this.dragging) {
            return;
          }
          this.dragging = false;
          const target: number = this.dragValue;
          this.dragValue = 0;
          this.onSeek(target);
        })
        .onActionCancel((): void => {
          this.dragging = false;
          this.dragValue = 0;
        })
    )
  }
}

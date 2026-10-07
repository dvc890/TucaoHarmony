/**
 * 错误重试视图：错误文案 + 重新加载按钮
 */
@ComponentV2
export struct ErrorRetry {
  @Param message: string = '加载失败，请检查网络后重试';
  /** 重试回调 */
  @Param onRetry: () => void = (): void => {};

  build() {
    Column({ space: $r('app.float.space_lg') }) {
      Text(this.message)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
      Button('重新加载')
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_on_brand'))
        .backgroundColor($r('app.color.brand'))
        .borderRadius($r('app.float.radius_button'))
        .padding({
          left: $r('app.float.space_xl'),
          right: $r('app.float.space_xl'),
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })
        .onClick(() => {
          this.onRetry();
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 160 })
    .justifyContent(FlexAlign.Center)
    .padding($r('app.float.space_lg'))
  }
}

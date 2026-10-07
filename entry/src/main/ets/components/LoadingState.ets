/**
 * 加载中状态视图：居中 LoadingProgress + 文案
 */
@ComponentV2
export struct LoadingState {
  @Param message: string = '加载中…';

  build() {
    Column({ space: $r('app.float.space_md') }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color($r('app.color.brand'))
      Text(this.message)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .constraintSize({ minHeight: 160 })
    .justifyContent(FlexAlign.Center)
    .padding($r('app.float.space_lg'))
  }
}

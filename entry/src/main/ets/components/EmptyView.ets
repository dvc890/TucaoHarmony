/**
 * 空态视图：居中提示文案
 */
@ComponentV2
export struct EmptyView {
  @Param message: string = '暂无内容';

  build() {
    Column({ space: $r('app.float.space_md') }) {
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

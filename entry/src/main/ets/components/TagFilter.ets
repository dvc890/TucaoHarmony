/**
 * 横向滚动标签筛选行（排序/类型切换等场景）
 * - 选中态由父层持有（selectedIndex），本组件为纯展示 + 回调
 */
@ComponentV2
export struct TagFilter {
  /** 标签文案列表 */
  @Param labels: string[] = [];
  /** 当前选中下标 */
  @Param selectedIndex: number = 0;
  /** 选中回调 */
  @Param onSelect: (index: number) => void = (index: number) => {};

  build() {
    Scroll() {
      Row({ space: $r('app.float.space_sm') }) {
        ForEach(this.labels, (label: string, index: number) => {
          Text(label)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(index === this.selectedIndex
              ? $r('app.color.text_on_brand')
              : $r('app.color.text_secondary'))
            .backgroundColor(index === this.selectedIndex
              ? $r('app.color.brand')
              : $r('app.color.float_background'))
            .borderRadius($r('app.float.radius_button'))
            .padding({
              left: $r('app.float.space_md'),
              right: $r('app.float.space_md'),
              top: $r('app.float.space_xs'),
              bottom: $r('app.float.space_xs')
            })
            .onClick(() => {
              this.onSelect(index);
            })
        }, (label: string) => label)
      }
      .padding({
        left: $r('app.float.space_lg'),
        right: $r('app.float.space_lg'),
        top: $r('app.float.space_sm'),
        bottom: $r('app.float.space_sm')
      })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.Start)
  }
}

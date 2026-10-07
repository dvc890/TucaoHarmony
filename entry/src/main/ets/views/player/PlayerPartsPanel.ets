/**
 * 全屏选集面板（右侧滑入，对齐安卓 parts_layout 3列网格）
 * - 右侧滑入面板，点击外部关闭
 * - 3列网格展示分集，高亮当前集
 * - 点击切换分集
 */
import { VideoDetailVM } from '../../viewmodel/VideoDetailVM';
import { Part } from '../../model/entity/BaseEntities';

@ComponentV2
export struct PlayerPartsPanel {
  @Param vm: VideoDetailVM = VideoDetailVM.shared();
  @Param visible: boolean = false;
  @Param onDismiss: () => void = (): void => {};

  /** 获取分集列表 */
  private partsOf(): Part[] {
    const video = this.vm.video;
    return video !== null ? video.parts : [];
  }

  /** 分集按钮文字颜色 */
  private partColor(part: Part, index: number): ResourceColor {
    if (index === this.vm.partIndex) {
      return $r('app.color.brand');
    }
    return 'rgba(255,255,255,0.85)';
  }

  /** 分集按钮背景 */
  private partBg(part: Part, index: number): Resource | string {
    if (index === this.vm.partIndex) {
      return 'rgba(255,255,255,0.12)';
    }
    return 'rgba(255,255,255,0.06)';
  }

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.End }) {
        // 点击外部区域关闭
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.01)')
          .onClick((): void => {
            this.onDismiss();
          })

        // 右侧选集面板
        Column() {
          // 标题栏
          Row() {
            Text('选集')
              .fontSize($r('app.float.font_size_title'))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bold)
            Blank()
            Text('✕')
              .fontSize(18)
              .fontColor(Color.White)
              .padding($r('app.float.space_sm'))
              .onClick((): void => {
                this.onDismiss();
              })
          }
          .width('100%')
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            top: $r('app.float.space_md'),
            bottom: $r('app.float.space_sm')
          })

          // 3列网格选集
          Scroll() {
            Grid() {
              ForEach(this.partsOf(), (part: Part, index: number) => {
                GridItem() {
                  Column() {
                    Text(this.partTitle(part, index))
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor(this.partColor(part, index))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .textAlign(TextAlign.Center)
                      .width('100%')
                  }
                  .width('100%')
                  .aspectRatio(1.8)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(this.partBg(part, index))
                  .borderRadius($r('app.float.radius_card'))
                  .onClick((): void => {
                    this.onDismiss();
                    this.vm.switchPart(index);
                  })
                }
              }, (part: Part, index: number): string => `${part.vid}#${index}`)
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap($r('app.float.space_sm'))
            .rowsGap($r('app.float.space_sm'))
            .width('100%')
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Auto)
          // 内容不足视口时贴顶（Scroll 默认居中导致排版下沉）
          .align(Alignment.Top)
        }
        .width(420)
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.85)')
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => {
          // 阻止点击冒泡到外层关闭
        })
      }
      .width('100%')
      .height('100%')
    }
  }

  private partTitle(part: Part, index: number): string {
    if (part.title.length > 0) {
      return part.title;
    }
    return `第${index + 1}集`;
  }
}

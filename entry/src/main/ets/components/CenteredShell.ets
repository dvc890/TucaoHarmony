/**
 * 限宽居中壳（大屏表单/内容页收敛）
 * - 外层全宽 Column（默认居中对齐）+ 内层限宽内容列：
 *   LG/XL 按 maxWidth 约束并水平居中，SM/MD 全宽（零退化）
 * - fillHeight=true：壳占满父容器剩余高度（列表/消息页，父容器须为有界 Column）；
 *   false：壳随内容自适应（Scroll 内表单页）
 * - 用法：CenteredShell({ maxWidth: 600 }) { ... } 或显式
 *   CenteredShell({ maxWidth: 600, content: (): void => { this.formBody() } })
 */
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { ContentWidth } from '../common/BreakpointLayout';

@ComponentV2
export struct CenteredShell {
  /** 大屏内容最大宽度 vp（仅 LG/XL 生效） */
  @Param maxWidth: number = 600;
  /** 是否撑满父容器剩余高度（列表页 true；Scroll 内表单页 false） */
  @Param fillHeight: boolean = false;
  /** 壳内容 */
  @BuilderParam content: () => void;
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  build() {
    if (this.fillHeight) {
      Column() {
        Column() {
          this.content()
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: ContentWidth.cap(this.maxWidth, this.windowSize.isExpanded()) })
      }
      .width('100%')
      .layoutWeight(1)
    } else {
      Column() {
        Column() {
          this.content()
        }
        .width('100%')
        .constraintSize({ maxWidth: ContentWidth.cap(this.maxWidth, this.windowSize.isExpanded()) })
      }
      .width('100%')
    }
  }
}

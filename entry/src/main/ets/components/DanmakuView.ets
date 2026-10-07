/**
 * 弹幕层组件：@ohos/danmakuflamemaster DanmakuViewV2 的薄封装
 *
 * - 尺寸：onAreaChange → vp→px → model.setWidth/setHeight（引擎内部以像素驱动画布后端，
 *   父组件 onAreaChange 先于子 Canvas onReady，首帧尺寸即正确）
 * - 生命周期：aboutToAppear → vm.attach（多页共存登记）；aboutToDisappear → vm.detach
 * - 命中：HitTestMode.Transparent，触摸穿透至底层播放器手势层
 * - limitScrollLines：半屏（详情页）限制滚动弹幕行数（对齐安卓非全屏 setMaximumLines 5 行），
 *   全屏播放页传 0 不限制
 *
 * 挂载示例（接线）：
 *   详情页 VideoDetail.ets 播放器 Stack 的 `//  扩展点`：
 *     DanmakuView({ limitScrollLines: 5 })
 *   全屏播放页 Player.ets 弹幕层挂载位：
 *     DanmakuView()
 */
import { DanmakuViewV2 } from '@ohos/danmakuflamemaster';
import { DanmakuVM } from '../viewmodel/DanmakuVM';

@ComponentV2
export struct DanmakuView {
  @Param vm: DanmakuVM = DanmakuVM.shared();
  /** 半屏滚动弹幕行数上限；0 = 不限制 */
  @Param limitScrollLines: number = 0;
  private model: DanmakuViewV2.Model = new DanmakuViewV2.Model();

  aboutToAppear(): void {
    this.vm.attach(this.model, this.limitScrollLines);
  }

  aboutToDisappear(): void {
    this.vm.detach(this.model);
  }

  build() {
    Stack() {
      DanmakuViewV2({ model: this.model })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const widthVp: number = Number(newArea.width);
      const heightVp: number = Number(newArea.height);
      if (widthVp <= 0 || heightVp <= 0) {
        return;
      }
      const widthPx: number = this.getUIContext().vp2px(widthVp);
      const heightPx: number = this.getUIContext().vp2px(heightVp);
      this.model.setWidth(widthPx);
      this.model.setHeight(heightPx);
    })
  }
}

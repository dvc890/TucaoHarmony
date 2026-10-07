/**
 * 网络图片组件（封装 @ohos/imageknifepro ImageKnifeComponentV2）
 * - 统一占位底色（skeleton）与圆角，自动缓存
 * - url 变化经 @Monitor 重建 Option 触发重载
 */
import { ImageKnifeComponentV2, ImageKnifeOptionV2 } from '@ohos/imageknifepro';

@ComponentV2
export struct NetworkImage {
  /** 图片地址 */
  @Param url: string = '';
  /** 宽（默认撑满） */
  @Param imageWidth: Length = '100%';
  /** 高（默认撑满） */
  @Param imageHeight: Length = '100%';
  /** 圆角 vp */
  @Param radius: number = 0;
  /** 填充模式 */
  @Param fit: ImageFit = ImageFit.Cover;
  @Local option: ImageKnifeOptionV2 = new ImageKnifeOptionV2();

  aboutToAppear(): void {
    this.rebuildOption();
  }

  @Monitor('url', 'fit')
  onOptionSourceChange(): void {
    this.rebuildOption();
  }

  private rebuildOption(): void {
    const option: ImageKnifeOptionV2 = new ImageKnifeOptionV2();
    option.loadSrc = this.url;
    option.objectFit = this.fit;
    this.option = option;
  }

  build() {
    Column() {
      ImageKnifeComponentV2({
        imageKnifeOption: this.option
      })
        .width('100%')
        .height('100%')
    }
    .width(this.imageWidth)
    .height(this.imageHeight)
    .borderRadius(this.radius)
    .clip(true)
    .backgroundColor($r('app.color.skeleton'))
  }
}

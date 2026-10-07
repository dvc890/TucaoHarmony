/**
 * 关于页
 * - 应用名/图标/版本号（bundleManager 动态读取 versionName+versionCode）
 * - 产品定位一句话 + 作者与开源（dvc890 / GitHub / MIT）
 * - LG/XL 内容限宽 600 居中（SM/MD 全宽，零退化）
 * - 路由：router_map.json → AboutBuilder（无参数；Router.goAbout()）
 */
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function AboutBuilder(name: string, param: Object) {
  About()
}

@ComponentV2
struct About {
  /** 版本名（读取失败回退「1.0.0」） */
  @Local versionName: string = '1.0.0';
  /** 版本号 */
  @Local versionCode: number = 1;

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        this.versionName = info.versionName;
      }
      this.versionCode = info.versionCode;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(0x0000, 'About', 'getBundleInfoForSelfSync failed: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        // LG/XL 内容限宽 600 居中（SM/MD 全宽，零退化）
        CenteredShell({ maxWidth: 600 }) {
          Column({ space: $r('app.float.space_md') }) {
            // 应用标识
            Column({ space: $r('app.float.space_sm') }) {
              Image($r('app.media.logo'))
                .width(160)
                .objectFit(ImageFit.Contain)
              Text(`HarmonyOS 版 · v${this.versionName}(${this.versionCode})`)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ top: $r('app.float.space_xl') })
            .justifyContent(FlexAlign.Center)

            // 产品定位
            Column({ space: $r('app.float.space_xs') }) {
              Text('产品简介')
                .fontSize($r('app.float.font_size_body'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('吐槽（tucao.my）第三方 HarmonyOS 客户端：视频播放、弹幕、评论、收藏历史、离线缓存与投屏。')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(20)
            }
            .width('100%')
            .padding($r('app.float.space_md'))
            .borderRadius($r('app.float.radius_card'))
            .backgroundColor($r('app.color.card_background'))
            .alignItems(HorizontalAlign.Start)

            // 开源致谢
            Column({ space: $r('app.float.space_xs') }) {
              Text('开源致谢')
                .fontSize($r('app.float.font_size_body'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('ImageKnife（图片加载缓存）\nDanmakuFlameMaster（弹幕引擎设计参考）\nRxDownload（断点续传设计参考）')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(20)
              Text('内容与接口均来自 tucao.my，本客户端不存储任何视频内容；仅供学习交流使用。')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: $r('app.float.space_sm') })
            }
            .width('100%')
            .padding($r('app.float.space_md'))
            .borderRadius($r('app.float.radius_card'))
            .backgroundColor($r('app.color.card_background'))
            .alignItems(HorizontalAlign.Start)

            // 作者与开源
            Column({ space: $r('app.float.space_xs') }) {
              Text('作者与开源')
                .fontSize($r('app.float.font_size_body'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('本应用由 dvc890 独立开发，基于 MIT 协议开源，欢迎 Star 与反馈')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(20)
              Text('开源地址：github.com/dvc890/TucaoHarmony')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.brand'))
                .lineHeight(20)
                .onClick((): void => {
                  const context: common.UIAbilityContext =
                    this.getUIContext().getHostContext() as common.UIAbilityContext;
                  context.openLink('https://github.com/dvc890/TucaoHarmony', { appLinkingOnly: false })
                    .catch((error: BusinessError) => {
                      hilog.warn(0x0000, 'About', 'openLink failed: %{public}s', JSON.stringify(error));
                    });
                })
              Text('© 2026 dvc890')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: $r('app.float.space_sm') })
            }
            .width('100%')
            .padding($r('app.float.space_md'))
            .borderRadius($r('app.float.radius_card'))
            .backgroundColor($r('app.color.card_background'))
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({
            left: $r('app.float.space_lg'),
            right: $r('app.float.space_lg'),
            bottom: $r('app.float.space_lg')
          })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title('关于')
    .backgroundColor($r('app.color.page_background'))
  }
}

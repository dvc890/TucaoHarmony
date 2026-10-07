/**
 * 开屏页（对标安卓 SplashActivity）
 * - 入页即预热会话 cookie（GET USER_INFO，对齐安卓 "Just to fetch cookie"，失败静默）
 * - 固定 1.5s 停留 → replaceUrl 至 pages/Index（经典路由，重建主骨架）
 * - 页面过渡：淡入淡出（对齐安卓 overridePendingTransition(fade_in, fade_out)）
 * - 防重复跳转：计时器单飞，aboutToDisappear 清理
 */
import { SessionService } from '../service/session/SessionService';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';

const SPLASH_DURATION_MS: number = 1500;

@Entry
@ComponentV2
struct Splash {
  windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();
  /** 跳转计时器句柄（-1 = 未开启） */
  private delayTimer: number = -1;

  aboutToAppear(): void {
    // 预热会话 cookie（对齐安卓 SplashActivity；失败静默）
    SessionService.shared().prefetchCookie();
    this.delayTimer = setTimeout((): void => {
      this.enterHome();
    }, SPLASH_DURATION_MS);
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  private stopTimer(): void {
    if (this.delayTimer >= 0) {
      clearTimeout(this.delayTimer);
      this.delayTimer = -1;
    }
  }

  /** 进入主骨架（replaceUrl 保证返回键不回开屏页） */
  private enterHome(): void {
    this.stopTimer();
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' })
      .catch((err: Error) => {
        this.getUIContext().getPromptAction().showToast({ message: '加载失败，请重启应用' });
      });
  }

  build() {
    Column({ space: $r('app.float.space_md') }) {
      Column() {
        Image($r('app.media.logo'))
          .width(220)
          .objectFit(ImageFit.Contain)
        Text('和网友一起，追番看片不寂寞')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: $r('app.float.space_xs') })
      }
      .justifyContent(FlexAlign.Center)

      LoadingProgress()
        .width(24)
        .height(24)
        .color($r('app.color.brand'))
        .margin({ top: $r('app.float.space_lg') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.page_background'))
    .onClick((): void => {
      this.enterHome();
    })
  }
}
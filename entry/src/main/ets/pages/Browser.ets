/**
 * 内嵌浏览器页
 * - ArkWeb Web 组件：JS 开启、DOM storage 开启、file/geolocation 关闭
 * - 主框架加载失败（onErrorReceive）→ 全屏错误页遮罩，重试 controller.refresh()
 * - 标题取网页 onTitleReceive，回退键优先消费网页历史（accessBackward/backward）
 * - 路由：router_map.json → BrowserBuilder（param = url 字符串）
 */
import { webview } from '@kit.ArkWeb';
import { Router } from '../common/Router';
import { BrowserVM } from '../viewmodel/BrowserVM';
import { ErrorRetry } from '../components/ErrorRetry';
import { EmptyView } from '../components/EmptyView';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function BrowserBuilder(name: string, param: Object) {
  Browser({ routeParam: param })
}

@ComponentV2
struct Browser {
  /** 路由参数（url 字符串，aboutToAppear 收窄） */
  @Param routeParam: Object = new Object();

  /** 页面级实例：随页面创建/销毁 */
  @Local vm: BrowserVM = new BrowserVM();

  aboutToAppear(): void {
    if (typeof this.routeParam === 'string') {
      this.vm.setup(this.routeParam);
    }
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（中性底） =====
        Row({ space: $r('app.float.space_sm') }) {
          Text('‹')
            .fontSize(28)
            .fontColor($r('app.color.text_primary'))
            .padding({
              left: $r('app.float.space_sm'),
              right: $r('app.float.space_sm')
            })
            .onClick((): void => {
              Router.back();
            })
          Text(this.vm.title.length > 0 ? this.vm.title : '浏览器')
            .fontSize($r('app.float.font_size_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_md'),
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })
        // 全局沉浸：topbar 底色仅扩展绘制延伸到状态栏下（不改布局，内容绝对位置不变）
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

        // ===== 内容区 =====
        if (this.vm.url.length === 0) {
          EmptyView({ message: '链接无效' })
        } else {
          Stack() {
            Web({ src: this.vm.url, controller: this.vm.controller })
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .fileAccess(false)
              .geolocationAccess(false)
              .onTitleReceive((event) => {
                if (event) {
                  this.vm.onPageTitle(event.title);
                }
              })
              .onErrorReceive((event) => {
                if (event && event.request.isMainFrame()) {
                  this.vm.onWebError(event.error.getErrorInfo());
                }
              })

            // 主框架错误遮罩
            if (this.vm.error.length > 0) {
              ErrorRetry({
                message: this.vm.error,
                onRetry: (): void => {
                  this.vm.retry();
                }
              })
            }
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      // 网页历史可后退时优先消费返回键
      if (this.vm.canGoBack()) {
        this.vm.goBack();
        return true;
      }
      return false;
    })
  }
}

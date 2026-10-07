/**
 * 内嵌浏览器视图模型
 * - 页面级实例（随页面创建/销毁，对齐 Star 页范式，不用单例）
 * - 持有 ArkWeb 控制器：错误页重试 refresh()、返回键优先消费网页历史
 * - 对齐安卓 BrowserActivity：JS 开启、DOM storage 开启、标题取 onReceivedTitle
 */
import { webview } from '@kit.ArkWeb';

@ObservedV2
export class BrowserVM {
  /** 目标地址（空串时不渲染 Web 组件） */
  @Trace url: string = '';
  /** 网页标题（onTitleReceive 回填，空时标题栏显示默认文案） */
  @Trace title: string = '';
  /** 主框架加载错误描述（非空时叠加错误页，重试后清空） */
  @Trace error: string = '';

  readonly controller: webview.WebviewController = new webview.WebviewController();

  /** 设置目标地址（aboutToAppear 时调用） */
  setup(url: string): void {
    if (this.url !== url) {
      this.url = url;
      this.title = '';
      this.error = '';
    }
  }

  /** 网页标题回调 */
  onPageTitle(title: string): void {
    if (title.length > 0) {
      this.title = title;
    }
  }

  /** 主框架加载失败回调 */
  onWebError(description: string): void {
    this.error = description.length > 0 ? description : '页面加载失败';
  }

  /** 错误页重试：清错并刷新当前页 */
  retry(): void {
    this.error = '';
    this.controller.refresh();
  }

  /** 网页历史可后退？返回键消费用 */
  canGoBack(): boolean {
    if (this.url.length === 0) {
      return false;
    }
    try {
      return this.controller.accessBackward();
    } catch (err) {
      return false;
    }
  }

  /** 网页历史后退 */
  goBack(): void {
    try {
      this.controller.backward();
    } catch (err) {
      // 控制器未附着时忽略
    }
  }
}

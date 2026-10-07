/*
 * 自由窗口模式助手（R6：自由窗 maximize(ENTER_IMMERSIVE) + 退出 recover()）
 * - 自由窗（FLOATING）形态下，沉浸视频体验（详情页进全屏 / 离线播放器进场）应把
 *   窗口 maximize 成全屏沉浸（MaximizePresentation.ENTER_IMMERSIVE：铺满屏幕、
 *   无标题栏/dock/状态栏），退出时 recover() 还原进入前的悬浮尺寸与位置
 * - 仅 FLOATING 状态才请求 maximize：非自由窗设备（手机/平板全屏运行）与
 *   已最大化的窗口一律 no-op（maximize 在非自由窗设备返回 801）
 * - 仅归还"应用自己请求"的最大化（appRequested 标记）：用户经系统标题栏手动
 *   最大化的窗口不受播放页退出影响；windowStatusChange 监听同步外部还原
 *   （用户点系统还原钮 → FLOATING → 清标记，避免二次 recover）
 * - 状态由 EntryAbility initWindow 注入主窗口后激活；未初始化时全部 no-op
 */
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'WindowModeHelper';

export class WindowModeHelper {
  private static win: window.Window | undefined = undefined;
  /** 应用请求的最大化未归还标记（仅 releaseImmersive 消费） */
  private static appRequested: boolean = false;

  /** EntryAbility.initWindow 注入主窗口并注册状态监听（loadContent 之后调用） */
  static init(mainWindow: window.Window): void {
    WindowModeHelper.win = mainWindow;
    try {
      mainWindow.on('windowStatusChange', (status: window.WindowStatusType): void => {
        // 外部还原（系统还原钮/手势）：清应用标记，防止退出播放页时误 recover
        if (status === window.WindowStatusType.FLOATING) {
          WindowModeHelper.appRequested = false;
        }
        hilog.info(DOMAIN, TAG, 'windowStatusChange: %{public}d', status as number);
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'on windowStatusChange failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 主窗口注销（onWindowStageDestroy）：置空引用并反注册监听 */
  static shutdown(): void {
    const win: window.Window | undefined = WindowModeHelper.win;
    if (win !== undefined) {
      try {
        win.off('windowStatusChange');
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'off windowStatusChange failed: %{public}s', JSON.stringify(err));
      }
    }
    WindowModeHelper.win = undefined;
    WindowModeHelper.appRequested = false;
  }

  /** 缓存主窗口只读访问（init 注入 / shutdown 置空）：方向仲裁器同步派发
   *  setPreferredOrientation 用（省 getLastWindow IPC 往返，旋转请求前移到
   *  点击瞬间的确定性前提）；未初始化返回 undefined，调用方自行回退 */
  static mainWindow(): window.Window | undefined {
    return WindowModeHelper.win;
  }

  /** 当前是否自由悬浮窗（查询失败按非自由窗处理，调用方全部 no-op） */
  static isFloating(): boolean {
    const win: window.Window | undefined = WindowModeHelper.win;
    if (win === undefined) {
      return false;
    }
    try {
      return win.getWindowStatus() === window.WindowStatusType.FLOATING;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getWindowStatus failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 沉浸入口：FLOATING 时 maximize(ENTER_IMMERSIVE) 进全屏沉浸。
   * 成功后额外等待一拍（窗口几何经 windowSizeChange 稳定），调用方再采集转场矩形。
   */
  static async requestImmersive(): Promise<void> {
    const win: window.Window | undefined = WindowModeHelper.win;
    if (win === undefined || !WindowModeHelper.isFloating()) {
      return;
    }
    WindowModeHelper.appRequested = true;
    try {
      await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
      await new Promise<void>((resolve: (value: void) => void): void => {
        setTimeout((): void => {
          resolve();
        }, 80);
      });
    } catch (err) {
      // 非自由窗设备 801 / 竞态失败：还原标记，沉浸由应用内布局兜底
      WindowModeHelper.appRequested = false;
      hilog.warn(DOMAIN, TAG, 'maximize failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 沉浸出口：仅归还应用自己请求的最大化（recover 已是 FLOATING 时本身 no-op） */
  static releaseImmersive(): void {
    const win: window.Window | undefined = WindowModeHelper.win;
    if (win === undefined || !WindowModeHelper.appRequested) {
      return;
    }
    WindowModeHelper.appRequested = false;
    try {
      win.recover().catch((): void => {
        // 忽略：窗口可能已被外部还原
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'recover failed: %{public}s', JSON.stringify(err));
    }
  }
}

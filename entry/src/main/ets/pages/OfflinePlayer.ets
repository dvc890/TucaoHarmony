/**
 * 离线全屏播放页
 * - 横屏沉浸（LANDSCAPE 方向锁定、退出还原；系统栏由 Index 路由拦截窗口级
 *   setSpecificSystemBarEnabled 隐藏——全屏布局下组件级 enableStatusBar 实测不生效，
 *   页面级属性保留兜底）+ XComponent surface
 *   + 手势区切换控制层（双击播放/竖滑亮度音量/长按 2x/单击控制层）+ 4s 自动隐藏
 * - 双指自由变换：捏合缩放 1~3x + 双指拖移（锚点=手指中点，松手保持不回弹），
 *   VideoZoomState 驱动画面+弹幕包裹层缩放平移；双指进行中单指手势冻结；
 *   切集（partIndex 变化）复位，设置面板提供"画面复位"
 * - 自绘控制栏（返回/标题、播放暂停、±10s、MediaSlider、时间、倍速循环、选集）
 *   + 右侧选集面板（当前高亮/已看标记/未缓存置灰不可点）
 * - 弹幕缺失 pill（未发现弹幕文件，请更新弹幕→更新，透传引擎重拉）+ 断点提示条（跳转）
 *   + 分集切换/缓冲浮层 + 播放错误浮层（重新载入）+ 目录错误全页态（ErrorRetry）
 * -  接线完成：DanmakuView 消费离线时钟（OfflineDanmakuClock 包裹 vm.danmuPathOfCurrent()）；
 *   aboutToAppear 注入 useOfflineClock、aboutToDisappear restoreOnlineClock（防单例残留）；
 *   弹幕更新成功 / 切集由 refreshPool 与 syncTick 换集检测自动重载；离线发送禁用
 * - 路由：router_map.json → OfflinePlayerBuilder（param = hid 或 hid#order，0 基 order）
 * 偏差：无键盘快捷键/无 AVSession（对齐 OfflinePlayerVM 隔离内核的偏差声明）
 */
import { window } from '@kit.ArkUI';
import { VideoDetailVM } from '../viewmodel/VideoDetailVM';
import { OfflinePlayerVM, OfflineSpeedTable } from '../viewmodel/OfflinePlayerVM';
import { DanmakuVM, DanmakuClock } from '../viewmodel/DanmakuVM';
import { PlayerCoreState } from '../service/player/PlayerController';
import { Video, Part, DownloadStatus } from '../model/entity/BaseEntities';
import { DanmakuView } from '../components/DanmakuView';
import { MediaSlider } from '../components/MediaSlider';
import { ErrorRetry } from '../components/ErrorRetry';
import { Router } from '../common/Router';
import { AppContextHolder, GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { WindowModeHelper } from '../common/WindowModeHelper';
import { ScaleTable, ScaleModeOption } from '../common/Constants';
import { VideoZoomState } from '../views/player/VideoZoomState';

/** 离线弹幕时钟：包裹 OfflinePlayerVM（本地 danmu.xml + 离线播放态；时间轴与在线分集本地轴同轴） */
class OfflineDanmakuClock implements DanmakuClock {
  private readonly vm: OfflinePlayerVM;

  constructor(vm: OfflinePlayerVM) {
    this.vm = vm;
  }

  danmakuVideo(): Video | null {
    return this.vm.video;
  }

  danmakuPartIndex(): number {
    return this.vm.partIndex;
  }

  danmakuCurrentMs(): number {
    return this.vm.currentMs;
  }

  danmakuPlaying(): boolean {
    return this.vm.coreState === PlayerCoreState.PLAYING && !this.vm.isBuffering;
  }

  danmakuSpeed(): number {
    return this.vm.speed;
  }

  danmakuLocalPath(): string | null {
    const path: string = this.vm.danmuPathOfCurrent();
    return path.length > 0 ? path : null;
  }
}

/** 路由 builder（router_map.json 注册用） */
@Builder
export function OfflinePlayerBuilder(name: string, param: Object) {
  OfflinePlayer({ routeParam: param })
}

@ComponentV2
struct OfflinePlayer {
  /** 路由参数（hid 或 hid#order，aboutToAppear 解析） */
  @Param routeParam: Object = new Object();
  /** 控制层可见性 */
  @Local showControls: boolean = true;
  /** 屏幕锁定（R8）：锁定后屏蔽点击/控制层/返回键，仅留右上角小锁解锁 */
  @Local locked: boolean = false;
  /** 右侧选集面板可见性 */
  @Local partsPanelVisible: boolean = false;
  /** 设置面板可见性（R7 落点二：倍速/画面缩放） */
  @Local settingsVisible: boolean = false;
  /** 亮度/音量 HUD（R7 落点三：竖滑手势反馈） */
  @Local gestureHudVisible: boolean = false;
  @Local gestureHudText: string = '';
  /** 长按 2x 倍速中（R7 落点三） */
  @Local longPressBoost: boolean = false;
  /** 双指自由变换状态（捏合缩放 1~3x + 双指拖移；切集/设置面板复位） */
  @Local zoomState: VideoZoomState = new VideoZoomState();

  /** 解析后的路由参数（错误态重试用） */
  private routeHid: string = '';
  private routeOrder: number = -1;
  /** @Local 以支持 @Monitor('vm.partIndex') 路径监听（切集复位触发源） */
  @Local vm: OfflinePlayerVM = new OfflinePlayerVM();
  /** 离线弹幕时钟（包裹 vm；aboutToAppear 注入 DanmakuVM） */
  private offlineClock: OfflineDanmakuClock = new OfflineDanmakuClock(this.vm);
  private danmakuVm: DanmakuVM = DanmakuVM.shared();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();
  private xcontroller: XComponentController = new XComponentController();
  private controlsTimer: number = -1;
  private gestureHudTimer: number = -1;
  /** 竖滑手势起点值（亮度或音量） */
  private gestureStart: number = 0;
  /** 竖滑目标：true=亮度 / false=音量（左半屏/右半屏） */
  private gestureIsBrightness: boolean = false;
  /** 长按 2x 前的倍速 */
  private longPressPrevSpeed: number = 1.0;
  /** 双指拖移上一次事件偏移（增量计算基准，onActionStart 记录） */
  private twoPanLastXVp: number = 0;
  private twoPanLastYVp: number = 0;
  /** 窗口亮度镜像（页面离开还原跟随系统） */
  private windowBrightness: number = 1.0;

  aboutToAppear(): void {
    if (typeof this.routeParam === 'string') {
      const raw: string = this.routeParam;
      const at: number = raw.indexOf('#');
      if (at >= 0) {
        this.routeHid = raw.substring(0, at);
        this.routeOrder = Number.parseInt(raw.substring(at + 1));
        if (Number.isNaN(this.routeOrder)) {
          this.routeOrder = -1;
        }
      } else {
        this.routeHid = raw;
        this.routeOrder = -1;
      }
    }
    // 离线弹幕时钟先于子组件挂载注入（DanmakuView attach 时即走本地池）
    this.danmakuVm.useOfflineClock(this.offlineClock);
    this.enterImmersive();
    this.resetControlsTimer();
    this.readWindowBrightness();
    // 音量镜像对齐系统当前值（避免手势起点失真）
    this.vm.refreshSystemVolume();
    this.vm.prepare(this.routeHid, this.routeOrder);
  }

  /** 单击/双击手动判别（ArkUI Exclusive 组内 count:1 每次点击即响应、count:2 永不
   *  触发）：最近一次点击时间戳 + 挂起的延迟单击任务 id */
  private lastTapAt: number = 0;
  private pendingSingleTapId: number = -1;

  aboutToDisappear(): void {
    this.stopControlsTimer();
    this.stopGestureHudTimer();
    if (this.pendingSingleTapId >= 0) {
      clearTimeout(this.pendingSingleTapId);
      this.pendingSingleTapId = -1;
    }
    // 还原在线时钟（防单例残留离线上下文污染在线弹幕）
    this.danmakuVm.restoreOnlineClock();
    this.vm.shutdown();
    this.exitImmersive();
    this.restoreWindowBrightness();
    this.restoreImmersiveWindowBaseline();
  }

  /** 横屏沉浸：横屏方向（全屏布局由 EntryAbility 常开，不再逐页开关——退出关 false 会击穿全局）；
   *  自由窗形态追加 maximize(ENTER_IMMERSIVE) 进全屏沉浸（R6，非自由窗 no-op） */
  private async enterImmersive(): Promise<void> {
    try {
      const context = AppContextHolder.get();
      if (context === null) {
        return;
      }
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setPreferredOrientation(window.Orientation.LANDSCAPE);
    } catch (err) {
      // 方向设置失败不影响播放
    }
    await WindowModeHelper.requestImmersive();
  }

  /** 退出横屏沉浸（页面销毁时还原方向；全屏布局保持全局常开）；
   *  归还自由窗下应用请求的最大化（R6，用户手动最大化的不动） */
  private async exitImmersive(): Promise<void> {
    WindowModeHelper.releaseImmersive();
    try {
      const context = AppContextHolder.get();
      if (context === null) {
        return;
      }
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setPreferredOrientation(window.Orientation.UNSPECIFIED);
    } catch (err) {
      // 忽略
    }
  }

  /** 【白边自愈】离场重申沉浸窗口基线（镜像 Player 同名方法）：Index willShow 在
   *  转场启动前已窗口级重开系统栏，部分真机"隐藏→重开"循环会把系统栏外观重置为
   *  默认不透明底——小白条区域不再透出页面底色而露白边。本页销毁必然晚于重开时机，
   *  此处按启动基线（EntryAbility F 终局）幂等重申：全屏布局常开 + 栏背景透明；
   *  不碰内容前景色（状态栏前景归 EntryAbility/详情页着色逻辑管） */
  private restoreImmersiveWindowBaseline(): void {
    const context = AppContextHolder.get();
    if (context === null) {
      return;
    }
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      mainWindow.setWindowLayoutFullScreen(true).catch((): void => {
        // 忽略：窗口可能正在销毁
      });
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000'
      }).catch((): void => {
        // 忽略：窗口可能正在销毁
      });
    }).catch((): void => {
      // 忽略：窗口可能正在销毁
    });
  }

  private resetControlsTimer(): void {
    this.stopControlsTimer();
    this.controlsTimer = setTimeout((): void => {
      this.showControls = false;
      this.partsPanelVisible = false;
      this.controlsTimer = -1;
    }, 4000);
  }

  private stopControlsTimer(): void {
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
  }

  /** 屏幕锁定切换（R8）：锁定时收起控制层/选集面板并停计时，防误触 */
  private toggleLock(): void {
    this.locked = !this.locked;
    if (this.locked) {
      this.showControls = false;
      this.partsPanelVisible = false;
      this.settingsVisible = false;
      this.stopControlsTimer();
    }
  }

  // ==================== 手势 HUD（R7 落点三） ====================

  private showGestureHud(text: string): void {
    this.gestureHudText = text;
    this.gestureHudVisible = true;
    if (this.gestureHudTimer >= 0) {
      clearTimeout(this.gestureHudTimer);
    }
    this.gestureHudTimer = setTimeout((): void => {
      this.gestureHudVisible = false;
      this.gestureHudTimer = -1;
    }, 800);
  }

  private stopGestureHudTimer(): void {
    if (this.gestureHudTimer >= 0) {
      clearTimeout(this.gestureHudTimer);
      this.gestureHudTimer = -1;
    }
  }

  // ==================== 手势处理（R7 落点三，对齐在线版 Player） ====================

  /** 竖向滑动开始：按起始 x 判定左=亮度 / 右=音量（双指变换进行中短路） */
  private handlePanStart(event: GestureEvent): void {
    if (this.zoomState.gestureActive) {
      return;
    }
    const half: number = this.windowWidthVp() / 2;
    const x: number = event.fingerList.length > 0 ? event.fingerList[0].localX : half;
    this.gestureIsBrightness = x < half;
    this.gestureStart = this.gestureIsBrightness ? this.windowBrightness : this.vm.volume;
    if (this.gestureIsBrightness) {
      this.showGestureHud(`亮度 ${Math.round(this.windowBrightness * 100)}%`);
    } else {
      this.showGestureHud(`音量 ${Math.round(this.vm.volume * 100)}%`);
    }
    this.resetControlsTimer();
  }

  /** 竖向滑动更新：offsetY 为累计位移（手势起点起算），直接映射亮度/音量 */
  private handlePanUpdate(event: GestureEvent): void {
    if (this.zoomState.gestureActive) {
      return;
    }
    const next: number = Math.min(1.0, Math.max(0.0, this.gestureStart - event.offsetY / 400));
    if (this.gestureIsBrightness) {
      this.setWindowBrightness(next);
      this.showGestureHud(`亮度 ${Math.round(next * 100)}%`);
    } else {
      this.vm.setVolume(next);
      this.showGestureHud(`音量 ${Math.round(next * 100)}%`);
    }
  }

  /** 竖向滑动结束 */
  private handlePanEnd(): void {
    if (this.zoomState.gestureActive) {
      return;
    }
    this.stopGestureHudTimer();
    this.gestureHudVisible = false;
  }

  /** 长按开始：临时 2x 倍速（双指变换进行中短路） */
  private async handleLongPressStart(): Promise<void> {
    if (this.zoomState.gestureActive) {
      return;
    }
    this.longPressPrevSpeed = this.vm.speed;
    this.longPressBoost = true;
    await this.vm.setSpeed(2.0);
    this.getUIContext().getPromptAction().showToast({
      message: '倍速: 2.0X'
    });
  }

  /** 长按结束：还原倍速 */
  private async handleLongPressEnd(): Promise<void> {
    if (this.longPressBoost) {
      this.longPressBoost = false;
      await this.vm.setSpeed(this.longPressPrevSpeed);
    }
  }

  /** 取消长按临时 2x（双指变换打断在途长按时调用，还原倍速不弹提示） */
  private async cancelLongPressBoost(): Promise<void> {
    if (this.longPressBoost) {
      this.longPressBoost = false;
      await this.vm.setSpeed(this.longPressPrevSpeed);
    }
  }

  // ==================== 双指自由变换（捏合缩放 + 双指拖移） ====================

  /** 切集复位：partIndex 变化（选集面板/下集按钮/自动连播统一触发） */
  @Monitor('vm.partIndex')
  onPartIndexChanged(monitor: IMonitor): void {
    this.zoomState.reset();
  }

  /** 视频区宽度 vp（全屏页 = 当前窗口宽；变换锚点/钳制基准） */
  private videoAreaWidthVp(): number {
    const width: number = GlobalState.windowSizeInfo().windowWidthVp;
    return width > 0 ? width : 720;
  }

  /** 视频区高度 vp（全屏页 = 当前窗口高；变换锚点/钳制基准） */
  private videoAreaHeightVp(): number {
    const height: number = GlobalState.windowSizeInfo().windowHeightVp;
    return height > 0 ? height : 1280;
  }

  /** 双指手势起效：冻结单指反馈（清手势 HUD、取消在途长按临时 2x） */
  private freezeSingleFingerFeedback(): void {
    this.stopGestureHudTimer();
    this.gestureHudVisible = false;
    this.cancelLongPressBoost();
  }

  /** 捏合开始：标记双指手势进行中并冻结单指反馈 */
  private handlePinchStart(): void {
    this.freezeSingleFingerFeedback();
    this.zoomState.onPinchStart();
  }

  /** 捏合更新：factor 为本次手势累计倍率；锚点 = pinchCenter（vp，视频区原点）保持中点画面不动 */
  private handlePinchUpdate(event: GestureEvent): void {
    this.zoomState.onPinchUpdate(
      event.scale,
      event.pinchCenterX,
      event.pinchCenterY,
      this.videoAreaWidthVp(),
      this.videoAreaHeightVp()
    );
  }

  /** 双指拖移开始：记录增量基准（offset 相对手指按下位置，事件间做差分） */
  private handleTwoPanStart(event: GestureEvent): void {
    this.freezeSingleFingerFeedback();
    this.twoPanLastXVp = event.offsetX;
    this.twoPanLastYVp = event.offsetY;
    this.zoomState.onTwoPanStart();
  }

  /** 双指拖移更新：与上一事件差分为本次增量 */
  private handleTwoPanUpdate(event: GestureEvent): void {
    const dXVp: number = event.offsetX - this.twoPanLastXVp;
    const dYVp: number = event.offsetY - this.twoPanLastYVp;
    this.twoPanLastXVp = event.offsetX;
    this.twoPanLastYVp = event.offsetY;
    this.zoomState.onTwoPanUpdate(dXVp, dYVp, this.videoAreaWidthVp(), this.videoAreaHeightVp());
  }

  /** 双指手势结束：松手保持变换（不回弹），指示器停留 800ms 后隐藏 */
  private handleZoomGestureEnd(): void {
    this.zoomState.onGestureEnd();
  }

  /** 窗口宽度 vp（左右半屏判定基准） */
  private windowWidthVp(): number {
    const info = this.windowSize.windowWidthVp;
    return info > 0 ? info : 720;
  }

  // ==================== 窗口亮度（R7 落点三，对齐在线版 Player） ====================

  /** 读取窗口当前亮度同步镜像 */
  private async readWindowBrightness(): Promise<void> {
    try {
      const context = AppContextHolder.get();
      if (context === null) {
        return;
      }
      const mainWindow: window.Window = await window.getLastWindow(context);
      const brightness: number = mainWindow.getWindowProperties().brightness;
      if (brightness >= 0) {
        this.windowBrightness = Math.min(1.0, Math.max(0.0, brightness));
      }
    } catch (_err) {
      // 忽略
    }
  }

  /** 写入窗口亮度 */
  private async setWindowBrightness(value: number): Promise<void> {
    const clamped: number = Math.min(1.0, Math.max(0.0, value));
    this.windowBrightness = clamped;
    try {
      const context = AppContextHolder.get();
      if (context === null) {
        return;
      }
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setWindowBrightness(clamped);
    } catch (_err) {
      // 忽略
    }
  }

  /** 还原窗口亮度为跟随系统 */
  private async restoreWindowBrightness(): Promise<void> {
    try {
      const context = AppContextHolder.get();
      if (context === null) {
        return;
      }
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setWindowBrightness(-1);
    } catch (_err) {
      // 忽略
    }
  }

  build() {
    NavDestination() {
      Stack() {
        // 内层变换包裹层：只含画面+弹幕，双指自由变换在此层缩放/平移；
        // scale/translate 为渲染变换不改布局，手势/控件/指示器在包裹层外
        Stack() {
          XComponent({ type: XComponentType.SURFACE, controller: this.xcontroller })
            .onLoad((): void => {
              this.vm.attachSurface(this.xcontroller.getXComponentSurfaceId());
            })
            .width('100%')
            .height('100%')

          // 弹幕渲染层（接线）：离线时钟驱动（本地 danmu.xml；离线发送禁用）；
          // 随画面层一起缩放平移
          DanmakuView({ limitScrollLines: 0 })
        }
        .width('100%')
        .height('100%')
        .scale({
          x: this.zoomState.scale,
          y: this.zoomState.scale
        })
        .translate({
          x: this.zoomState.offsetXVp,
          y: this.zoomState.offsetYVp
        })

        // 手势区（R7 落点三，对齐在线版）：双击播放/暂停、竖滑亮度音量、
        // 长按 2x、单击切控制层、双指自由变换；锁定态（R8）不挂载，全屏蔽
        if (!this.locked) {
          Column()
            .width('100%')
            .height('100%')
            .gesture(
              GestureGroup(GestureMode.Exclusive,
                PanGesture({ fingers: 1, direction: PanDirection.Vertical })
                  .onActionStart((event: GestureEvent): void => {
                    this.handlePanStart(event);
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    this.handlePanUpdate(event);
                  })
                  .onActionEnd((): void => {
                    this.handlePanEnd();
                  })
                  .onActionCancel((): void => {
                    this.handlePanEnd();
                  }),
                LongPressGesture({ repeat: false, duration: 1000 })
                  .onAction((): void => {
                    this.handleLongPressStart();
                  })
                  .onActionEnd((): void => {
                    this.handleLongPressEnd();
                  }),
                TapGesture({ count: 1, fingers: 1 })
                  .onAction((): void => {
                    if (this.zoomState.gestureActive) {
                      return;
                    }
                    // 单击/双击手动判别（对齐安卓 onSingleTapConfirmed/onDoubleTap）：
                    // 300ms 窗口内二次点击判双击→播放/暂停并取消挂起单击；
                    // 单击（控制条切换）延迟至窗口期满执行
                    const now: number = Date.now();
                    if (this.lastTapAt > 0 && now - this.lastTapAt <= 300) {
                      this.lastTapAt = 0;
                      if (this.pendingSingleTapId >= 0) {
                        clearTimeout(this.pendingSingleTapId);
                        this.pendingSingleTapId = -1;
                      }
                      this.vm.togglePlay();
                      return;
                    }
                    this.lastTapAt = now;
                    if (this.pendingSingleTapId >= 0) {
                      clearTimeout(this.pendingSingleTapId);
                    }
                    this.pendingSingleTapId = setTimeout((): void => {
                      this.pendingSingleTapId = -1;
                      if (this.showControls) {
                        this.showControls = false;
                        this.partsPanelVisible = false;
                        this.stopControlsTimer();
                      } else {
                        this.showControls = true;
                        this.resetControlsTimer();
                      }
                    }, 300);
                  }),
                // 双指自由变换：捏合缩放 1~3x（锚点=手指中点，松手保持不回弹）
                PinchGesture({ fingers: 2 })
                  .onActionStart((): void => {
                    this.handlePinchStart();
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    this.handlePinchUpdate(event);
                  })
                  .onActionEnd((): void => {
                    this.handleZoomGestureEnd();
                  })
                  .onActionCancel((): void => {
                    this.handleZoomGestureEnd();
                  }),
                // 双指拖移平移（事件间差分增量，钳制画面恒铺满视频区）
                PanGesture({ fingers: 2, direction: PanDirection.All })
                  .onActionStart((event: GestureEvent): void => {
                    this.handleTwoPanStart(event);
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    this.handleTwoPanUpdate(event);
                  })
                  .onActionEnd((): void => {
                    this.handleZoomGestureEnd();
                  })
                  .onActionCancel((): void => {
                    this.handleZoomGestureEnd();
                  })
              )
            )
        }

        // 双指变换指示器：手势进行中常显，松手 800ms 后隐藏；顶部居中，不参与命中测试
        if (this.zoomState.indicatorVisible) {
          Stack({ alignContent: Alignment.Top }) {
            Text(this.zoomState.indicatorText)
              .fontSize($r('app.float.font_size_body'))
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .backgroundColor('rgba(0, 0, 0, 0.60)')
              .borderRadius(999)
              .padding({
                left: $r('app.float.space_md'),
                right: $r('app.float.space_md'),
                top: $r('app.float.space_sm'),
                bottom: $r('app.float.space_sm')
              })
              .margin({ top: $r('app.float.space_lg') })
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
        }

        // ===== 目录错误全页态 =====
        if (this.vm.loadError.length > 0) {
          Column() {
            ErrorRetry({
              message: this.vm.loadError,
              onRetry: (): void => {
                this.vm.prepare(this.routeHid, this.routeOrder);
              }
            })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Color.Black)
        } else if (!this.locked) {
          // 锁定态（R8）：提示条/控制层/面板全收起，只留画面与解锁小锁
          // ===== 断点续播提示条 =====
          if (this.vm.resumeTipVisible) {
            Row({ space: $r('app.float.space_md') }) {
              Text(`上次看到 ${this.vm.resumeTipText}`)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(Color.White)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('跳转')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.brand'))
                .padding($r('app.float.space_sm'))
                .onClick((): void => {
                  this.vm.resumeFromTip();
                })
              // 关闭入口（R7 落点四）：对齐在线页 ResumeTipBar 的 ✕ 语义
              Text('✕')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor('rgba(255,255,255,0.70)')
                .padding($r('app.float.space_sm'))
                .onClick((): void => {
                  this.vm.resumeTipVisible = false;
                })
            }
            .backgroundColor('rgba(0,0,0,0.60)')
            .borderRadius($r('app.float.radius_button'))
            .padding({
              left: $r('app.float.space_md'),
              right: $r('app.float.space_sm'),
              top: $r('app.float.space_xs'),
              bottom: $r('app.float.space_xs')
            })
            .margin({ top: $r('app.float.space_lg') })
          }

          // ===== 弹幕缺失提示 pill =====
          if (this.vm.danmuMissing) {
            Row({ space: $r('app.float.space_sm') }) {
              Text('未发现弹幕文件，请更新弹幕')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor('rgba(255,255,255,0.70)')
              Text('更新')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.brand'))
                .padding($r('app.float.space_xs'))
                .onClick((): void => {
                  this.updateDanmu();
                })
            }
            .backgroundColor('rgba(0,0,0,0.60)')
            .borderRadius($r('app.float.radius_button'))
            .padding({
              left: $r('app.float.space_md'),
              right: $r('app.float.space_sm'),
              top: $r('app.float.space_xs'),
              bottom: $r('app.float.space_xs')
            })
            .margin({ top: this.vm.resumeTipVisible ? $r('app.float.space_lg') : $r('app.float.space_xl') })
          }

          // ===== 控制层 =====
          if (this.showControls) {
            this.ControlLayer()
          }

          // ===== 右侧选集面板 =====
          if (this.partsPanelVisible) {
            this.PartsPanel()
          }

          // ===== 分集切换/缓冲浮层 =====
          if (this.vm.partLoading || this.vm.isBuffering) {
            Column() {
              LoadingProgress()
                .width(36)
                .height(36)
                .color(Color.White)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }

          // ===== 播放错误浮层 =====
          if (this.vm.playbackError.length > 0) {
            Column({ space: $r('app.float.space_sm') }) {
              Text(this.vm.playbackError)
                .fontSize($r('app.float.font_size_body'))
                .fontColor(Color.White)
              Text('重新载入')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.brand'))
                .padding($r('app.float.space_sm'))
                .onClick((): void => {
                  this.vm.retryPlayback();
                })
            }
            .justifyContent(FlexAlign.Center)
            .backgroundColor('rgba(0,0,0,0.55)')
            .width('100%')
            .height('100%')
          }
        }

        // 解锁小锁（R8）：锁定态右上角常驻，唯一交互入口（解锁恢复常规点击/控制层）
        if (this.locked) {
          Stack({ alignContent: Alignment.TopEnd }) {
            Text('🔒')
              .fontSize(18)
              .fontColor(Color.White)
              .padding($r('app.float.space_sm'))
              .backgroundColor('rgba(0,0,0,0.45)')
              .borderRadius($r('app.float.radius_button'))
              .margin($r('app.float.space_md'))
              .onClick((): void => {
                this.toggleLock();
              })
          }
          .width('100%')
          .height('100%')
        }

        // 亮度/音量 HUD + 长按 2x 角标（R7 落点三；不拦截手势）
        if (this.gestureHudVisible || this.longPressBoost) {
          Stack({ alignContent: Alignment.Center }) {
            Column({ space: $r('app.float.space_sm') }) {
              if (this.gestureHudVisible) {
                Text(this.gestureHudText)
                  .fontSize($r('app.float.font_size_body'))
                  .fontColor(Color.White)
                  .backgroundColor('rgba(0,0,0,0.60)')
                  .borderRadius($r('app.float.radius_card'))
                  .padding({
                    left: $r('app.float.space_md'),
                    right: $r('app.float.space_md'),
                    top: $r('app.float.space_sm'),
                    bottom: $r('app.float.space_sm')
                  })
              }
              if (this.longPressBoost) {
                Text('2.0X')
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor(Color.White)
                  .backgroundColor('rgba(0,0,0,0.60)')
                  .borderRadius($r('app.float.radius_card'))
                  .padding({
                    left: $r('app.float.space_md'),
                    right: $r('app.float.space_md'),
                    top: $r('app.float.space_sm'),
                    bottom: $r('app.float.space_sm')
                  })
              }
            }
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
        }

        // 设置面板（R7 落点二：倍速/画面缩放；点击遮罩关闭）
        if (this.settingsVisible) {
          Stack({ alignContent: Alignment.End }) {
            // 遮罩
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('rgba(0,0,0,0.60)')
              .onClick((): void => {
                this.settingsVisible = false;
              })
            this.SettingsPanel()
          }
          .width('100%')
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    // 沉浸对齐 Player：组件级隐藏状态栏/导航条（页面离开自动还原）——
    // 全局沉浸(F 终局)下窗口本就全屏，壳层 padding 随避让区归零自动收回
    .enableStatusBar(false)
    .enableNavigationIndicator(false)
    .backgroundColor(Color.Black)
    .onHidden((): void => {
      this.stopControlsTimer();
    })
    // 返回键拦截（R8）：锁定时返回不解锁也不退出（需先点右上角小锁解锁）
    .onBackPressed((): boolean => {
      return this.locked;
    })
  }

  // ==================== 控制层 ====================

  @Builder
  ControlLayer() {
    Column() {
      // 顶栏：返回 + 标题
      Row({ space: $r('app.float.space_sm') }) {
        Text('‹')
          .fontSize(28)
          .fontColor(Color.White)
          .padding({
            left: $r('app.float.space_sm'),
            right: $r('app.float.space_sm')
          })
          .onClick((): void => {
            Router.back();
          })
        Column({ space: 2 }) {
          Text(this.topTitleText())
            .fontSize($r('app.float.font_size_body'))
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.partTitleOfCurrent())
            .fontSize($r('app.float.font_size_caption'))
            .fontColor('rgba(255,255,255,0.70)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        // 设置入口（R7 落点二）：倍速/画面缩放轻量面板
        Text('设置')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(Color.White)
          .padding($r('app.float.space_xs'))
          .onClick((): void => {
            this.resetControlsTimer();
            this.settingsVisible = true;
          })
        // 锁定入口（R8）：锁定后屏蔽点击/控制层/返回键，仅留右上角小锁解锁
        Text('🔒')
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
          .padding($r('app.float.space_xs'))
          .onClick((): void => {
            this.resetControlsTimer();
            this.toggleLock();
          })
      }
      .width('100%')
      .padding({
        left: this.avoidLeftVp() > 0 ? this.avoidLeftVp() : $r('app.float.space_sm'),
        right: $r('app.float.space_md'),
        top: this.avoidTopVp() > 0 ? this.avoidTopVp() : $r('app.float.space_sm')
      })

      Blank()

      // 底栏：播放控制 + 进度 + 倍速 + 选集
      Column({ space: $r('app.float.space_xs') }) {
        MediaSlider({
          value: this.vm.currentMs,
          maxValue: Math.max(1, this.vm.totalMs),
          onSeek: (ms: number): void => {
            this.vm.seekTotal(ms);
          },
          onInteraction: (): void => {
            this.resetControlsTimer();
          }
        })
        Row({ space: $r('app.float.space_md') }) {
          // 播放/暂停
          Text(this.vm.coreState === PlayerCoreState.PLAYING ? '❚❚' : '▶')
            .fontSize(16)
            .fontColor(Color.White)
            .padding($r('app.float.space_xs'))
            .onClick((): void => {
              this.resetControlsTimer();
              this.vm.togglePlay();
            })
          // -10s
          Text('-10s')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(Color.White)
            .padding($r('app.float.space_xs'))
            .onClick((): void => {
              this.resetControlsTimer();
              this.vm.skipBy(-10000);
            })
          // 时间
          Text(`${VideoDetailVM.formatClock(this.vm.currentMs)} / ${VideoDetailVM.formatClock(this.vm.totalMs)}`)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor('rgba(255,255,255,0.85)')
            .layoutWeight(1)
          // +10s
          Text('+10s')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(Color.White)
            .padding($r('app.float.space_xs'))
            .onClick((): void => {
              this.resetControlsTimer();
              this.vm.skipBy(10000);
            })
          // +90s（R7 落点一：对齐安卓 op 快进特色）
          Text('+90s')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(Color.White)
            .padding($r('app.float.space_xs'))
            .onClick((): void => {
              this.resetControlsTimer();
              this.vm.skipBy(90000);
            })
          // 倍速（R7 落点一：循环点击改菜单直选，含 3.0x）
          Text(OfflineSpeedTable.labelOf(this.vm.speed))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(this.vm.speed === 1.0 ? Color.White : $r('app.color.brand'))
            .padding($r('app.float.space_xs'))
            .bindMenu(this.buildSpeedMenu())
          // 弹幕开关（离线仅开关可见性，完整设置在在线播放页）
          Text(this.danmakuVm.danmakuOn ? '弹幕开' : '弹幕关')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(this.danmakuVm.danmakuOn ? $r('app.color.brand') : 'rgba(255,255,255,0.70)')
            .padding($r('app.float.space_xs'))
            .onClick((): void => {
              this.resetControlsTimer();
              this.danmakuVm.danmakuOn = !this.danmakuVm.danmakuOn;
            })
          // 下集（R7 落点一：末集置灰禁点）
          Text('下集')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(this.hasNextPart() ? Color.White : 'rgba(255,255,255,0.30)')
            .padding($r('app.float.space_xs'))
            .onClick((): void => {
              this.resetControlsTimer();
              if (this.hasNextPart()) {
                this.vm.switchPart(this.vm.partIndex + 1);
              }
            })
          // 选集
          Text('选集')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(Color.White)
            .padding($r('app.float.space_xs'))
            .onClick((): void => {
              this.resetControlsTimer();
              this.partsPanelVisible = !this.partsPanelVisible;
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({
        left: this.avoidLeftVp() > 0 ? this.avoidLeftVp() : $r('app.float.space_md'),
        right: this.avoidRightVp() > 0 ? this.avoidRightVp() : $r('app.float.space_md'),
        bottom: this.avoidBottomVp() > 0 ? this.avoidBottomVp() : $r('app.float.space_sm')
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.45)')
    .onClick((): void => {
      this.resetControlsTimer();
    })
  }

  // ==================== 右侧选集面板 ====================

  @Builder
  PartsPanel() {
    Row() {
      Blank()
      Column() {
        Text('选集')
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .width('100%')
          .padding($r('app.float.space_md'))
        Scroll() {
          Column({ space: 0 }) {
            ForEach(this.partsOf(), (part: Part, index: number) => {
              this.PartPanelRow(part, index)
            }, (part: Part, index: number): string => `${part.vid}#${index}`)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
      .width('36%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.75)')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  /** 设置面板（R7 落点二：倍速滑条 + 画面缩放，视觉对齐在线版播放 Tab） */
  @Builder
  private SettingsPanel() {
    Column() {
      // 头部：标题 + 关闭
      Row() {
        Text('设置')
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
        Blank()
        Text('✕')
          .fontSize($r('app.float.font_size_body'))
          .fontColor('rgba(255,255,255,0.70)')
          .padding($r('app.float.space_xs'))
          .onClick((): void => {
            this.settingsVisible = false;
          })
      }
      .width('100%')
      .padding($r('app.float.space_md'))

      Scroll() {
        Column({ space: $r('app.float.space_md') }) {
          // 播放速度
          Column({ space: $r('app.float.space_sm') }) {
            Row() {
              Text('播放速度')
                .fontSize($r('app.float.font_size_body'))
                .fontColor(Color.White)
              Blank()
              Text(`${this.vm.speed.toFixed(2)}x`)
                .fontSize($r('app.float.font_size_body'))
                .fontColor(Color.White)
            }
            .width('100%')

            Row({ space: $r('app.float.space_sm') }) {
              Text('0.5')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor('rgba(255,255,255,0.60)')
              Slider({
                value: this.vm.speed,
                min: 0.5,
                max: 3.0,
                step: 0.05,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor($r('app.color.brand'))
                .blockColor(Color.White)
                .trackColor('rgba(255,255,255,0.30)')
                .onChange((value: number, _mode: SliderChangeMode): void => {
                  this.vm.setSpeed(value);
                })
              Text('3.0')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor('rgba(255,255,255,0.60)')
            }
            .width('100%')
          }
          .width('100%')

          // 画面缩放（原比例/16:9/4:3/撑满）
          Column({ space: $r('app.float.space_sm') }) {
            Text('画面缩放')
              .fontSize($r('app.float.font_size_body'))
              .fontColor(Color.White)
              .width('100%')
            Row({ space: $r('app.float.space_sm') }) {
              ForEach(ScaleTable.ALL, (option: ScaleModeOption) => {
                Text(option.label)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor(this.vm.scaleMode === option.mode ? $r('app.color.brand') : Color.White)
                  .padding({
                    left: $r('app.float.space_md'),
                    right: $r('app.float.space_md'),
                    top: $r('app.float.space_xs'),
                    bottom: $r('app.float.space_xs')
                  })
                  .borderRadius($r('app.float.radius_button'))
                  .backgroundColor(this.vm.scaleMode === option.mode ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.06)')
                  .onClick((): void => {
                    this.vm.setScaleMode(option.mode);
                  })
              }, (option: ScaleModeOption): string => `setting-scale-${option.mode}`)
            }
          }
          .width('100%')

          // 画面复位（双指自由变换回 1x 居中；已是 1x 时置灰提示）
          Row() {
            Text('画面复位')
              .fontSize($r('app.float.font_size_body'))
              .fontColor(Color.White)
            Blank()
            Text(`${this.zoomState.scale.toFixed(1)}x`)
              .fontSize($r('app.float.font_size_body'))
              .fontColor(Color.White)
              .opacity(this.zoomState.scale === 1 ? 0.45 : 1)
              .padding({
                left: $r('app.float.space_md'),
                right: $r('app.float.space_md'),
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .borderRadius($r('app.float.radius_button'))
              .backgroundColor('rgba(255,255,255,0.06)')
              .onClick((): void => {
                this.zoomState.reset();
              })
          }
          .width('100%')
          .padding($r('app.float.space_sm'))
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
    }
    .width('32%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.75)')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PartPanelRow(part: Part, index: number) {
    Row({ space: $r('app.float.space_sm') }) {
      Text(part.title.length > 0 ? part.title : `第${index + 1}集`)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor(this.partPanelTextColor(part, index))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (index === this.vm.partIndex) {
        Text('正在播')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.brand'))
      } else if (part.hadPlay) {
        Text('已看')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor('rgba(255,255,255,0.50)')
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md'),
      top: $r('app.float.space_sm'),
      bottom: $r('app.float.space_sm')
    })
    .onClick((): void => {
      if (part.flag === DownloadStatus.COMPLETED) {
        this.partsPanelVisible = false;
        this.resetControlsTimer();
        this.vm.switchPart(index);
      }
    })
  }

  // ==================== 辅助 ====================

  private partsOf(): Part[] {
    const video: Video | null = this.vm.video;
    return video !== null ? video.parts : [];
  }

  private partTitleOfCurrent(): string {
    const video: Video | null = this.vm.video;
    if (video === null) {
      return '离线播放';
    }
    const part: Part | undefined = video.parts[this.vm.partIndex];
    if (part === undefined) {
      return '离线播放';
    }
    return part.title.length > 0 ? part.title : `第${this.vm.partIndex + 1}集`;
  }

  /** 顶栏标题（R7 落点一：多分集时拼接集数，对齐在线版 topTitle） */
  private topTitleText(): string {
    const video: Video | null = this.vm.video;
    if (video === null) {
      return '';
    }
    if (!video.isSinglePart) {
      return `${video.title} · 第${this.vm.partIndex + 1}/${video.parts.length}集`;
    }
    return video.title;
  }

  /** 是否有下一集（R7 落点一：下集按钮末集置灰依据） */
  private hasNextPart(): boolean {
    const video: Video | null = this.vm.video;
    return video !== null && this.vm.partIndex + 1 < video.parts.length;
  }

  /** 倍速菜单（R7 落点一：循环点击改菜单直选，补 3.0x） */
  @Builder
  private buildSpeedMenu() {
    Menu() {
      ForEach(OfflineSpeedTable.ALL, (rate: number) => {
        MenuItem({
          content: OfflineSpeedTable.labelOf(rate)
        })
          .selected(this.vm.speed === rate)
          .selectIcon(true)
          .onClick((): void => {
            this.vm.setSpeed(rate);
          })
      }, (rate: number): string => `speed-${rate}`)
    }
  }

  private partPanelTextColor(part: Part, index: number): ResourceColor {
    if (index === this.vm.partIndex) {
      return $r('app.color.brand');
    }
    if (part.flag !== DownloadStatus.COMPLETED) {
      return 'rgba(255,255,255,0.35)';
    }
    return 'rgba(255,255,255,0.85)';
  }

  /** 弹幕更新（缺失 pill）：成功 toast + 重载本地弹幕池 */
  private async updateDanmu(): Promise<void> {
    const ok: boolean = await this.vm.updateDanmu();
    this.getUIContext().getPromptAction().showToast({
      message: ok ? '弹幕已更新' : '弹幕更新失败，请稍后重试'
    });
    if (ok) {
      // 重拉成功：作废旧池，按 danmuPathOfCurrent() 重新装载（接线）
      this.danmakuVm.refreshPool();
    }
  }

  /** 横屏全屏顶栏避让（状态栏高度 px→vp，横屏下通常为 0） */
  private avoidTopVp(): number {
    return this.getUIContext().px2vp(this.windowSize.statusBarHeightPx);
  }

  /** 横屏全屏底栏避让（导航条/手势条高度 px→vp） */
  private avoidBottomVp(): number {
    return this.getUIContext().px2vp(this.windowSize.navBarHeightPx);
  }

  /** 横屏挖孔左侧避让宽度 vp */
  private avoidLeftVp(): number {
    return this.getUIContext().px2vp(this.windowSize.cutoutLeftPx);
  }

  /** 横屏挖孔右侧避让宽度 vp */
  private avoidRightVp(): number {
    return this.getUIContext().px2vp(this.windowSize.cutoutRightPx);
  }
}

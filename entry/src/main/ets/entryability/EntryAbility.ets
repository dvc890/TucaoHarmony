/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want, wantConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ColorModeState, GlobalState, WindowSizeInfo, AppContextHolder } from '../common/GlobalState';
import { ContinuePayload, ContinuationSlot, MissionContinueSwitch } from '../common/ContinuationState';
import { Router } from '../common/Router';
import { WindowModeHelper } from '../common/WindowModeHelper';
import { JsonFileStore } from '../data/JsonFileStore';
import { SessionService } from '../service/session/SessionService';
import { VideoDetailVM } from '../viewmodel/VideoDetailVM';
import { Video, Part } from '../model/entity/BaseEntities';
import { PlayerCoreState } from '../service/player/PlayerController';

const DOMAIN = 0x0000;
const TAG = 'TucaoEntryAbility';

/**
  * 应用入口 Ability
  * 职责：
  * - loadContent 之后注册 windowSizeChange / avoidAreaChange 监听并写入 WindowSizeInfo 单例
  *   （栏高缓存只记非零值：TYPE_SYSTEM 的 bottomRect 恒 0、沉浸页隐藏系统栏的零值事件
  *   均不清缓存；壳层沉浸避让由 Index 路由拦截标志驱动）
  * - 沉浸（F 终局）：layoutFullScreen 常开 + 系统栏背景透明 + 前景双色显式
  *   （statusBarContentColor 浅黑深白）；壳层 padding 与系统栏显隐由
  *   Index 路由栈拦截按落位页驱动（视频页沉浸，其余页面恢复避让与系统栏）
  * - setKeyboardAvoidMode(RESIZE)（loadContent 之后调用）
  * - onConfigurationUpdate 推送深浅色到 ColorModeState 单例（跟随系统，不持久覆盖）
  * - 多端应用接续：
  *   源端 onContinue 采集播放状态快照（wantParam 单键 'tucao.cont'，约 200 字节，
  *   与 HistoryService 断点语义同构）；目标端 onCreate/onNewWant 识别接续 want →
  *   接续槽 → restoreWindowStage → onWindowStageRestore 直达骨架跳过 Splash；
  *   Navigation 不支持系统页面栈恢复，目标端由 Index 消费接续槽手动导航详情页
  */
export default class EntryAbility extends UIAbility {
  private windowSizeInfo: WindowSizeInfo = GlobalState.windowSizeInfo();
  private colorModeState: ColorModeState = GlobalState.colorModeState();
  private mainWindow: window.Window | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 跟随系统深浅色（COLOR_MODE_NOT_SET 即不覆盖系统配置）
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    this.applyColorMode(this.context.config);
    // 数据层初始化（files 目录，收藏/历史/下载目录等 JSON 存储根）
    JsonFileStore.init(this.context.filesDir);
    // 上下文持有（AVSession 等无 context 服务取用）
    AppContextHolder.set(this.context);
    // 多端接续入口默认隐藏：仅播放场景经 Index 路由拦截亮出（syncImmersiveTop 驱动）
    MissionContinueSwitch.setActive(false);
    // 多端接续目标端识别：真接续 launchReason=CONTINUATION；或 want.parameters 携带
    // 接续键（L2 伪 want 验证路径——模拟器无法触发系统接续，以参数注入等效模拟）
    if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION
      || EntryAbility.hasContinuePayload(want)) {
      this.handleContinueWant(want);
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  /** 单实例热启动：接续场景（目标端应用已在运行）与冷启动同构处理 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onNewWant');
    if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION
      || EntryAbility.hasContinuePayload(want)) {
      this.handleContinueWant(want);
    }
  }

  /** want.parameters 是否携带接续键（'tucao.cont'） */
  private static hasContinuePayload(want: Want): boolean {
    const params: Record<string, Object> | undefined = want.parameters;
    return params !== undefined && params[ContinuePayload.WANT_KEY] !== undefined;
  }

  /**
   * 多端接续·源端（用户从系统全局接续入口发起时触发）：
   * 采集播放状态快照写入 wantParam 单键，返回 AGREE。
   * - 非播放场景（video 空/未起播）→ REJECT（非播放页的系统入口已由
   *   setMissionContinueState 隐藏，此处兜底拒绝）
   * - Navigation 路由不支持系统自动恢复页面栈 → 关闭页面栈迁移，目标端手动导航
   * - 视频垂类按需适配（调研方案 §4.5）：源端不退出仅暂停（防双端同播）；
   *   暂停不阻塞协商——wantParam 已带时位，pause 晚到不影响目标端
   */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    const vm: VideoDetailVM = VideoDetailVM.shared();
    const video: Video | null = vm.video;
    if (video === null || !vm.started) {
      hilog.info(DOMAIN, TAG, '[Continuation] onContinue REJECT: 不在播放场景');
      return AbilityConstant.OnContinueResult.REJECT;
    }
    // 版本协商预留：当前无多版本并存发布形态，仅记录对端版本号
    const remoteVersion: Object | undefined = wantParam['version'];
    if (remoteVersion !== undefined) {
      hilog.info(DOMAIN, TAG, '[Continuation] 对端应用版本: %{public}s', JSON.stringify(remoteVersion));
    }
    // Navigation 不支持系统页面栈恢复（调研方案 §1.5）——目标端手动导航
    wantParam[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY] = false;
    // 源端不自动退出仅暂停（调研方案 §4.5）
    wantParam[wantConstant.Params.SUPPORT_CONTINUE_SOURCE_EXIT_KEY] = false;
    // 源端断点先落盘（当前观看位置并入本地历史，切回本端可继续看）
    vm.saveBreakpointNow();
    // 播放状态快照：currentMs 为分集内多段总时位（PlayerController onProgress 权威值）
    const payload: ContinuePayload = new ContinuePayload();
    payload.hid = video.hid;
    payload.partIndex = vm.partIndex;
    payload.positionMs = vm.currentMs;
    payload.playing = vm.coreState === PlayerCoreState.PLAYING;
    payload.title = video.title;
    const part: Part | undefined = video.parts[vm.partIndex];
    payload.partTitle = part !== undefined ? part.title : '';
    payload.ts = Date.now();
    wantParam[ContinuePayload.WANT_KEY] = ContinuePayload.toJson(payload);
    hilog.info(DOMAIN, TAG,
      '[Continuation] onContinue AGREE: hid=%{public}s part=%{public}d pos=%{public}d playing=%{public}s',
      payload.hid, payload.partIndex, payload.positionMs, `${payload.playing}`);
    // 源端仅暂停不退出（不 await：AGREE 先行，暂停后台完成）
    vm.pause();
    return AbilityConstant.OnContinueResult.AGREE;
  }

  /**
   * 多端接续·目标端（onCreate/onNewWant 的接续分支共用，官方 continueRestore 同构）：
   * 解析接续数据入槽 → 接续入口置回 ACTIVE（官方要求：保证本端可再接续回源端）→
   * 同步段内 restoreWindowStage（触发 onWindowStageRestore 直达骨架）。
   * restoreWindowStage 失败兜底（热启动窗口已就绪场景）：清栈后直接导航详情页。
   */
  private handleContinueWant(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      hilog.warn(DOMAIN, TAG, '[Continuation] want.parameters 缺失，按普通启动处理');
      return;
    }
    const raw: Object | undefined = params[ContinuePayload.WANT_KEY];
    const json: string = typeof raw === 'string' ? raw as string : '';
    const payload: ContinuePayload | null = json.length > 0 ? ContinuePayload.fromJson(json) : null;
    if (payload === null) {
      hilog.warn(DOMAIN, TAG, '[Continuation] 接续数据解析失败，按普通启动处理');
      return;
    }
    ContinuationSlot.shared().set(payload);
    hilog.info(DOMAIN, TAG,
      '[Continuation] 目标端接续入槽: hid=%{public}s part=%{public}d pos=%{public}d playing=%{public}s',
      payload.hid, payload.partIndex, payload.positionMs, `${payload.playing}`);
    // 官方要求：接续恢复后置回 ACTIVE，保证本端可再接续回源端
    MissionContinueSwitch.setActive(true);
    // 必须在 onCreate/onNewWant 同步执行段内调用（异步调用会导致迁移后页面加载失败）
    try {
      this.context.restoreWindowStage(new LocalStorage());
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restoreWindowStage failed: %{public}s', JSON.stringify(err));
      this.navigateContinuationFallback();
    }
  }

  /** restoreWindowStage 失败兜底（热启动窗口已就绪场景）：清栈回首页再直达详情页 */
  private navigateContinuationFallback(): void {
    const stack: NavPathStack | null = Router.navPathStack();
    const payload: ContinuePayload | null = ContinuationSlot.shared().peek();
    if (stack === null || payload === null) {
      return;
    }
    stack.clear();
    Router.goVideoDetail(payload.hid);
    hilog.info(DOMAIN, TAG, '[Continuation] 热启动兜底导航: hid=%{public}s', payload.hid);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Splash', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
      this.initWindow(windowStage);
    });
  }

  /**
   * 多端接续·目标端窗口恢复（接续启动时代替 onWindowStageCreate 触发，冷/热启动均走此）：
   * - 直达主骨架（跳过 Splash 1.5s 停留），接续槽由 Index.aboutToAppear 消费导航详情页
   * - Splash 内的会话预热在此兜底（失败静默——详情/直链为公开端点，不依赖会话）
   * - 窗口初始化与冷启动同套（initWindow 复用，内部已做重复注册防护）
   */
  onWindowStageRestore(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageRestore');
    SessionService.shared().prefetchCookie();
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content on restore. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content on restore.');
      this.initWindow(windowStage);
    });
  }

  onWindowStageDestroy(): void {
    // 主窗口销毁，注销监听避免泄漏
    if (this.mainWindow !== undefined) {
      try {
        this.mainWindow.off('windowSizeChange');
        this.mainWindow.off('avoidAreaChange');
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'off window listeners failed: %{public}s', JSON.stringify(err));
      }
      WindowModeHelper.shutdown();
      this.mainWindow = undefined;
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  /** 系统配置变化（深浅色切换等），实时推送全局状态 */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.applyColorMode(newConfig);
    hilog.info(DOMAIN, TAG, 'onConfigurationUpdate colorMode: %{public}d', newConfig.colorMode ?? -1);
  }

  /** 窗口初始化：键盘避让 + 尺寸/避让区监听（必须 loadContent 之后注册） */
  private initWindow(windowStage: window.WindowStage): void {
    let mainWindow: window.Window;
    try {
      mainWindow = windowStage.getMainWindowSync();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'getMainWindowSync failed: %{public}s', JSON.stringify(err));
      return;
    }
    // 接续恢复（onWindowStageRestore）复用本方法时窗口可能已初始化（热启动同窗场景）：
    // 先注销旧监听与自由窗助手，防止 windowSizeChange/avoidAreaChange/windowStatusChange 重复注册
    if (this.mainWindow !== undefined) {
      try {
        this.mainWindow.off('windowSizeChange');
        this.mainWindow.off('avoidAreaChange');
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'off old window listeners failed: %{public}s', JSON.stringify(err));
      }
      WindowModeHelper.shutdown();
    }
    this.mainWindow = mainWindow;
    // 自由窗口模式助手（R6）：注入主窗口并监听 windowStatusChange（FLOATING 互转）
    WindowModeHelper.init(mainWindow);
    // 状态栏前景双色初始应用（onCreate 期窗口未就绪，此处补偿）
    this.applySystemBarColors(this.colorModeState.isDark);

    // 全局沉浸（F 终局）：窗口全屏布局，页面视口延伸至状态栏/导航条之下；
    // Index 壳层（内层 Stack）按避让区高度统一自垫，所有页面内容绝对位置
    // 与非全屏时逐像素一致（hero/全屏转场几何不变）。失败仅告警不中断启动。
    try {
      mainWindow.setWindowLayoutFullScreen(true)
        .catch((err: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(err));
        });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen throw: %{public}s', JSON.stringify(err));
    }
    // 系统栏背景透明（沉浸外观；前景双色仍由 applySystemBarColors 独立管理）
    try {
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000'
      }).catch((err: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties transparent failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties throw: %{public}s', JSON.stringify(err));
    }

    // 键盘避让：RESIZE 模式
    try {
      mainWindow.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setKeyboardAvoidMode failed: %{public}s', JSON.stringify(err));
    }

    // 屏幕密度（同步获取可能抛异常，失败回退 1）
    let density: number = 1;
    try {
      density = display.getDefaultDisplaySync().densityPixels;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getDefaultDisplaySync failed: %{public}s', JSON.stringify(err));
    }

    // 初次同步窗口尺寸
    try {
      const windowRect: window.Rect = mainWindow.getWindowProperties().windowRect;
      this.windowSizeInfo.updateByPixel(windowRect.width, windowRect.height, density);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getWindowProperties failed: %{public}s', JSON.stringify(err));
    }

    // 初次同步系统避让区（状态栏/导航条）
    this.syncAvoidAreas(mainWindow);

    // 窗口尺寸变化（分屏、自由窗口拉伸、折叠等）
    mainWindow.on('windowSizeChange', (size: window.Size) => {
      this.windowSizeInfo.updateByPixel(size.width, size.height, density);
      // 旋转提速观测：几何事件全链路留痕（点击→方向请求→几何回调→稳定判定
      // 各环节耗时分解的基准锚点），INFO 级低频不扰日志
      hilog.info(DOMAIN, TAG, 'windowSizeChange: %{public}d x %{public}d', size.width, size.height);
    });

    // 避让区变化（状态栏、导航条、挖孔、键盘全类型）。
    // 栏高缓存只记非零值（F 终局补充）：TYPE_SYSTEM 事件 bottomRect 恒 0，直接赋值会
    // 清掉导航条高度（仅靠启动期 INDICATOR 事件后到才幸免）；沉浸页窗口级隐藏系统栏
    // （Index.toggleSystemBars）产生的零值事件亦不应清缓存——壳层沉浸避让由路由标志
    // 驱动，缓存只需保留最近一次非零栏高
    mainWindow.on('avoidAreaChange', (options: window.AvoidAreaOptions) => {
      if (options.type === window.AvoidAreaType.TYPE_SYSTEM) {
        if (options.area.topRect.height > 0) {
          this.windowSizeInfo.statusBarHeightPx = options.area.topRect.height;
        }
        if (options.area.bottomRect.height > 0) {
          this.windowSizeInfo.navBarHeightPx = options.area.bottomRect.height;
        }
      }
      if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
        if (options.area.bottomRect.height > 0) {
          this.windowSizeInfo.navBarHeightPx = options.area.bottomRect.height;
        }
      }
      if (options.type === window.AvoidAreaType.TYPE_CUTOUT) {
        this.windowSizeInfo.cutoutLeftPx = options.area.leftRect.width;
        this.windowSizeInfo.cutoutRightPx = options.area.rightRect.width;
      }
      if (options.type === window.AvoidAreaType.TYPE_KEYBOARD) {
        this.windowSizeInfo.keyboardHeightPx = options.area.bottomRect.height;
      }
    });
  }

  /** 同步初始避让区（同步 API，失败仅告警不中断） */
  private syncAvoidAreas(mainWindow: window.Window): void {
    try {
      const systemArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.windowSizeInfo.statusBarHeightPx = systemArea.topRect.height;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getWindowAvoidArea SYSTEM failed: %{public}s', JSON.stringify(err));
    }
    try {
      const indicatorArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.windowSizeInfo.navBarHeightPx = indicatorArea.bottomRect.height;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getWindowAvoidArea INDICATOR failed: %{public}s', JSON.stringify(err));
    }
    this.syncCutoutArea(mainWindow, 0);
    try {
      const keyboardArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
      this.windowSizeInfo.keyboardHeightPx = keyboardArea.bottomRect.height;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getWindowAvoidArea KEYBOARD failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 挖孔避让同步：个别设备早期查询返回全 0，0 值时延迟重试（≤3 次 × 300ms）
   */
  private syncCutoutArea(mainWindow: window.Window, attempt: number): void {
    try {
      const cutoutArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      this.windowSizeInfo.cutoutLeftPx = cutoutArea.leftRect.width;
      this.windowSizeInfo.cutoutRightPx = cutoutArea.rightRect.width;
      if ((cutoutArea.leftRect.width === 0 && cutoutArea.rightRect.width === 0) && attempt < 3) {
        setTimeout((): void => {
          this.syncCutoutArea(mainWindow, attempt + 1);
        }, 300);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getWindowAvoidArea CUTOUT failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 深浅色状态应用（跟随系统昼夜设置） */
  private applyColorMode(config?: Configuration): void {
    const dark: boolean = config?.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.colorModeState.isDark = dark;
    this.applySystemBarColors(dark);
  }

  /** 状态栏/导航条前景双色（浅色黑字、深色白字；窗口未就绪时静默跳过） */
  private applySystemBarColors(dark: boolean): void {
    if (this.mainWindow === undefined) {
      return;
    }
    const contentColor: string = dark ? '#FFFFFF' : '#000000';
    this.mainWindow.setWindowSystemBarProperties({
      statusBarContentColor: contentColor,
      navigationBarContentColor: contentColor
    }).catch((err: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
    });
  }
}

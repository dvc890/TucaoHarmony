/**
 * 全屏沉浸播放页（活画面转场重构；先旋转后展开）
 * - 播放画面 = PlayerNodeController 单例活节点（全工程唯一 XComponent）：
 *   半屏 ⇄ 全屏仅换 NodeContainer 宿主（VideoDetail 同帧移交），播放全程不断流
 * - 半屏 → 全屏连续缩放转场（§3.1 先旋转后展开）：入口参数 { hid, expandParam? }；
 *   手机竖屏的窗口旋转由来源详情页在 push 前经 OrientationArbiter 完成（LANDSCAPE
 *   请求 + 几何稳定确认），本页到达时窗口已在目标几何——飞行恒为"当前窗口内纯
 *   缩放"springMotion（手机/平板统一，needsRotate 旋转支路已删）；POP 与 PUSH
 *   同几何回放（进/回物理对称）；POP 落位仅挂起归还（B6），节点在本页移除
 *   （aboutToDisappear，死线 finish 弹出本页后同帧）经 onNodeReturn 归还详情页
 * - 方向所有权（§3.5）：本页不再触碰窗口方向（声明式 preferredOrientation 已拆，
 *   框架销毁时自动释放注入的 UNSPECIFIED 噪声随之消失）——退出全屏的归还由来源
 *   详情页 restoreNodeHost 经 OrientationArbiter 阶梯执行（sceneboard 容器粘性
 *   换算态需 UNSPECIFIED 重置后阶梯重试，单发目标值会被换算丢弃——详见该类注释）
 * - 转场期间 transitionActive：手势/控制层/弹幕/浮层不渲染；页背景 0 透出详情页；
 *   POP 时详情页已被框架覆盖冻结（INVISIBLE + JSViewActive(false)）无法透出，
 *   以垫底层复现"封面态播放区 + 信息栏"（封面/标题取自共享 VideoDetailVM 单例）
 * - 沉浸（§3.6）：三栏隐藏归 Index willShow 窗口级 setSpecificSystemBarEnabled（进场前
 *   VideoDetail.setPlayerEntryBars 预隐藏）；声明式 enableStatusBar/enableNavigationIndicator
 *   实测不生效，已拆（"more than once" 残留日志真因是框架转场超时残臂 + JS 包装 GC 彩票，
 *   与该属性无关，根治见 HeroAnimateCallback 契约注释）；方向归 arbiter 单一所有者，本页零方向逻辑
 * - 单击切换控制层、控制层 4s 自动隐藏；双击播放/暂停；长按 1s 临时 2x；
 *   左半屏竖滑亮度/右半屏竖滑音量（对齐安卓 DanmuVideoPlayer）
 * - 双指自由变换：捏合缩放 1~3x + 双指拖移（锚点=手指中点，松手保持不回弹），
 *   VideoZoomState 驱动画面+弹幕包裹层缩放平移；双指进行中单指手势冻结；
 *   切集（partIndex 变化）/进出全屏（expandPush/expandPop）复位，设置面板提供"画面复位"
 * - 画面缩放（对齐安卓播放设置）：原比例留边/16:9/4:3/撑满裁剪，经 vm.setScaleMode
 *   交 AVPlayer 处理（盒恒为整窗，比例模式不再缩盒）
 * - 侧拉面板：设置（统一面板）+ 选集（3列网格）+ 投屏 bindSheet（detents 0.6）；
 *   PiP componentController 取自单例节点（节点未建时不起小窗）
 * - 路由：router_map.json → PlayerBuilder（param = hid 字符串或 { hid, expandParam? }）
 */
import { window, PiPWindow, curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoDetailVM } from '../viewmodel/VideoDetailVM';
import { CastVM } from '../viewmodel/CastVM';
import { PlayerControlView, ResumeTipBar } from '../views/player/PlayerControlView';
import { PlayerSettingsPanel } from '../views/player/PlayerSettingsPanel';
import { PlayerPartsPanel } from '../views/player/PlayerPartsPanel';
import { CastPanel } from '../views/player/CastPanel';
import { VideoZoomState } from '../views/player/VideoZoomState';
import { DanmakuView } from '../components/DanmakuView';
import { NetworkImage } from '../components/NetworkImage';
import { Router } from '../common/Router';
import { AppContextHolder, GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { WindowModeHelper } from '../common/WindowModeHelper';
import { HeroAnimateCallback, HeroRectUtils, HeroTransition, PlayerBoxAnim, PlayerExpandParam, RectPx } from '../common/HeroTransition';
import { OrientationArbiter } from '../common/OrientationArbiter';
import { PlayerNodeController } from '../service/player/PlayerNodeController';

/** 盒初态（PUSH 计算一次，POP 回放；进/回对称。§3.1 后 PUSH/POP 同几何，纯缩放） */
class PlayerBoxInit {
  widthVp: number = 0;
  heightVp: number = 0;
  translateXVp: number = 0;
  translateYVp: number = 0;
  /** PUSH 时刻窗口几何快照（R4/R5：POP 活捕失败回退基准，与冻结盒同一基准，
   *  不回退 param push 时刻值——两者可能因点击后窗口变化而不同） */
  windowWidthPx: number = 0;
  windowHeightPx: number = 0;
}

/** 转场窗口几何活算快照（R4/R5）：GlobalState 实时值优先，窗口监听未就绪回退 param 快照 */
class ExpandLiveGeom {
  windowWidthPx: number = 0;
  windowHeightPx: number = 0;
  statusBarPx: number = 0;
  navBarPx: number = 0;
  /** GlobalState 窗口监听已就绪（false = 全部回退 param push 时刻快照） */
  live: boolean = false;
}

/** 路由 builder（router_map.json 注册用） */
@Builder
export function PlayerBuilder(name: string, param: Object) {
  Player({ routeParam: param })
}

@ComponentV2
struct Player {
  /** 路由参数（hid 字符串或 { hid, expandParam? } 对象，aboutToAppear 收窄） */
  @Param routeParam: Object = new Object();
  @Local hid: string = '';
  /** 控制层可见性 */
  @Local showControls: boolean = true;
  /** 屏幕锁定（R8）：锁定后屏蔽手势/控制层/返回键，右侧锁按钮为唯一交互入口（复刻安卓） */
  @Local locked: boolean = false;
  /** 锁定态锁按钮短暂显示（复刻安卓 :238-242）：点屏幕唤出 + 重置计时到时自动隐藏；
   *  未锁定态锁按钮随控制条显隐，不经过此标记 */
  @Local lockHintVisible: boolean = false;
  /** 单击/双击手动判别（ArkUI Exclusive 组内 count:1 每次点击即响应、count:2 永不
   *  触发）：最近一次点击时间戳 + 挂起的延迟单击任务 id */
  private lastTapAt: number = 0;
  private pendingSingleTapId: number = -1;
  /** 设置面板可见 */
  @Local settingsVisible: boolean = false;
  /** 选集面板可见 */
  @Local partsVisible: boolean = false;
  /** 亮度/音量 HUD 可见 */
  @Local gestureHudVisible: boolean = false;
  /** 亮度/音量 HUD 文案 */
  @Local gestureHudText: string = '';
  /** 长按临时倍速（2x）激活中 */
  @Local longPressBoost: boolean = false;
  /** 双指自由变换状态（捏合缩放 1~3x + 双指拖移；切集/进出全屏/设置面板复位） */
  @Local zoomState: VideoZoomState = new VideoZoomState();
  /** 半屏 → 全屏转场参数（无则普通进入） */
  @Local expandParam: PlayerExpandParam | undefined = undefined;
  /** 盒动画状态（宽/高/平移，中心基准；纯缩放飞行） */
  @Local boxAnim: PlayerBoxAnim = new PlayerBoxAnim();
  /** 页背景色数值：0=透明（转场中透出详情页）→ 0xFF000000（落位纯黑） */
  @Local videoBg: number = 0xFF000000;
  /** 转场进行中：手势/控制层/弹幕/浮层不渲染（盒恒挂载） */
  @Local transitionActive: boolean = false;
  /** POP 垫底层可见：详情页被覆盖冻结（框架 INVISIBLE + JSViewActive(false)）期间代替透出 */
  @Local popUnderlayVisible: boolean = false;
  /** 垫底层竖屏态（详情页为上下堆叠布局）：控制假标题挂载与封面 fit——
   *  横屏分栏（平板）真页面标题在右列、视频 16:9 在面板内上下留黑，
   *  手机布局假设（标题在下 + 封面裁切满铺）在平板会造成底部残块与交接错位 */
  @Local underlayPortrait: boolean = true;
  /** 垫底层封面态播放区位置尺寸（与盒初态同源 rect，落位同位交接） */
  @Local underlayCoverLeft: number = 0;
  @Local underlayCoverTop: number = 0;
  @Local underlayCoverWidth: number = 0;
  @Local underlayCoverHeight: number = 0;

  /** @Local 以支持 @Monitor('vm.partIndex') 路径监听（切集复位触发源） */
  @Local vm: VideoDetailVM = VideoDetailVM.shared();
  private castVm: CastVM = CastVM.shared();
  /** PiP 控制器（小窗播放中） */
  private pipController: PiPWindow.PiPController | null = null;
  private controlsTimer: number = -1;
  private gestureHudTimer: number = -1;
  /** PUSH 动画 onFinish 丢失兜底（强制落位，避免卡在转场态） */
  private transitionSafetyTimer: number = -1;
  /** POP 几何稳定等待作废标记（aboutToDisappear 置位：等待期间页面销毁则不再起飞） */
  private popSettleCancelled: boolean = false;
  /** 【B6】节点归还挂起：POP 落位不再即时归还——转场注册死线（850ms）前把
   *  XComponent 重挂到框架仍置 INVISIBLE 的详情页会令 surface 隐藏，落位→
   *  死线间盒内画面瞬间消失露垫底封面（NCC 0.972 闪帧）。归还推迟到本页
   *  移除（aboutToDisappear，死线 finish 弹出本页后同帧）执行，全程视频可见 */
  private nodeReturnPending: boolean = false;
  /** 当前窗口亮度 (0~1) */
  private windowBrightness: number = 1.0;
  /** 手势起始值（亮度/音量） */
  private gestureStart: number = 0;
  /** 手势用途：true=亮度（左半屏），false=音量（右半屏） */
  private gestureIsBrightness: boolean = false;
  /** 长按前倍速（松手还原） */
  private longPressPrevSpeed: number = 1.0;
  /** 双指拖移上一次事件偏移（增量计算基准，onActionStart 记录） */
  private twoPanLastXVp: number = 0;
  private twoPanLastYVp: number = 0;
  /** 盒初态缓存（POP 回放） */
  private boxInit: PlayerBoxInit | null = null;
  private pageId: string = '';

  aboutToAppear(): void {
    // 参数收窄：hid 字符串（降级入口）或 { hid, expandParam? } 对象
    const param: Object = this.routeParam;
    if (param !== null && typeof param === 'object') {
      const record: Record<string, Object> = param as Record<string, Object>;
      const hidValue: Object | undefined = record['hid'];
      if (typeof hidValue === 'string') {
        this.hid = hidValue;
      }
      const expandValue: Object | undefined = record['expandParam'];
      if (expandValue !== undefined && expandValue !== null) {
        this.expandParam = expandValue as PlayerExpandParam;
      }
    } else if (typeof param === 'string') {
      this.hid = param;
    }
    // 方向所有权（§3.5）：本页零方向逻辑——进全屏的 LANDSCAPE 已由来源详情页在
    // push 前经 OrientationArbiter 完成（先旋转后展开，到达时窗口已在目标几何）
    const expand: PlayerExpandParam | undefined = this.expandParam;
    // 新播放页进入：作废在途方向序列（归还阶梯/进全屏等待的上一会话残留），
    // 防其把窗口转回竖屏打断本页飞行/停留
    OrientationArbiter.cancel();
    if (expand !== undefined) {
      // 转场进入：控制层收起，背景透明透出详情页（落位由 PUSH 回调驱动）
      this.transitionActive = true;
      this.videoBg = 0;
      this.showControls = false;
      this.stopControlsTimer();
    } else {
      // 普通进入：纯黑直入 + 控制层浮现
      this.transitionActive = false;
      this.videoBg = 0xFF000000;
      this.showControls = true;
      this.resetControlsTimer();
    }
    // 防御：封面态直接进全屏（异常入口；正常链路 VideoDetail.enterFullscreen 已先起播）
    if (!this.vm.started && this.vm.video !== null) {
      this.vm.startPlay();
    }
    this.readWindowBrightness();
    // 音量镜像对齐系统当前值（避免手势起点失真）
    this.vm.refreshSystemVolume();
  }

  aboutToDisappear(): void {
    this.stopControlsTimer();
    this.stopGestureHudTimer();
    this.stopTransitionSafetyTimer();
    if (this.pendingSingleTapId >= 0) {
      clearTimeout(this.pendingSingleTapId);
      this.pendingSingleTapId = -1;
    }
    this.popSettleCancelled = true;
    this.restoreWindowBrightness();
    // 方向归还不归本页（§3.5 单一所有者）：本页自始未改窗口方向，销毁时无债可还——
    // B 档两段式返回：手机 POP 落位不归还（横屏停留=来源详情页的横屏浏览态），
    // 归还由详情页离开（aboutToDisappear 支路）发起阶梯；平板/折叠落位即复位跟随
    this.restoreImmersiveWindowBaseline();
    if (this.pageId.length > 0) {
      HeroTransition.unregister(this.pageId);
    }
    // 【B6】执行挂起的节点归还：本页移除与详情页再现同帧（死线 finish 弹出
    // 本页后触发），节点重挂时详情页已可见、surface 不经隐藏期——落位到归还
    // 全程视频连续，垫底封面不再露出；详情页 onShown 700ms 兜底保留作回调
    // 丢失备份（pending 已清则空转）
    if (this.nodeReturnPending) {
      this.nodeReturnPending = false;
      const expand: PlayerExpandParam | undefined = this.expandParam;
      if (expand !== undefined) {
        expand.onNodeReturn();
      }
    }
  }

  // ==================== 半屏 → 全屏转场 ====================

  /** 【R4/R5】转场窗口几何活算：EntryAbility 全局监听实时值优先（点击后折叠/旋转
   *  中途变化不依赖 param 快照），监听未就绪回退 param push 时刻值 */
  private expandLiveGeom(param: PlayerExpandParam): ExpandLiveGeom {
    const geom: ExpandLiveGeom = new ExpandLiveGeom();
    const win: WindowSizeInfo = GlobalState.windowSizeInfo();
    if (win.density > 0 && win.windowWidthVp > 0 && win.windowHeightVp > 0) {
      geom.windowWidthPx = win.windowWidthVp * win.density;
      geom.windowHeightPx = win.windowHeightVp * win.density;
      geom.statusBarPx = win.statusBarHeightPx;
      geom.navBarPx = win.navBarHeightPx;
      geom.live = true;
    } else {
      geom.windowWidthPx = param.windowWidthPx;
      geom.windowHeightPx = param.windowHeightPx;
      geom.statusBarPx = 0;
      geom.navBarPx = 0;
      geom.live = false;
    }
    return geom;
  }

  /** 【R4/R5】源播放区矩形活捕：详情页节点在转场启动时仍可查询（冻结期坐标亦有效）；
   *  未携带 hid / 节点查询失败返回 null，调用方回退 param 快照 */
  private recaptureSourceRect(param: PlayerExpandParam): RectPx | null {
    if (param.sourceHid.length === 0) {
      return null;
    }
    return HeroRectUtils.captureRectPx(this.getUIContext(), `player-area-${param.sourceHid}`);
  }

  /** 【B5】POP 垫底底色：冻结横屏 pillarbox 会话（手机竖屏来源，frozenLandscape
   *  标记）源详情页 = 纯黑底 + 居中视频带，垫底同观感（封面同位铺黑底、盒外
   *  区域与冻结页黑边连续）；其余会话（平板分栏/横屏停留）保持页面底色复现
   *  真页面观感 */
  private underlayBgColor(): ResourceColor {
    const expand: PlayerExpandParam | undefined = this.expandParam;
    if (expand !== undefined && expand.frozenLandscape) {
      return Color.Black;
    }
    return $r('app.color.page_background');
  }

  /** 【R4】纯缩放支路盒中心 Y（窗口 px）：沉浸态内容区=整窗（winH/2，实测零偏差基准）；
   *  immersiveTop 未置位边缘态按避让区内容中心 (winH+status−nav)/2 */
  private expandCenterYpx(geom: ExpandLiveGeom): number {
    if (!geom.live || GlobalState.windowSizeInfo().immersiveTop) {
      return geom.windowHeightPx / 2;
    }
    return (geom.windowHeightPx + geom.statusBarPx - geom.navBarPx) / 2;
  }

  /** PUSH/POP 统一入口（Index 驱动回调）。转场状态收尾见 HeroAnimateCallback 契约：
   *  本页只管飞完落位，框架注册超时任务为唯一合法 finish */
  private runExpandAnimation(isPush: boolean): void {
    if (isPush) {
      // 进全屏：方向序列已在 push 前清理（来源详情页 enterFullscreen →
      // OrientationArbiter.requestEnter 内部 cancel），此处无在途归还可打断飞行
      this.expandPush();
    } else {
      this.expandPop();
    }
  }

  /** 进入：半屏播放区 → 全屏（§3.1 先旋转后展开：窗口旋转已在 push 前由来源详情页
   *  经 OrientationArbiter 完成，本页飞行恒为当前窗口内纯缩放 springMotion） */
  private expandPush(): void {
    // 进入全屏复位（保险）：飞行盒内画面回 1x 居中
    this.zoomState.reset();
    const param: PlayerExpandParam | undefined = this.expandParam;
    if (param === undefined) {
      // 无参异常路径：不动画，转场由框架注册超时收尾
      return;
    }
    const ui: UIContext = this.getUIContext();
    hilog.info(0x0000, 'TucaoPlayer', 'expandPush flight start');
    // 【R4 活算】源矩形活捕：转场启动时详情页节点仍可查询，点击后布局有变即用新值；
    // 采集失败/未带 hid 回退 param push 时刻快照（先旋转后展开下两者同几何，等价）
    const liveRect: RectPx | null = this.recaptureSourceRect(param);
    const l: number = liveRect !== null ? liveRect.left : param.sourceLeftPx;
    const t: number = liveRect !== null ? liveRect.top : param.sourceTopPx;
    const w: number = liveRect !== null ? liveRect.width : param.sourceWidthPx;
    const h: number = liveRect !== null ? liveRect.height : param.sourceHeightPx;
    // 【R4 活算】窗口几何取实时值；监听未就绪回退 param push 时刻值
    const geom: ExpandLiveGeom = this.expandLiveGeom(param);
    const pW: number = geom.windowWidthPx;
    const pH: number = geom.windowHeightPx;
    if (pW <= 0 || pH <= 0 || w <= 0 || h <= 0) {
      // 参数非法：跳过动画直接落位
      this.landFullscreenUi();
      return;
    }
    // 【R4】盒中心 Y 基准：沉浸态整窗中心（平板实测零偏差）；未置位边缘态按避让区中心
    const centerYpx: number = this.expandCenterYpx(geom);

    // 盒初态缓存（POP 回放基准）：纯缩放（无旋转），窗口尺寸转场前后不变
    const init: PlayerBoxInit = new PlayerBoxInit();
    init.widthVp = ui.px2vp(w);
    init.heightVp = ui.px2vp(h);
    init.windowWidthPx = pW;
    init.windowHeightPx = pH;
    const targetCenterX: number = l + w / 2;
    const targetCenterY: number = t + h / 2;
    init.translateXVp = ui.px2vp(targetCenterX - pW / 2);
    init.translateYVp = ui.px2vp(targetCenterY - centerYpx);
    this.boxInit = init;

    // PUSH 飞行初态：源区中心平移到窗口中心（root Stack Center 居中基准）
    // 同步置初态（转场回调内改状态，首帧即初态，无闪黑）
    this.boxAnim.width = init.widthVp;
    this.boxAnim.height = init.heightVp;
    this.boxAnim.translateX = ui.px2vp(l + w / 2 - pW / 2);
    this.boxAnim.translateY = ui.px2vp(t + h / 2 - centerYpx);
    this.videoBg = 0;
    this.transitionActive = true;
    this.showControls = false;
    this.stopControlsTimer();
    this.startTransitionSafetyTimer();

    // 【R5 修复】同 VideoDetail heroPush：PUSH 时本页（新建 NavDestination）尚未挂载渲染树，
    // 转场回调内直接 animateTo 令插值丢失（首帧即终态、瞬切无动画，onFinish 空转计时）。
    // 推迟到节点挂载+首帧渲染后启动：首帧=初态（半屏播放区小盒），随后插值放大。
    // 80 + ~600(springMotion) ≈ 690ms < 注册超时 850ms（超时=唯一 finish，
    // 见 HeroAnimateCallback 契约），落位先于收尾、无截断
    setTimeout((): void => {
      ui.animateTo({
        curve: curves.springMotion(0.42, 0.86),
        onFinish: (): void => {
          this.landFullscreenUi();
        }
      }, (): void => {
        this.boxAnim.width = '100%';
        this.boxAnim.height = '100%';
        this.boxAnim.translateX = 0;
        this.boxAnim.translateY = 0;
      });
    }, 80);
  }

  /** PUSH 落位收尾（飞行 onFinish/参数非法兜底/onReady 回调共用）：背景落黑 + 退出转场态
   *  （§3.1 先旋转后展开：窗口旋转已在 push 前完成，落位无旋转重布局要渡，直接整树挂载；
   *  转场状态本身由框架注册超时收尾，见 HeroAnimateCallback 契约） */
  private landFullscreenUi(): void {
    hilog.info(0x0000, 'TucaoPlayer', 'landFullscreenUi');
    this.stopTransitionSafetyTimer();
    this.videoBg = 0xFF000000;
    this.transitionActive = false;
    this.showControlsWithTimer();
  }

  /** 返回：全屏 → 半屏播放区（回放盒初态；POP 完成归还节点）。
   *  【R6 落位修复】releaseImmersive 的 recover() 是异步请求（自由窗从最大化
   *  悬浮尺寸缩放），原先紧随其后同步采集落位矩形/窗口几何并起飞——全部跑在旧
   *  （最大化）几何里，窗口缩放与飞行并发导致平板落位偏移。现仅自由窗进入时
   *  （wasFloating）先等窗口几何稳定（waitFreeWindowSettle）再采集起飞；
   *  非自由窗（手机/全屏平板）releaseImmersive 本身 no-op，零延迟直飞 */
  private expandPop(): void {
    // 旋转提速观测：POP 起飞锚点（≈back() 后转场回调帧，退出耗时分解基准）
    hilog.info(0x0000, 'TucaoPlayer', 'expandPop flight start');
    // 返回半屏复位（保险）：回放盒内画面回 1x 居中
    this.zoomState.reset();
    // 取消 PUSH 落位兜底计时（onFinish 丢失时 1600ms 兜底会在 POP 中途强挂控制层；
    // 已在退出，PUSH 落位兜底失去意义）
    this.stopTransitionSafetyTimer();
    // wasFloating 先行快照：releaseImmersive 内部会清 appRequested 并触发恢复
    const wasFloating: boolean = WindowModeHelper.isFloating();
    // R6 自由窗：归还进全屏时应用请求的窗口最大化（用户手动最大化的不动）
    WindowModeHelper.releaseImmersive();
    if (wasFloating) {
      this.popSettleCancelled = false;
      this.waitFreeWindowSettle().then((): void => {
        // 等待期间页面已销毁（快速退出）：转场由注册超时/详情页兜底收尾
        if (this.popSettleCancelled) {
          return;
        }
        this.performExpandPop();
      });
    } else {
      this.performExpandPop();
    }
  }

  /** 【R6 落位修复】等自由窗 recover() 缩放落地：垫底一拍让恢复请求先到窗口管理，
   *  再轮询窗口状态回 FLOATING 且尺寸两采样一致（EntryAbility windowSizeChange
   *  实时写入 GlobalState 的值）。上限 ≈120+5×80=520ms + 飞行 ~640ms < 自由窗 POP
   *  注册超时 1300ms（唯一 finish，见 HeroAnimateCallback 契约）；
   *  超时按当前几何尽力采集（与旧行为一致，仅概率性偏差） */
  private async waitFreeWindowSettle(): Promise<void> {
    await new Promise<void>((resolve: (value: void) => void): void => {
      setTimeout((): void => {
        resolve();
      }, 120);
    });
    let lastW: number = GlobalState.windowSizeInfo().windowWidthVp;
    let lastH: number = GlobalState.windowSizeInfo().windowHeightVp;
    for (let i: number = 0; i < 5; i++) {
      await new Promise<void>((resolve: (value: void) => void): void => {
        setTimeout((): void => {
          resolve();
        }, 80);
      });
      const win: WindowSizeInfo = GlobalState.windowSizeInfo();
      if (win.windowWidthVp === lastW && win.windowHeightVp === lastH &&
        WindowModeHelper.isFloating()) {
        return;
      }
      lastW = win.windowWidthVp;
      lastH = win.windowHeightVp;
    }
  }

  /** POP 主体：采集落位目标 + 起飞（原 expandPop 同步段，几何稳定后执行）。
   *  §3.1 先旋转后展开：PUSH/POP 同窗口几何（窗口旋转在 push 前由详情页完成；
   *  手机 POP 落位后方向按任务⓪方向记忆分流：竖屏来源由详情页延迟 400ms 自动
   *  阶梯归还竖屏（落位帧本页不做任何窗口请求，防转场死线内窗口变动），横屏
   *  来源保持横屏停留，平板/折叠落位即复位传感器跟随），
   *  落位目标 = 冻结详情页节点的当前位置（窗口形态变化时活捕刷新） */
  private performExpandPop(): void {
    const param: PlayerExpandParam | undefined = this.expandParam;
    const init: PlayerBoxInit | null = this.boxInit;
    if (param === undefined || init === null) {
      // 无参数/初态丢失：不飞、直接挂起归还（【B6】归还推迟到本页移除同帧执行，
      // 详情页 700ms 兜底仍生效），转场由框架注册超时收尾
      this.nodeReturnPending = true;
      return;
    }
    const ui: UIContext = this.getUIContext();
    // 【R5 活算】落位目标活捕：全屏停留期间布局可能变化（折叠展开等），
    // 活捕成功飞向当前真实位置；失败回退 PUSH 冻结初态
    const liveRect: RectPx | null = this.recaptureSourceRect(param);
    const geom: ExpandLiveGeom = this.expandLiveGeom(param);
    let landWidthVp: number = init.widthVp;
    let landHeightVp: number = init.heightVp;
    let landTranslateXVp: number = init.translateXVp;
    let landTranslateYVp: number = init.translateYVp;
    if (liveRect !== null && liveRect.width > 0 && liveRect.height > 0) {
      landWidthVp = ui.px2vp(liveRect.width);
      landHeightVp = ui.px2vp(liveRect.height);
      landTranslateXVp = ui.px2vp(liveRect.left + liveRect.width / 2 - geom.windowWidthPx / 2);
      landTranslateYVp =
        ui.px2vp(liveRect.top + liveRect.height / 2 - this.expandCenterYpx(geom));
    }
    // 转场中透出详情页 + 收起控制层/手势层
    this.videoBg = 0;
    this.transitionActive = true;
    this.showControls = false;
    this.stopControlsTimer();
    this.stopGestureHudTimer();
    this.gestureHudVisible = false;

    // POP 垫底层：PUSH 完成时框架把详情页设 INVISIBLE + JSViewActive(false)（覆盖冻结），
    // POP 启动时仅 navbar 有同步恢复、dest 不恢复 → videoBg=0 透出的是窗口底色（暗色=黑）。
    // 垫底层按"封面态播放区 + 信息栏"复现详情页视觉；PUSH/POP 同几何 → 画布恒 '100%'
    // 平铺当前窗口（无旋转映射），盒落位即与封面同位交接
    this.popUnderlayVisible = true;
    // 竖屏判定取实时窗口：手机 POP 飞行期及 B 档横屏停留期窗口恒横屏，按窗口
    // 实际形态渲染垫底（横窗平铺无假标题）；落位后真页面接管
    this.underlayPortrait = geom.windowWidthPx < geom.windowHeightPx;
    // 【R5】垫底封面矩形：活捕成功用当前值，失败回退 param push 时刻快照
    const coverLeftPx: number = liveRect !== null ? liveRect.left : param.sourceLeftPx;
    const coverTopPx: number = liveRect !== null ? liveRect.top : param.sourceTopPx;
    const coverWidthPx: number = liveRect !== null ? liveRect.width : param.sourceWidthPx;
    const coverHeightPx: number = liveRect !== null ? liveRect.height : param.sourceHeightPx;
    this.underlayCoverLeft = ui.px2vp(coverLeftPx);
    this.underlayCoverTop = ui.px2vp(coverTopPx);
    this.underlayCoverWidth = ui.px2vp(coverWidthPx);
    this.underlayCoverHeight = ui.px2vp(coverHeightPx);
    ui.animateTo({
      curve: curves.springMotion(0.42, 0.86),
      onFinish: (): void => {
        this.finishExpandPop();
      }
      }, (): void => {
        this.boxAnim.width = landWidthVp;
        this.boxAnim.height = landHeightVp;
        this.boxAnim.translateX = landTranslateXVp;
        this.boxAnim.translateY = landTranslateYVp;
      });
  }

  /** POP 收尾：挂起节点归还（【B6】不再于落位帧即时归还——转场注册死线 850ms
   *  前归还会把 XComponent 重挂到框架仍置 INVISIBLE 的详情页，surface 随之
   *  隐藏、本页盒内画面瞬间消失，落位→死线间露出垫底封面（NCC 0.972 闪帧）。
   *  节点滞留本页盒内持续渲染，归还推迟到本页移除（aboutToDisappear，死线
   *  finish 弹出本页后同帧）——全程视频可见，surface 不经隐藏期）；转场状态
   *  由框架注册超时收尾（唯一合法 finish，见 HeroAnimateCallback 契约）。
   *  方向归还不在此处（§3.5 单一所有者）：restoreNodeHost——手机竖屏来源由
   *  详情页延迟 400ms 自动阶梯归还竖屏，横屏来源保持横屏停留，平板/折叠落位
   *  即复位 AUTO_ROTATION_RESTRICTED 传感器跟随 */
  private finishExpandPop(): void {
    hilog.info(0x0000, 'TucaoPlayer', 'expandPop flight landed, node return deferred to disappear');
    this.nodeReturnPending = true;
  }

  /** PUSH 动画 onFinish 丢失兜底（1600ms > 注册超时上限 1300ms，必晚于框架收尾） */
  private startTransitionSafetyTimer(): void {
    this.stopTransitionSafetyTimer();
    this.transitionSafetyTimer = setTimeout((): void => {
      this.transitionSafetyTimer = -1;
      if (this.transitionActive) {
        // 兜底落位走统一收尾（补挂控制层，onFinish 丢失时保证落位正确）
        this.landFullscreenUi();
      }
    }, 1600);
  }

  private stopTransitionSafetyTimer(): void {
    if (this.transitionSafetyTimer >= 0) {
      clearTimeout(this.transitionSafetyTimer);
      this.transitionSafetyTimer = -1;
    }
  }

  // ==================== 控制层计时 ====================

  private showControlsWithTimer(): void {
    this.showControls = true;
    this.resetControlsTimer();
  }

  private resetControlsTimer(): void {
    this.stopControlsTimer();
    this.controlsTimer = setTimeout((): void => {
      this.showControls = false;
      // 锁定态锁按钮随同一计时隐藏（复刻安卓 DismissControlViewTimerTask：到时锁按钮一并 GONE）
      this.lockHintVisible = false;
      this.controlsTimer = -1;
    }, 4000);
  }

  private stopControlsTimer(): void {
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
  }

  /** 屏幕锁定切换（R8，复刻安卓 StandardGSYVideoPlayer :150-161）：锁定时收起全部
   *  控制浮层（hideAllWidget 语义），锁按钮换 lock 图标短暂显示后随计时隐藏；
   *  解锁时唤出控制层（手势随挂载条件恢复），锁按钮回到随控制条显隐 */
  private toggleLock(): void {
    this.locked = !this.locked;
    if (this.locked) {
      this.showControls = false;
      this.settingsVisible = false;
      this.partsVisible = false;
      this.gestureHudVisible = false;
      this.lockHintVisible = true;
      this.resetControlsTimer();
    } else {
      this.lockHintVisible = false;
      this.showControlsWithTimer();
    }
  }

  // ==================== 亮度 ====================

  /** 读取当前窗口亮度作为手势起点（-1=跟随系统时以 1.0 为起点） */
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

  /** 【白边自愈】离场重申沉浸窗口基线：Index willShow 在转场启动前已窗口级重开
   *  系统栏（setSpecificSystemBarEnabled 三连开），部分真机"隐藏→重开"循环会把
   *  系统栏外观重置为默认不透明底——小白条区域不再透出页面底色（#F5F6F8）而露
   *  白边（用户报告的退出全屏回归）。本页销毁必然晚于重开时机，此处按启动基线
   *  （EntryAbility F 终局）幂等重申：全屏布局常开 + 栏背景透明；不碰内容前景色
   *  （状态栏前景归 EntryAbility/详情页着色逻辑管，避免覆盖沉浸白字） */
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

  // ==================== 手势 HUD ====================

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

  // ==================== 手势处理 ====================

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

  /** 切集复位：partIndex 变化（选集面板点击/下集按钮/自动连播/断点续播统一触发） */
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
    const info = GlobalState.windowSizeInfo().windowWidthVp;
    return info > 0 ? info : 720;
  }

  /** 锁按钮可见性：未锁定随控制条显隐；锁定态走 lockHintVisible（单击唤出/计时隐藏） */
  private lockButtonVisible(): boolean {
    return this.locked ? this.lockHintVisible : this.showControls;
  }

  /** 锁按钮 X（vp）：距右缘 50vp + 按钮宽 30vp（复刻安卓 alignParentRight/marginRight 50dp） */
  private lockButtonXVp(): number {
    return this.videoAreaWidthVp() - 50 - 30;
  }

  /** 锁按钮 Y（vp）：垂直居中（复刻安卓 centerVertical） */
  private lockButtonYVp(): number {
    return this.videoAreaHeightVp() / 2 - 15;
  }

  // ==================== 小窗播放（PiP 系统悬浮窗） ====================

  /** 创建 PiP 悬浮窗并退后台（VIDEO_PLAY 模板自带播放/暂停与全屏恢复按钮） */
  private async startPipWindow(): Promise<void> {
    if (this.pipController !== null) {
      return;
    }
    const context = AppContextHolder.get();
    if (context === null) {
      return;
    }
    // 活节点单例的 XComponentController（节点未建时不起小窗）
    const xcontroller: XComponentController | null = PlayerNodeController.getInstance().getXComponentController();
    if (xcontroller === null) {
      return;
    }
    try {
      const config: PiPWindow.PiPConfiguration = {
        context: context,
        componentController: xcontroller,
        navigationId: 'MainNavigation',
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY
      };
      const controller: PiPWindow.PiPController = await PiPWindow.create(config);
      this.pipController = controller;
      // 模板按钮：播放/暂停切换（status 1=应播放 0=应暂停；直接 toggle 同步）
      controller.on('controlPanelActionEvent', (event: PiPWindow.PiPActionEventType, _status?: number): void => {
        if (event === 'playbackStateChanged') {
          this.vm.togglePlay();
        }
      });
      controller.on('stateChange', (state: PiPWindow.PiPState, _reason: string): void => {
        if (state === PiPWindow.PiPState.ABOUT_TO_STOP || state === PiPWindow.PiPState.STOPPED) {
          this.pipController = null;
        }
      });
      await controller.startPiP();
      await context.moveAbilityToBackground();
    } catch (_err) {
      this.pipController = null;
      this.getUIContext().getPromptAction().showToast({
        message: '当前设备不支持小窗播放'
      });
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        // POP 垫底层：详情页被框架覆盖冻结不可见，缩小过程无法透出真页 →
        // 以同源 rect 复现"封面态播放区 + 信息栏"（设计意图），落位时与真实详情页同位交接；
        // §3.1 先旋转后展开：PUSH/POP 同窗口几何 → 画布恒 '100%' 平铺当前窗口（无旋转映射）
        if (this.popUnderlayVisible) {
          Stack() {
            NetworkImage({
              url: this.vm.video !== null ? this.vm.video.thumb : '',
              imageWidth: this.underlayCoverWidth,
              imageHeight: this.underlayCoverHeight,
              // 真实面板纵横比恒 16:9（平板分栏面板实测 [0,458,1786,1462] 边坐标 → 1786×1004），
              // 视频满铺面板，假封面须 Cover 满铺同形，落位交接不错位
              fit: ImageFit.Cover
            })
              .position({
                x: this.underlayCoverLeft,
                y: this.underlayCoverTop
              })
            // 假标题仅在竖屏上下堆叠布局挂载（真实标题就在视频下方）；
            // 横屏分栏真标题在右列，挂下方会出现真页没有的底部残块（平板实测"背景太低"）
            if (this.vm.video !== null && this.vm.video.title.length > 0 && this.underlayPortrait) {
              Text(this.vm.video.title)
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.text_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .position({
                  x: this.underlayCoverLeft,
                  y: this.underlayCoverTop + this.underlayCoverHeight + 8
                })
                .width(this.underlayCoverWidth)
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor(this.underlayBgColor())
        }
        // 播放画面盒：活节点 100%×100% + 封面兜底（未起播防御态）；
        // 转场中 width/height/translate 驱动纯缩放飞行，盒恒挂载不卸载（防黑屏）
        Stack() {
          // 内层变换包裹层：只含画面+弹幕，双指自由变换在此层缩放/平移；
          // scale/translate 为渲染变换不改布局，外层转场飞行数学不受影响
          Stack() {
            NodeContainer(PlayerNodeController.getInstance())
              .width('100%')
              .height('100%')
            if (!this.vm.started) {
              NetworkImage({
                url: this.vm.video !== null ? this.vm.video.thumb : '',
                imageWidth: '100%',
                imageHeight: '100%',
                fit: ImageFit.Cover
              })
            }
            // 弹幕渲染层（→  接线）：全屏不限制滚动行数；
            // 时间轴基准 = VideoDetailVM onSegmentChanged 的段偏移 + 段内 currentTime；
            // 随画面层一起缩放平移（转场中随盒飞行，锁定态照常渲染，维持原行为）
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
        }
        .width(this.boxAnim.width)
        .height(this.boxAnim.height)
        .translate({
          x: this.boxAnim.translateX,
          y: this.boxAnim.translateY
        })

        if (!this.transitionActive && !this.locked) {
          // 点击/手势区：单击切换控制层、双击播放暂停、长按 2x、左右竖滑亮度/音量（对齐安卓）；
          // 锁定态（R8）不挂载：单击/双击/长按/竖滑全屏蔽，防误触
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

          // 断点续播提示条
          ResumeTipBar({ vm: this.vm })
            .margin({ top: $r('app.float.space_lg') })

          // 控制层（全屏形态：含键盘快捷键注册）
          if (this.showControls) {
            PlayerControlView({
              vm: this.vm,
              visible: this.showControls,
              fullscreen: true,
              onBack: (): void => {
                Router.back();
              },
              onToggleFullscreen: (): void => {
                Router.back();
              },
              onInteraction: (): void => {
                this.resetControlsTimer();
              },
              onOpenParts: (): void => {
                // 全屏形态：显示右侧选集面板（不再退出全屏）
                this.partsVisible = true;
                this.settingsVisible = false;
              },
              onOpenSettings: (): void => {
                // 全屏形态：显示统一设置面板
                this.settingsVisible = true;
                this.partsVisible = false;
              },
              onToggleControls: (): void => {
                // 点击控制层空白：隐藏控制层
                this.showControls = false;
                this.stopControlsTimer();
              },
              // 控制层可见时的竖滑同样走亮度/音量手势
              onVerticalPanStart: (event: GestureEvent): void => {
                this.handlePanStart(event);
              },
              onVerticalPanUpdate: (event: GestureEvent): void => {
                this.handlePanUpdate(event);
              },
              onVerticalPanEnd: (): void => {
                this.handlePanEnd();
              }
            })
          }

          // 亮度/音量 HUD（竖向滑动反馈）
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

          // 长按 2x 倍速角标
          if (this.longPressBoost) {
            Text('2.0X')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .padding($r('app.float.space_sm'))
              .backgroundColor('rgba(0,0,0,0.60)')
              .borderRadius($r('app.float.radius_card'))
              .alignSelf(ItemAlign.End)
              .margin({ right: $r('app.float.space_lg'), bottom: $r('app.float.space_lg') })
          }

          // 设置面板（双 Tab：播放/弹幕；点击外部关闭）
          PlayerSettingsPanel({
            vm: this.vm,
            zoomState: this.zoomState,
            visible: this.settingsVisible,
            onDismiss: (): void => {
              this.settingsVisible = false;
            },
            onOpenPiP: (): void => {
              this.startPipWindow();
            },
            onResetVideoFrame: (): void => {
              this.zoomState.reset();
            }
          })

          // 选集面板（全屏内呈现，点击外部关闭）
          PlayerPartsPanel({
            vm: this.vm,
            visible: this.partsVisible,
            onDismiss: (): void => {
              this.partsVisible = false;
            }
          })

          // 分集切换/缓冲浮层
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

          // 播放错误浮层
          if (this.vm.playbackError.length > 0) {
            Column({ space: $r('app.float.space_sm') }) {
              Text(this.vm.playbackError)
                .fontSize($r('app.float.font_size_body'))
                .fontColor(Color.White)
              Text('点击重试')
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

        // 锁定态单击透传层（R8 复刻安卓 :238-242）：点屏幕仅唤出锁按钮并重置隐藏计时，
        // 不展开任何控制条；双击/长按/竖滑/双指手势仍全屏蔽（本层只挂 onClick）
        if (!this.transitionActive && this.locked) {
          Column()
            .width('100%')
            .height('100%')
            .onClick((): void => {
              this.lockHintVisible = true;
              this.resetControlsTimer();
            })
        }

        // 锁按钮（R8 复刻安卓 danmu_video_land :232-241）：右侧垂直居中 30vp 裸图标、
        // 距右缘 50vp；未锁定随控制条显隐（unlock 图标=点击锁定），锁定态由单击唤出
        // 短暂显示（lock 图标=点击解锁）。叶子节点直挂根 Stack，命中区仅按钮本身，
        // 不遮挡下层控制条（无全屏包裹层，规避 HitTestMode 穿透/阻塞双刃）
        if (!this.transitionActive && this.lockButtonVisible()) {
          Image(this.locked ? $r('app.media.ic_player_lock') : $r('app.media.ic_player_unlock'))
            .width(30)
            .height(30)
            .objectFit(ImageFit.Contain)
            .position({
              x: this.lockButtonXVp(),
              y: this.lockButtonYVp()
            })
            .onClick((): void => {
              this.toggleLock();
            })
        }
      }
      .width('100%')
      .height('100%')
      // 投屏面板（→  接线）：半模态 sheet，高度 60%（detents 建议 [0.6]）
      .bindSheet(this.castVm.panelVisible, this.castPanelBuilder(), {
        detents: ['60%'],
        dragBar: true,
        showClose: false,
        onDisappear: (): void => {
          this.castVm.closePanel();
        },
        shouldDismiss: (sheetDismiss: SheetDismiss) => {
          sheetDismiss.dismiss();
        }
      })
    }
    .hideTitleBar(true)
    // 转场中透明透出详情页，落位后纯黑
    .backgroundColor(this.videoBg)
    // 沉浸（§3.6）：状态栏/指示条隐藏走 Index willShow 窗口级 setSpecificSystemBarEnabled
    // （进场前 VideoDetail.setPlayerEntryBars 已预隐藏，willShow 退化为无变化空调用）。
    // 声明式 enableStatusBar/enableNavigationIndicator 实测不生效（见 Index 同名注释），已拆
    // （"more than once" 错误真因是框架转场超时残臂 + JS 包装 GC 彩票，与该属性无关——
    // 拆除仅作清理，根治见 HeroAnimateCallback 契约注释）
    .onHidden((): void => {
      this.stopControlsTimer();
    })
    // 返回键拦截（R8）：锁定时返回不解锁也不退出（需先点右侧锁按钮解锁）
    .onBackPressed((): boolean => {
      return this.locked;
    })
    .onReady((context: NavDestinationContext): void => {
      const pageId: string = context.navDestinationId ?? '';
      if (pageId.length === 0) {
        // 无页面 id 无法注册驱动：转场态强制落位，避免界面卡在转场中
        // （窗口旋转已在 push 前完成，无自定义动画可中止，直接落位安全）
        if (this.expandParam !== undefined && this.transitionActive) {
          this.landFullscreenUi();
        }
        return;
      }
      this.pageId = pageId;
      if (this.expandParam === undefined) {
        return;
      }
      const callback: HeroAnimateCallback = new HeroAnimateCallback();
      callback.animation = (isPush: boolean): void => {
        this.runExpandAnimation(isPush);
      };
      // 注册超时 = 唯一合法 finish（契约见 HeroAnimateCallback）：PUSH 飞行 80+~610 ≈
      // 690ms；POP 手机直飞 ~640ms，自由窗另有几何稳定等待 ≤520ms（配置构建期窗口
      // 仍浮动、isFloating 可查——releaseImmersive 在 transition 回调内才执行）
      callback.resolveTimeout = (isPush: boolean): number => {
        if (isPush) {
          return 850;
        }
        return WindowModeHelper.isFloating() ? 1300 : 850;
      };
      HeroTransition.register(pageId, callback);
    })
  }

  /** 投屏面板内容（CastPanel 自带标题与关闭） */
  @Builder
  castPanelBuilder() {
    CastPanel({
      vm: this.castVm,
      onClose: (): void => {
        this.castVm.closePanel();
      }
    })
  }
}

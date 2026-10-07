/**
 * 视频详情页（接线完成；hero 活画面转场重构）
 * - 上半屏 NodeContainer 活节点（16:9）+ 弹幕层 + 控制层/续播提示/加载与错误浮层
 * - 下半屏 页面级标题（DetailHeader，hero 标题锚点）+ 简介/评论 两 Tab
 * - 与全屏页共享 VideoDetailVM + PlayerNodeController 单例：进入全屏仅换节点宿主，
 *   播放全程不断流；从全屏返回经 onNodeReturn/onShown 兜底恢复宿主并重发 surface
 * - 大屏分栏：lg/xl 断点左右分栏（左播放器右详情），小屏上下布局
 * - 顶部沉浸（定案，全断点）：Index 沉浸集把壳层顶部避让归零（pad=0），本页
 *   根随 NavDestination 内容区自窗口顶 [0,0] 布局——16:9 视频区顶边贴合窗口
 *   物理顶、状态栏透明浮在视频内容上，页面侧零补偿（旧方案 A 根 Stack 负 margin
 *   与壳层 pad 互抵的历史包袱已拆除；expandSafeArea 只能延伸背景绘制带不动
 *   画面内容，亦不适用）；分栏（lg/xl）右列自垫状态栏高让 DetailHeader 离开
 *   时钟区；控制层顶栏/续播条在宿主侧让开时钟区，状态栏前景切白字保证可读，
 *   离开页面恢复全局策略
 * - hero 连续缩放转场（卡片 → 详情）：入口参数 { hid, heroParam? }，
 *   带参数时三层盒结构（盒裁剪/缩放 + 内容冻结 + 飞行标题覆盖层）整页从卡片封面
 *   连续放大就位，返回反向收缩回卡片（rect 重查，查不到降级淡出）；无参数普通进入
 * - 半屏 → 全屏（§3.1 先旋转后展开 + §3.6 转场静默期）：竖屏窗口先经
 *   OrientationArbiter.requestEnter 转横屏（LANDSCAPE + 几何稳定确认，超时降级按
 *   当前几何推进），预隐藏三栏并静默 300ms 后再采集 player-area rect 组
 *   PlayerExpandParam 走 Player 同几何纯缩放飞行（rect 以旋转后布局为真：
 *   活捕 → 布局真值兜底）；采集失败降级普通跳转（两条路径均同帧移交节点宿主）
 * - 方向（§3.5 单一所有者）：手机竖屏锁定，平板/折叠展开 AUTO_ROTATION_RESTRICTED
 *   跟随传感器；进入时静态确定。窗口方向为窗口级持久状态（不随页面返回自动还原），
 *   全部请求经 OrientationArbiter 单通道发出（本页声明式 preferredOrientation 已拆）：
 *   进全屏 requestEnter / 退全屏（任务⓪方向记忆：手机竖屏来源 POP 落位后延迟
 *   400ms 自动阶梯归还竖屏——竖屏进全屏退出必须回竖屏详情页，旋转重排即收起
 *   动画，落点=竖屏内嵌播放位；横屏来源（B 档停留态再进）保持横屏停留，离开
 *   本页 aboutToDisappear 才 requestRestore——第一拍 + 阶梯重试对抗容器粘性
 *   换算态；平板/折叠落位即复位传感器跟随）/ 页面销毁防御兜底归还
 * - 弹幕设置抽屉挂载一次（DanmakuSettingsDrawer 锚点层，Sheet 跨页生效）
 * - 退出页面 aboutToDisappear：注销转场回调 + 节点 dispose + 断点落盘 + 释放内核（shutdown）
 * - 路由：router_map.json → VideoDetailBuilder（param = { hid } 对象或 hid 字符串）
 */
import { Video } from '../model/entity/BaseEntities';
import { VideoDetailVM } from '../viewmodel/VideoDetailVM';
import { InfoView } from '../views/detail/InfoView';
import { CommentsView } from '../views/detail/CommentsView';
import { PlayerControlView, ResumeTipBar } from '../views/player/PlayerControlView';
import { DanmakuView } from '../components/DanmakuView';
import { LoadingState } from '../components/LoadingState';
import { ErrorRetry } from '../components/ErrorRetry';
import { Router } from '../common/Router';
import { AppContextHolder, GlobalState, WidthBreakpoint, WindowSizeInfo } from '../common/GlobalState';
import { WindowModeHelper } from '../common/WindowModeHelper';
import { NetworkImage } from '../components/NetworkImage';
import { curves, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  HeroAnimateCallback,
  HeroCardParam,
  HeroDetailAnim,
  HeroRectUtils,
  HeroSource,
  HeroSourceState,
  HeroTransition,
  PlayerExpandParam,
  RectPx
} from '../common/HeroTransition';
import { PlayerNodeController } from '../service/player/PlayerNodeController';
import { OrientationArbiter } from '../common/OrientationArbiter';
import { KnockShareController } from '../service/share/KnockShareController';

/** 标题落位矩形（内容区 vp，纯算术推算）。A4：新增 h=标题盒高——覆盖层以
 *  同高盒复刻源端垂直居中（卡片端定高 42 盒 1 行内容居中偏移 ~10vp），
 *  起飞/落位两端与源端文字逐像素重合 */
class TitleTarget {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  /** 标题盒高 vp（算术兜底 24≈单行 17fp 行高） */
  h: number = 24;
}

/** 路由 builder（router_map.json 注册用） */
@Builder
export function VideoDetailBuilder(name: string, param: Object) {
  VideoDetail({ routeParam: param })
}

@ComponentV2
struct VideoDetail {
  /** 路由参数（{ hid, heroParam? } 对象或 hid 字符串，aboutToAppear 收窄） */
  @Param routeParam: Object = new Object();
  @Local hid: string = '';
  /** 半屏控制层可见性 */
  @Local showControls: boolean = false;
  /** 选中的 Tab（0=简介 1=评论；命名避开通用属性 tabIndex） */
  @Local selectedTab: number = 0;
  /** hero 转场参数（无则普通进入） */
  @Local heroParam: HeroCardParam | undefined = undefined;
  /** hero 动画状态（盒缩放/裁剪/背景 + 飞行标题覆盖层） */
  @Local heroAnim: HeroDetailAnim = new HeroDetailAnim();
  /** 页面方向：进入时静态确定（转场中防被覆盖页重渲染翻转） */
  @Local displayOrientation: window.Orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
  /** 播放节点宿主：undefined = 节点不在本页（已移交全屏页） */
  @Local nodeHost: PlayerNodeController | undefined = undefined;
  /** 节点外借中（全屏转场/全屏停留）：封面态不渲染播放引导层（▶/续播条），仅露封面 */
  @Local nodeAway: boolean = false;

  private vm: VideoDetailVM = VideoDetailVM.shared();
  private tabsController: TabsController = new TabsController();
  private controlsTimer: number = -1;
  /** 节点归还兜底定时器（POP 回调丢失时恢复宿主） */
  private nodeRestoreTimer: number = -1;
  /** 【任务⓪方向记忆】本次全屏进入时窗口为竖屏（needsRotateForFullscreen 时刻值）：
   *  POP 落位后自动阶梯归还竖屏的触发条件；横屏来源（罕见：B 档横屏停留态再进
   *  全屏）保持现状停留语义。每次 enterFullscreen 覆写 */
  private expandFromPortrait: boolean = false;
  /** 【任务⓪】POP 落位后自动归还延迟计时器（scheduleExpandAutoRestore） */
  private expandAutoRestoreTimer: number = -1;
  /** @Local 以支持 @Monitor('windowSize.breakpoint') 路径监听（折叠展开/分屏拖拽切换沉浸态） */
  @Local windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();
  /** 页面当前可见（onShown/onHidden 维护；沉浸状态栏前景仅在可见时着色） */
  private pageVisible: boolean = false;
  /** 沉浸状态栏前景已切白（页面离开/断点切走时恢复全局深浅色策略） */
  private statusBarTinted: boolean = false;
  /** hero 源隐藏状态（POP 起飞前重标记卡片） */
  private heroSource: HeroSourceState = HeroSource.getState();
  private pageId: string = '';
  /** hero 入口采集时的窗口尺寸（POP 判断列表布局是否冻结） */
  private heroCaptureWinW: number = 0;
  private heroCaptureWinH: number = 0;
  /** 旋转窗口懒建冻结（§3.4）：进全屏旋转等待期（§3.1）冻结下方 Tab 区为轻量骨架；
   *  【退向两段式治理】竖屏来源会话（手机 + 平板/折叠）冻结贯穿全屏会话全程——
   *  退向 POP 落位帧=骨架、旋转全程骨架，竖屏 300ms 稳定拍后一次性 build 真实
   *  内容（restoreNodeHost 分流 + @Monitor 解冻支路；横屏来源退向仍落位即解冻） */
  @Local layoutFrozen: boolean = false;
  /** 解冻去抖计时器（几何回竖屏后 300ms 稳定拍） */
  private unfreezeTimer: number = -1;
  /** 冻结安全兜底计时器（阶梯失效/几何事件丢失时防永久骨架） */
  private freezeSafetyTimer: number = -1;
  /** 进全屏旋转等待中（§3.1）：下方 Tab 区冻结（窗口转横屏触发重排版），@Monitor
   *  解冻支路只服务退向（进向窗口自竖屏出发，几何事件会误判"已回竖屏"提前解冻） */
  private layoutFrozenForEnter: boolean = false;
  /** 进全屏 requestEnter 等待中：页面销毁时取消等待并归还窗口方向（快速双返回封口） */
  private enterFullscreenWaiting: boolean = false;
  /** 页面已析构（aboutToDisappear 置位）：requestEnter 返回后不得再 push Player */
  private pageTornDown: boolean = false;
  /** 【B8】退向旋转监视（平板/折叠）：POP 落位（restoreNodeHost 传感器支路）
   *  武装、被覆盖（onHidden）或首拍触发后解除——窗口转竖屏的第一个几何拍
   *  先冻结再 measure（onWindowGeometryChanged 与 @Trace 写入同拍、先于新
   *  几何 measure），首个竖屏帧 = 骨架，规避旋转落定全量 build 风暴；解冻走
   *  既有 300ms 稳定拍。【退向两段式治理后】竖屏来源落位已直接冻结（方向记忆
   *  expandFromPortrait 即传感器意图预判，冻结期本监视为 no-op），本监视实际
   *  服务两段：横屏来源落位后的首次竖屏旋转 + 解冻后浏览期常规旋转；"停留期
   *  翻转持机"支路由横屏落定检测（scheduleExitLandscapeSettle）先行解冻，
   *  其后迟到的竖屏旋转仍由本监视接管 */
  private exitRotationWatch: boolean = false;

  aboutToAppear(): void {
    // 收窄路由参数：{ hid: string, heroParam?: HeroCardParam }
    const param: Object = this.routeParam;
    if (param !== null && typeof param === 'object') {
      const record: Record<string, Object> = param as Record<string, Object>;
      const hidValue: Object = record['hid'];
      if (typeof hidValue === 'string') {
        this.hid = hidValue;
      }
      const heroValue: Object | undefined = record['heroParam'];
      if (heroValue !== undefined && heroValue !== null) {
        const parsed: HeroCardParam = heroValue as HeroCardParam;
        // 视口校验：首页多分组/多 Tab 会以相同 id 挂载同一视频的多张卡片，
        // 采集可能命中屏幕外实例（矩形合法但位于视口外，宽高守卫拦不住）。
        // 命中垃圾矩形则放弃 hero 转场，回退系统默认转场（push/pop 均干净降级）
        this.heroParam = this.heroParamInView(parsed) ? parsed : undefined;
      }
    } else if (typeof param === 'string') {
      // 兼容旧式字符串 hid 入口
      this.hid = param;
    }
    // 记录入口窗口尺寸：POP 时判断列表布局是否冻结（未变则复用入口 rect，不重查）
    this.heroCaptureWinW = this.windowSize.windowWidthVp;
    this.heroCaptureWinH = this.windowSize.windowHeightVp;
    // 方向静态确定：手机竖屏锁定；平板/折叠展开保持传感器跟随
    if (this.windowSize.isCompact() && !HeroTransition.isExpandedOrHalfFolded()) {
      this.displayOrientation = window.Orientation.PORTRAIT;
    } else {
      this.displayOrientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
    }
    // 播放节点归本页 + surface 监听转发 VM（幂等重绑）
    this.nodeHost = PlayerNodeController.getInstance();
    this.nodeHost.setSurfaceListener((surfaceId: string): void => {
      this.vm.attachSurface(surfaceId);
    });
    if (this.hid.length > 0) {
      this.vm.loadDetail(this.hid);
    }
    // 音量镜像对齐系统当前值（键盘步进/手势基准）
    this.vm.refreshSystemVolume();
  }

  aboutToDisappear(): void {
    this.pageTornDown = true;
    this.stopControlsTimer();
    this.stopNodeRestoreTimer();
    this.stopExpandAutoRestoreTimer();
    // 碰一碰分享注销（onHidden 已注销时此处幂等）
    KnockShareController.getInstance().unlisten();
    this.unfreezeDetailLayout();
    // 方向归还（§3.5 本页是唯一归还责任人）——任务⓪ 后归还触发点分层：
    //  主触发＝POP 落位自动阶梯（scheduleExpandAutoRestore，竖屏来源专用）；
    //  本处降级为防御/兜底段——
    //  ① 进全屏旋转等待中销毁（快速双返回）：取消等待序列，按声明方向发起归还
    //   （此际窗口可能已横屏/旋转在途，arbiter 第一拍 + 阶梯保证最终回竖屏）；
    //  ② 声明竖屏但窗口实际仍横屏（横屏来源停留态离开本页 / 落位自动归还
    //    未及触发即离开）：发起阶梯归还（arbiter 静态序列独立于页面生命周期
    //    继续步进；旋转落定时本页已拆除，重排风暴面只剩列表页——与进全屏
    //    push 期同场景，已验证无 appfreeze；同目标在途幂等不重复起序列）
    if (this.enterFullscreenWaiting) {
      this.enterFullscreenWaiting = false;
      OrientationArbiter.cancel();
      OrientationArbiter.requestRestore(this.displayOrientation);
    } else if (this.displayOrientation === window.Orientation.PORTRAIT) {
      const win: WindowSizeInfo = this.windowSize;
      if (win.windowWidthVp > win.windowHeightVp && win.windowHeightVp > 0) {
        hilog.warn(0x0000, 'TucaoDetail', 'aboutToDisappear: window still landscape, defensive restore');
        OrientationArbiter.requestRestore(this.displayOrientation);
      }
    }
    // 沉浸状态栏前景恢复：防止白字泄漏到后续页面（onHidden 已恢复时此处幂等）
    this.pageVisible = false;
    this.syncStatusBarTint();
    if (this.pageId.length > 0) {
      HeroTransition.unregister(this.pageId);
    }
    // 节点销毁（下次进入重建全新节点/surface）
    this.nodeHost = undefined;
    PlayerNodeController.getInstance().dispose();
    // 断点落盘 + 释放内核/会话（最后一个引用页面退出）
    this.vm.shutdown();
  }

  // ==================== 节点宿主生命周期 ====================

  /** 节点归还（Player POP onFinish 回调）：重建宿主绑定 + surface 幂等重发（归还
   *  提前至转场结束帧同步执行——停留期 +1s 仍显示 ImageKnife 封面的缺陷封口）。
   *  方向按声明分两支（任务⓪方向记忆）：
   *  - 手机（PORTRAIT）＝落位不即时归还（横屏落位帧保持，防转场窗口内窗口变动），
   *    随后按进入来源分流：竖屏来源（expandFromPortrait）→ 延迟 400ms 自动阶梯
   *    归还竖屏（用户语义：竖屏进全屏，退出必须回竖屏详情页，收起动画与阶梯
   *    旋转重排连续过渡，落点=竖屏内嵌播放位）；横屏来源（B 档停留态再进）→
   *    保持横屏停留浏览态，归还推迟到离开本页（aboutToDisappear 防御段）
   *  - 平板/折叠（传感器跟随声明）：落位即复位 AUTO_ROTATION_RESTRICTED 还清
   *    跟随；落位解冻按方向记忆分流（竖屏来源冻结贯穿旋转，见下方分支注释） */
  private restoreNodeHost(): void {
    this.stopNodeRestoreTimer();
    hilog.info(0x0000, 'TucaoDetail', 'restoreNodeHost: node rebound (expand pop landed)');
    this.nodeAway = false;
    this.nodeHost = PlayerNodeController.getInstance();
    this.syncSurfaceId();
    if (this.displayOrientation === window.Orientation.PORTRAIT) {
      // 任务⓪：竖屏来源的退出全屏自动归还（延迟起梯，见 scheduleExpandAutoRestore）
      if (this.expandFromPortrait) {
        // 【问题B·§2.5-6】冻结贯穿退向：阶梯期重挂 20s 安全兜底（旋转彻底失效
        // 时防永久骨架——20s 后解冻建横屏内容，终端兜底）
        this.armFreezeSafety();
        this.scheduleExpandAutoRestore();
      } else {
        // B-档（横屏来源再进）：无阶梯债，防御性解冻（常规流程幂等 no-op）
        this.unfreezeDetailLayout();
      }
      return;
    }
    // 平板/折叠：传感器归还在途。【B8】武装退向旋转监视（解冻后窗口转竖屏的
    // 首拍冻结 before measure + 之后常规旋转的落定风暴治理，见
    // onWindowGeometryChanged；冻结期首拍为 no-op——!layoutFrozen 门控天然兼容）。
    // 落位解冻按方向记忆分流（退向两段式治理）：
    // - 竖屏来源（expandFromPortrait，方向记忆保证退出回竖屏）：落位不 unfreeze
    //   ——立即冻结骨架化（会话期冻结贯穿未解冻时为幂等确认，降级/残留路径
    //   兜底）。落位帧=骨架（视频带+空白下区，对齐手机端观感），旋转全程骨架
    //   连续，竖屏 300ms 稳定拍后解冻建真实竖屏布局——消灭"落位先横屏分栏、
    //   再转竖屏"的两段式中间态。20s 兜底重挂；横屏落定检测兜住"停留期翻转
    //   持机、传感器决定横屏"支路（scheduleExitLandscapeSettle）
    // - 横屏来源（expandFromPortrait=false）：现状不动——落位 unfreeze 即时建
    //   分栏（无旋转债无中间态）
    this.exitRotationWatch = true;
    if (this.expandFromPortrait) {
      const win: WindowSizeInfo = this.windowSize;
      if (win.windowWidthVp > 0 && win.windowHeightVp > win.windowWidthVp) {
        // 窗口已竖屏（停留期外部归还/进入期旋转未遂降级）：无旋转债，直解建真内容
        this.unfreezeDetailLayout();
      } else {
        this.layoutFrozen = true;
        this.armFreezeSafety();
        this.scheduleExitLandscapeSettle();
      }
    } else {
      this.unfreezeDetailLayout();
    }
    OrientationArbiter.requestRestore(this.displayOrientation);
  }

  /** 【任务⓪】POP 落位自动阶梯归还竖屏。延迟起梯的时序依据（【旋转提速】
   *  400→50 校准修正）：restoreNodeHost 实际触发点=框架转场注册死线收尾
   *  （POP 起算 850ms，B6 归还推迟至 Player aboutToDisappear 后；飞行 onFinish
   *  仅 ~640ms 先到、此后 ~210ms 静默等死线）——死线（850ms）前不得有任何
   *  窗口变动（§3.6 同源约束，防 more than once 回归）。旧值 400ms 是 B6 前
   *  "onFinish(~640ms)+400=1040ms>死线"的校准残留；B6 后实际触发点已后移到
   *  死线本身，400ms 变成纯等待。50ms 使阶梯第一拍（requestRestore 即发
   *  PORTRAIT，健康容器立即旋转）落在 ~900ms ≥ 死线，旋转请求最早合法发出。
   *  阶梯期间（模拟器粘性容器 ~3s 拒竖屏硬约束）用户所见即横屏详情页分栏
   *  浏览态；PORTRAIT 生效时视频节点已绑回本页 NodeContainer，随重排自然落
   *  至竖屏内嵌播放位（落点=竖屏详情页播放器位置 ±2px 天然达成，无"落定再
   *  跳"）。重入安全：restoreNodeHost 多通道触发（onNodeReturn / onShown 700ms
   *  兜底）时重启计时器幂等。
   *  【否决方案留痕】"PORTRAIT 前移到 pop 起飞瞬间"（用户感知最优 ~0.7s）被
   *  否决：① 窗口变动落入 850ms 转场死线窗口内，框架 double-arm 转场超时
   *  （"more than once"）风险回归；② 飞行盒/垫底 rect 按横屏几何采集，旋转
   *  中重排会令落位目标错位——两均为契约级风险，收益不抵 */
  private scheduleExpandAutoRestore(): void {
    this.stopExpandAutoRestoreTimer();
    this.expandAutoRestoreTimer = setTimeout((): void => {
      this.expandAutoRestoreTimer = -1;
      const win: WindowSizeInfo = this.windowSize;
      if (win.windowWidthVp <= win.windowHeightVp || win.windowHeightVp <= 0) {
        // 窗口已回竖屏（进入期旋转超时未遂即直进 / 外部归还已达）：无债可还；
        // 【问题B·§2.5-7】直解冻结（monitor 亦会解，直解更确定、即时）
        this.unfreezeDetailLayout();
        return;
      }
      hilog.info(0x0000, 'TucaoDetail', 'expand auto restore: ladder start (portrait source)');
      OrientationArbiter.requestRestore(window.Orientation.PORTRAIT);
    }, 50);
  }

  private stopExpandAutoRestoreTimer(): void {
    if (this.expandAutoRestoreTimer >= 0) {
      clearTimeout(this.expandAutoRestoreTimer);
      this.expandAutoRestoreTimer = -1;
    }
  }

  /** surface 幂等重发（节点未重建时 surface 不变，重复 setSurface 无副作用） */
  private syncSurfaceId(): void {
    const host: PlayerNodeController | undefined = this.nodeHost;
    if (host !== undefined) {
      host.dispatchSurface();
    }
  }

  /** 节点归还兜底：1400ms 后仍未归还则强制恢复（onNodeReturn 回调真丢失场景）。
   *  【B6 修正】归还已推迟到 Player 页销毁（aboutToDismiss → onNodeReturn），
   *  触发点=框架转场注册死线收尾：手机 expand POP 850ms / 自由窗 POP 1300ms。
   *  旧值 700ms < 死线，兜底反而先于正常归还触发（详情页重挂早于弹页卸载，
   *  实测双 restoreNodeHost）；须大于最长死线 1300ms，取 1400ms 保证
   *  正常路径 onNodeReturn 恒先到、兜底只接真回调丢失 */
  private startNodeRestoreTimer(): void {
    this.stopNodeRestoreTimer();
    this.nodeRestoreTimer = setTimeout((): void => {
      this.nodeRestoreTimer = -1;
      if (this.nodeHost === undefined) {
        this.restoreNodeHost();
      }
    }, 1400);
  }

  private stopNodeRestoreTimer(): void {
    if (this.nodeRestoreTimer >= 0) {
      clearTimeout(this.nodeRestoreTimer);
      this.nodeRestoreTimer = -1;
    }
  }

  // ==================== 旋转窗口懒建冻结（§3.4） ====================
  // 在用场景：① 进全屏旋转等待（freezeDetailLayoutForEnter）；② 竖屏来源会话
  // 冻结贯穿全屏停留 + 退向旋转全程（退向两段式治理，restoreNodeHost 冻结 /
  // @Monitor 竖屏 300ms 稳定拍解冻 / 横屏落定检测 / 20s 兜底）

  /** 解冻：清计时器后一次性在最终几何下 build 下方 Tab 区（退向主通道/防御
   *  共用；冻结安全兜底在此统一停表——§2.5-8 生命周期清理点） */
  private unfreezeDetailLayout(): void {
    this.stopUnfreezeTimer();
    this.stopFreezeSafetyTimer();
    this.layoutFrozen = false;
    this.layoutFrozenForEnter = false;
  }

  /** 进全屏旋转等待冻结（§3.1）：requestEnter 期间窗口转横屏触发本页重排版
   *  （横屏 MD 断点上下堆叠溢出裁切），冻结下方 Tab 区为轻量骨架渡过等待期。
   *  @Monitor 解冻支路经 layoutFrozenForEnter 旗标对本支路静默（进向窗口自
   *  竖屏出发，几何事件会被误判为"已回竖屏"提前解冻），由 push 后收尾
   *  （§2.5-5）清零旗标武装退向支路 */
  private freezeDetailLayoutForEnter(): void {
    this.layoutFrozenForEnter = true;
    this.layoutFrozen = true;
    // 【问题B·§2.5-10】冻结即收起半屏控制层：等待视觉=纯视频带（控制层顶栏
    // 悬浮其上突兀）；节点移交时随宿主自然卸载，无残留闪烁
    this.showControls = false;
    this.armFreezeSafety();
  }

  /** 冻结安全兜底（20s，§2.5-8）：进向等待期与退向阶梯期各挂一次——彻底失效
   *  路径的终端解冻（防永久骨架，20s 后按当前几何 build 真实内容）。幂等：
   *  已挂不重置（退向重挂前由 stopFreezeSafetyTimer 停旧） */
  private armFreezeSafety(): void {
    if (this.freezeSafetyTimer < 0) {
      this.freezeSafetyTimer = setTimeout((): void => {
        this.freezeSafetyTimer = -1;
        this.unfreezeDetailLayout();
      }, 20000);
    }
  }

  private stopFreezeSafetyTimer(): void {
    if (this.freezeSafetyTimer >= 0) {
      clearTimeout(this.freezeSafetyTimer);
      this.freezeSafetyTimer = -1;
    }
  }

  /** 几何回竖屏后 300ms 稳定拍解冻（连续 windowSizeChange 抖动时反复顺延；
   *  拍点复查仍横屏则静默等下一次几何事件——不与旋转动画中间态抢跑） */
  private scheduleUnfreezeOnPortrait(): void {
    this.stopUnfreezeTimer();
    this.unfreezeTimer = setTimeout((): void => {
      this.unfreezeTimer = -1;
      const win: WindowSizeInfo = this.windowSize;
      if (win.windowHeightVp > win.windowWidthVp) {
        // 诊断日志：真机退向验证依赖完整日志链（落位→旋转拍→300ms 稳定→解冻）
        hilog.info(0x0000, 'TucaoDetail', 'portrait stable beat: unfreeze detail layout');
        this.unfreezeDetailLayout();
      }
    }, 300);
  }

  private stopUnfreezeTimer(): void {
    if (this.unfreezeTimer >= 0) {
      clearTimeout(this.unfreezeTimer);
      this.unfreezeTimer = -1;
    }
  }

  /** 【退向两段式治理】竖屏来源退向横屏落定检测：传感器跟随支路（beat1
   *  UNSPECIFIED 重置 → +1800ms beat2 重发跟随声明）下，窗口才随持机方向旋转
   *  ——"全屏停留期翻转持机、传感器决定横屏"是合法落点，此时无竖屏旋转会
   *  再来。3s（1800 重发 + 旋转 ~500 + 300 稳定拍 + 余量）仍横屏则解冻建
   *  横屏分栏浏览态，防骨架滞留到 20s 兜底；期间竖屏几何拍到达则本计时器被
   *  300ms 稳定拍链路取消（复用 unfreezeTimer 晚到者覆盖互斥语义），更迟的
   *  旋转由 B8 监视接管（首拍冻结 before measure → 骨架 → 300ms 稳定拍解冻） */
  private scheduleExitLandscapeSettle(): void {
    this.stopUnfreezeTimer();
    this.unfreezeTimer = setTimeout((): void => {
      this.unfreezeTimer = -1;
      const win: WindowSizeInfo = this.windowSize;
      if (win.windowWidthVp > win.windowHeightVp && win.windowHeightVp > 0) {
        hilog.info(0x0000, 'TucaoDetail', 'exit landscape settle: sensor chose landscape, unfreeze');
        this.unfreezeDetailLayout();
      }
      // 已竖屏/几何缺失：竖屏稳定拍链路或 20s 兜底接管，此处不动作
    }, 3000);
  }

  // ==================== 半屏控制层 ====================

  private showControlsWithTimer(): void {
    this.showControls = true;
    this.resetControlsTimer();
  }

  private resetControlsTimer(): void {
    this.stopControlsTimer();
    this.controlsTimer = setTimeout((): void => {
      this.showControls = false;
      this.controlsTimer = -1;
    }, 4000);
  }

  private stopControlsTimer(): void {
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
  }

  // ==================== hero 转场（卡片 ⇄ 详情） ====================

  /** hero PUSH/POP 统一入口（Index 驱动回调）。转场状态收尾见 HeroAnimateCallback 契约：
   *  本页只管飞完落位，框架注册超时任务为唯一合法 finish */
  private runHeroAnimation(isPush: boolean): void {
    if (isPush) {
      this.heroPush();
    } else {
      this.heroPop();
    }
  }

  /** 进入：卡片封面/标题 → 整页连续放大就位 */
  private heroPush(): void {
    const heroParam: HeroCardParam | undefined = this.heroParam;
    if (heroParam === undefined) {
      // 无参异常路径：不动画，转场由框架注册超时收尾
      return;
    }
    const ui: UIContext = this.getUIContext();
    const W0: number = this.contentWidthVp();
    const H0: number = this.contentHeightVp();
    // 沉浸路由下盒空间原点恒为窗口顶（壳层 pad=0），窗口 px → 盒 vp 零偏移直换
    const originTopVp: number = 0;
    // 【A1c 快照优先】转场首帧源 rect 优先用点击快照：willShow 已先行 un-pad
    // （壳层避让归零），列表整体上移状态栏高——快照含发射页壳层垫高，换算扣减
    // statusBarVp 即得 un-pad 后真位（与活捕等价；详情页覆盖期间列表冻结无滚动，
    // 快照即权威位置）。仅快照退化（宽高<=0，历史构造参数）才按随参 id 活捕兜底
    // （活捕为 un-pad 后真位，不扣减）；cover/title 逐 rect 独立判断
    const coverId: string = heroParam.coverId.length > 0 ? heroParam.coverId : `cover-${this.hid}`;
    const titleId: string = heroParam.titleId.length > 0 ? heroParam.titleId : `title-${this.hid}`;
    const snapshotCoverOk: boolean = heroParam.coverRect.width > 0 && heroParam.coverRect.height > 0;
    const snapshotTitleOk: boolean = heroParam.titleRect.width > 0 && heroParam.titleRect.height > 0;
    const liveCover: RectPx | null = snapshotCoverOk ? null : HeroRectUtils.captureRectPx(ui, coverId);
    const liveTitle: RectPx | null = snapshotTitleOk ? null : HeroRectUtils.captureRectPx(ui, titleId);
    const coverRect: RectPx = snapshotCoverOk ? heroParam.coverRect :
      (liveCover !== null ? liveCover : heroParam.coverRect);
    const titleRect: RectPx = snapshotTitleOk ? heroParam.titleRect :
      (liveTitle !== null ? liveTitle : heroParam.titleRect);
    if (coverRect.width <= 0 || coverRect.height <= 0 ||
      titleRect.width <= 0 || titleRect.height <= 0) {
      // 双路均退化（仅历史构造参数可触发）：不动画防 NaN 缩放，转场由框架注册超时收尾
      return;
    }
    // 【问题A·1.4】快照含非沉浸发射页壳层垫高，PUSH 侧 flush 后 pad 已归 0，
    // 换算须扣减还原；活捕值为 un-pad 后真位，不扣
    const coverPadVp: number = snapshotCoverOk ? this.statusBarVp() : 0;
    const titlePadVp: number = snapshotTitleOk ? this.statusBarVp() : 0;
    const pageBg: number = HeroTransition.resColor(ui, $r('app.color.page_background'), 0xFFF5F6F8);
    const spaceMd: number = HeroTransition.resNumber(ui, $r('app.float.space_md'), 12);
    const bodyFont: number = HeroTransition.resNumber(ui, $r('app.float.font_size_body'), 15);
    const titleFont: number = HeroTransition.resNumber(ui, $r('app.float.font_size_title'), 17);
    // 飞行标题字色插值端点：卡片标题色 → 品牌栏白字
    const textPrimary: number = HeroTransition.resColor(ui, $r('app.color.text_primary'), 0xFF222222);
    const textOnBrand: number = HeroTransition.resColor(ui, $r('app.color.text_on_brand'), 0xFFFFFFFF);

    // 卡片封面 rect（窗口 px）→ 盒空间 vp（盒原点=窗口顶，零偏移直换）
    const cL: number = ui.px2vp(coverRect.left);
    const cT: number = ui.px2vp(coverRect.top) - originTopVp - coverPadVp;
    const cW: number = ui.px2vp(coverRect.width);
    const cH: number = ui.px2vp(coverRect.height);

    // 缩放支路：宽比 ≥ 高比走宽支路（clipW='100%'），否则高支路（clipH='100%'）
    const useWidthScale: boolean = cW / W0 >= cH / H0;
    let scale0: number;
    let clipW0: Length;
    let clipH0: Length;
    if (useWidthScale) {
      scale0 = cW / W0;
      clipW0 = '100%';
      clipH0 = cH / scale0;
    } else {
      scale0 = cH / H0;
      clipH0 = '100%';
      clipW0 = cW / scale0;
    }
    // 盒顶-居中锚点数学：tx = cL − W0/2 + clipW·S/2；ty = cT − clipH·(1−S)/2
    const clipWNum: number = useWidthScale ? W0 : cW / scale0;
    const clipHNum: number = useWidthScale ? cH / scale0 : H0;
    const tx0: number = cL - W0 / 2 + clipWNum * scale0 / 2;
    const ty0: number = cT - clipHNum * (1 - scale0) / 2;

    // 同步置初态（转场回调内改状态，首帧即初态，无闪白）
    this.heroAnim.scaleValue = scale0;
    this.heroAnim.translateX = tx0;
    this.heroAnim.translateY = ty0;
    this.heroAnim.clipWidth = clipW0;
    this.heroAnim.clipHeight = clipH0;
    this.heroAnim.radius = heroParam.cornerRadius;
    this.heroAnim.navBgColor = 0;
    this.heroAnim.titleOpacity = 0;
    this.heroAnim.boxOpacity = 1;
    this.heroAnim.contentWidth = W0;
    this.heroAnim.contentHeight = H0;
    this.heroAnim.overlayVisible = true;
    this.heroAnim.overlayOpacity = 1;
    this.heroAnim.overlayX = ui.px2vp(titleRect.left);
    // 【问题A·1.4】标题 overlay 与封面各自按来源扣减（快照含 pad，活捕不扣）
    this.heroAnim.overlayY = ui.px2vp(titleRect.top) - originTopVp - titlePadVp;
    this.heroAnim.overlayWidth = ui.px2vp(titleRect.width);
    // A4：起飞端盒高=源卡标题盒高（定高 42 盒复刻内容垂直居中，1 行标题
    // 视觉位置随盒高对齐，消除 ~10vp 高差；自适应行卡标题=内容高，恒等）
    this.heroAnim.overlayHeight = ui.px2vp(titleRect.height);
    this.heroAnim.overlayFontSize = bodyFont;
    this.heroAnim.overlayFontColor = textPrimary;

    // 【R2 修复】PUSH 时本页（新建 NavDestination）尚未挂载渲染树，转场回调内直接 animateTo
    // 会令插值丢失：主树属性被闭包直落终值，首帧即渲染终态（瞬切、无动画，onFinish 空转计时）。
    // 推迟到节点挂载+首帧渲染后再启动：首帧=初态（卡位小盒），随后插值放大。
    // 80 + springMotion（大距离稳定可超 1s）< 注册超时 1250ms（超时=唯一 finish，
    // 见 HeroAnimateCallback 契约），落位先于收尾、无截断。
    // 【问题②】落位终点在闭包内解析（titleTargetPush）：此刻页面已挂载，标题行高
    // 活捕才可达（回调期组件未挂载，采集恒空）
    setTimeout((): void => {
      const target: TitleTarget = this.titleTargetPush(ui, W0, spaceMd);
      ui.animateTo({
        curve: curves.springMotion(0.42, 0.86),
        onFinish: (): void => {
          this.heroAnim.overlayVisible = false;
          this.heroAnim.titleOpacity = 1;
          // 静止态释放为百分比：响应后续窗口/折叠变化
          this.heroAnim.contentWidth = '100%';
          this.heroAnim.contentHeight = '100%';
        }
      }, (): void => {
        this.heroAnim.scaleValue = 1;
        this.heroAnim.translateX = 0;
        this.heroAnim.translateY = 0;
        this.heroAnim.clipWidth = '100%';
        this.heroAnim.clipHeight = '100%';
        this.heroAnim.radius = 0;
        this.heroAnim.navBgColor = pageBg;
        this.heroAnim.overlayX = target.x;
        this.heroAnim.overlayY = target.y;
        this.heroAnim.overlayWidth = target.w;
        // A4：落位端盒高=真实标题行高（与 DetailHeader 标题重合后交接零跳变）
        this.heroAnim.overlayHeight = target.h;
        this.heroAnim.overlayFontSize = titleFont;
        this.heroAnim.overlayFontColor = textOnBrand;
      });
    }, 80);
  }

  /** 返回：整页收缩回卡片封面/标题（rect 重查，列表可能已滚动；查不到降级淡出） */
  private heroPop(): void {
    const heroParam: HeroCardParam | undefined = this.heroParam;
    if (heroParam === undefined) {
      // 无参异常路径：不动画，转场由框架注册超时收尾
      return;
    }
    const ui: UIContext = this.getUIContext();
    const W0: number = this.contentWidthVp();
    const H0: number = this.contentHeightVp();
    // 沉浸路由下盒空间原点恒为窗口顶（壳层 pad=0），窗口 px → 盒 vp 零偏移直换
    const originTopVp: number = 0;
    const spaceMd: number = HeroTransition.resNumber(ui, $r('app.float.space_md'), 12);
    const bodyFont: number = HeroTransition.resNumber(ui, $r('app.float.font_size_body'), 15);
    const titleFont: number = HeroTransition.resNumber(ui, $r('app.float.font_size_title'), 17);
    // 飞行标题字色插值端点：品牌栏白字 → 卡片标题色
    const textPrimary: number = HeroTransition.resColor(ui, $r('app.color.text_primary'), 0xFF222222);
    const textOnBrand: number = HeroTransition.resColor(ui, $r('app.color.text_on_brand'), 0xFFFFFFFF);

    // 列表卡片重隐藏 + 标题交覆盖层 + 内容重冻结（窗口尺寸可能已变）
    // 【A1d】按随参 sourceToken（发射实例 token）重标记：同屏同 hid 孪生卡不误隐藏
    this.heroSource.markSource(heroParam.sourceToken);
    this.heroAnim.contentWidth = W0;
    this.heroAnim.contentHeight = H0;
    // A2：内容平移起飞前归零（上次 POP 被中断残留防御；静止态恒 0）
    this.heroAnim.contentTranslateX = 0;
    this.heroAnim.contentTranslateY = 0;
    this.heroAnim.titleOpacity = 0;
    this.heroAnim.boxOpacity = 1;
    this.heroAnim.overlayFontColor = textOnBrand;

    // 卡片矩形解析：详情页全屏覆盖期间列表布局冻结（无法滚动），
    // 窗口未变时入口 rect 即所点卡片的权威位置（A1 后 id 含实例 token，
    // 无重复 id 树序错配问题，快照仍是免采集时序依赖的最优解）。
    // 窗口已变（折叠/旋转/分屏）列表已重排：按随参 id 重查取新位置并做视口
    // 校验，重查不可信回退入口 rect（仍在屏才可用），均不可达才降级淡出
    const winUnchanged: boolean = this.windowSize.windowWidthVp === this.heroCaptureWinW &&
      this.windowSize.windowHeightVp === this.heroCaptureWinH;
    let coverRect: RectPx | null = null;
    let titleRect: RectPx | null = null;
    // 【问题A】快照含采集时刻壳层垫高（发射页均非沉浸，pad=statusBarVp）；
    // 活捕值为当前布局窗口坐标。两者换算基准不同，来源标记决定是否扣减
    let rectsFromSnapshot: boolean = false;
    if (winUnchanged) {
      coverRect = heroParam.coverRect;
      titleRect = heroParam.titleRect;
      rectsFromSnapshot = true;
    } else {
      // 各发射页卡片 id 前缀不同（rank-row- / star-row- / …，A1 后均含实例
      // token 后缀），按随参带来的 id 重查；旧发射点未填 id 时回退 home 网格
      // 的 cover-/title- 约定
      const coverId: string = heroParam.coverId.length > 0 ? heroParam.coverId : `cover-${this.hid}`;
      const titleId: string = heroParam.titleId.length > 0 ? heroParam.titleId : `title-${this.hid}`;
      const liveCover: RectPx | null = HeroRectUtils.captureRectPx(ui, coverId);
      const liveTitle: RectPx | null = HeroRectUtils.captureRectPx(ui, titleId);
      if (liveCover !== null && this.rectIntersectsViewport(liveCover)) {
        coverRect = liveCover;
        titleRect = liveTitle !== null && this.rectIntersectsViewport(liveTitle) ? liveTitle : null;
      } else if (this.rectIntersectsViewport(heroParam.coverRect)) {
        coverRect = heroParam.coverRect;
        titleRect = this.rectIntersectsViewport(heroParam.titleRect) ? heroParam.titleRect : null;
        rectsFromSnapshot = true;
      }
    }

    if (coverRect === null) {
      // 卡片不可达（列表已销毁/滚动出屏）：降级淡出下移
      // 【问题②】静止态活捕真实标题矩形（算术兜底在 titleTargetRest 内）
      const target: TitleTarget = this.titleTargetRest(ui, W0, spaceMd);
      this.heroAnim.overlayVisible = true;
      this.heroAnim.overlayOpacity = 1;
      this.heroAnim.overlayX = target.x;
      this.heroAnim.overlayY = target.y;
      this.heroAnim.overlayWidth = target.w;
      // A4：起飞端盒高=真实标题行高（接管 DetailHeader 标题零跳变）
      this.heroAnim.overlayHeight = target.h;
      this.heroAnim.overlayFontSize = titleFont;
      ui.animateTo({
        duration: 300,
        curve: Curve.EaseInOut,
        onFinish: (): void => {
          this.heroAnim.overlayVisible = false;
          this.heroSource.clearSource();
        }
      }, (): void => {
        this.heroAnim.boxOpacity = 0;
        this.heroAnim.translateY = this.heroAnim.translateY + 60;
        this.heroAnim.navBgColor = 0;
        this.heroAnim.overlayOpacity = 0;
      });
      return;
    }

    // 卡片命中：与 PUSH 对称反向收缩（窗口坐标→盒空间坐标，沉浸态盒原点即窗口顶）
    // 【问题A】POP 时 willShow 已把壳层 pad 翻回 statusBarVp，盒与卡片同在被
    // padding 的 Stack 内同移：快照含采集时刻 pad（c0+pad），须扣减还原 Stack
    // 局域坐标 c0——落点对任意 pad 落帧时序恒贴合（同父级同移不变量）；
    // 活捕值在 flush 前采集、pad 仍为详情期 0，即局域坐标，不扣
    const rectPadVp: number = rectsFromSnapshot ? this.statusBarVp() : 0;
    const cL: number = ui.px2vp(coverRect.left);
    const cT: number = ui.px2vp(coverRect.top) - originTopVp - rectPadVp;
    const cW: number = ui.px2vp(coverRect.width);
    const cH: number = ui.px2vp(coverRect.height);
    // 【A2 落位数学】旧数学整页等比缩放落位（S=cW/W0 或 cH/H0）：卡比 16:9 更"高"
    // （aspect 1.6 < 1.778）时落位帧卡窗内 = 播放区 + 其下方约数十 px 标题/信息条。
    // 改为播放区 Cover 映射进卡片可见窗：S=max(cW/paW, cH/paH)（Cover 语义，
    // 超维居中裁切），clipW=cW/S、clipH=cH/S（盒裁剪窗缩放后恰为卡片窗），
    // 内容层平移令播放区中心对齐卡片窗中心。tx/ty 沿用原结构（根 Stack
    // Alignment.Top 水平居中的布局偏移补偿已内含：tx = cL − W0/2 + S·clipW/2
    // 与 Lx+tx+(1−S)·clipW/2 = cL 等价，宽/高两支路均成立）
    const pa: RectPx = this.playAreaRectPx(ui);
    const paL: number = ui.px2vp(pa.left);
    const paT: number = ui.px2vp(pa.top);
    const paW: number = ui.px2vp(pa.width);
    const paH: number = ui.px2vp(pa.height);
    const scale1: number = Math.max(cW / paW, cH / paH);
    const clipWNum1: number = cW / scale1;
    const clipHNum1: number = cH / scale1;
    const clipW1: Length = clipWNum1;
    const clipH1: Length = clipHNum1;
    const tx1: number = cL - W0 / 2 + clipWNum1 * scale1 / 2;
    const ty1: number = cT - clipHNum1 * (1 - scale1) / 2;
    // 内容层平移（content 坐标）：播放区中心 → 卡片窗中心；Cover 超维侧为负值
    // （播放区缩放后大于卡窗的部分被裁掉），主导维恰为 0
    const contentTx1: number = (cW - paW * scale1) / (2 * scale1) - paL;
    const contentTy1: number = (cH - paH * scale1) / (2 * scale1) - paT;

    // 覆盖层从标题落位起飞，飞回卡片标题（标题不可达则淡出）。
    // 【问题②】静止态活捕真实标题矩形：起飞交接与真实标题逐像素重合（旧算术
    // 终点偏右 + 行内垂直居中未计，交接瞬跳的根因）；算术兜底在 titleTargetRest 内
    const target: TitleTarget = this.titleTargetRest(ui, W0, spaceMd);
    this.heroAnim.overlayVisible = true;
    this.heroAnim.overlayOpacity = 1;
    this.heroAnim.overlayX = target.x;
    this.heroAnim.overlayY = target.y;
    this.heroAnim.overlayWidth = target.w;
    // A4：起飞端盒高=真实标题行高（接管 DetailHeader 标题零跳变）
    this.heroAnim.overlayHeight = target.h;
    this.heroAnim.overlayFontSize = titleFont;
    const titleOk: boolean = titleRect !== null;

    ui.animateTo({
      curve: curves.springMotion(0.42, 0.86),
      onFinish: (): void => {
        // A3：同帧收盒——落位帧盒画面与源卡封面（clearSource 后恢复 Visible）
        // 无缝交接；旧代码盒不清，落位后到框架 1250ms 转场死线间盒画面滞留
        // 覆盖在卡片上（视频帧 ≠ 封面缩略图时可见残影）
        this.heroAnim.overlayVisible = false;
        this.heroAnim.boxOpacity = 0;
        this.heroSource.clearSource();
      }
    }, (): void => {
      this.heroAnim.scaleValue = scale1;
      this.heroAnim.translateX = tx1;
      this.heroAnim.translateY = ty1;
      this.heroAnim.clipWidth = clipW1;
      this.heroAnim.clipHeight = clipH1;
      // A2：内容层平移与盒收缩同帧插值——落位帧播放区恰铺满卡片可见窗
      this.heroAnim.contentTranslateX = contentTx1;
      this.heroAnim.contentTranslateY = contentTy1;
      this.heroAnim.radius = heroParam.cornerRadius;
      this.heroAnim.navBgColor = 0;
      if (titleOk && titleRect !== null) {
        this.heroAnim.overlayX = ui.px2vp(titleRect.left);
        // 【问题A】标题 overlay 与盒共用同一来源扣减（快照含 pad，活捕不扣）
        this.heroAnim.overlayY = ui.px2vp(titleRect.top) - originTopVp - rectPadVp;
        this.heroAnim.overlayWidth = ui.px2vp(titleRect.width);
        // A4：落位端盒高=源卡标题盒高（与卡内标题文字重合后交还，消除垂直高差）
        this.heroAnim.overlayHeight = ui.px2vp(titleRect.height);
        this.heroAnim.overlayFontSize = bodyFont;
        this.heroAnim.overlayFontColor = textPrimary;
      } else {
        this.heroAnim.overlayOpacity = 0;
      }
    });
  }

  /** 横屏停留分栏判定（md-landscape 分栏修复）：宽>高 且断点 ≥ md——
   *  手机横屏停留（B 档浏览态）vp 宽约 788 落 md 档，旧判定 isExpanded() 不含
   *  md，横屏停留呈"封面+白带+空内容"残页；md-landscape 亦走左右分栏（视频
   *  左 + 信息流右），sm 横屏两列过窄仍上下堆叠 */
  private isSplitLayout(): boolean {
    const win: WindowSizeInfo = this.windowSize;
    return win.windowWidthVp > win.windowHeightVp &&
      (win.isExpanded() || win.isMedium());
  }

  /** 【B5】冻结期横屏 pillarbox 判定：窗口横屏且满宽 16:9 视频带纵向溢出
   *  （winH×16/9 < winW）——手机横屏窗口（2760×1256）冻结堆叠的满宽带高
   *  1552px 超窗 296px 底部被裁，PUSH 飞行源与全屏落位的视频 fit 不一致
   *  （飞行中画面纵横比连续变化，观感"二段收缩"）。pillarbox 化后视频带 =
   *  窗高 16:9 水平居中、两侧黑边：飞行起止视频 fit 恒等、内容 rect 全程
   *  不动，转场 = 纯黑框展开/收拢的单段连续缩放。平板横屏（2880×1920）
   *  winH×16/9=3413 > winW 不触发，满宽堆叠原样（进全屏等待期平板满宽
   *  E2b 契约不变）；冻结竖屏（含退向旋转冻结）不触发 */
  private frozenLandscapePillar(): boolean {
    if (!this.layoutFrozen) {
      return false;
    }
    const win: WindowSizeInfo = this.windowSize;
    return win.windowWidthVp > win.windowHeightVp && win.windowHeightVp > 0 &&
      win.windowHeightVp * 1.7778 < win.windowWidthVp;
  }

  /** 【B5】冻结 pillarbox 态播放区宽 vp（窗高 × 16:9，钳制 ≤ 窗宽防退化几何） */
  private frozenPillarWidthVp(): number {
    const win: WindowSizeInfo = this.windowSize;
    return Math.min(win.windowWidthVp, win.windowHeightVp * 1.7778);
  }

  /** 【B5】播放区宽：冻结横屏 pillarbox 态取居中带宽（Column 默认水平居中），
   *  其余态满宽——渲染层与 expandSourceRect/playAreaRectPx 兜底同几何，
   *  飞行源 rect = 等待末帧所见 */
  private playerAreaWidth(): Length {
    return this.frozenLandscapePillar() ? this.frozenPillarWidthVp() : '100%';
  }

  /** 标题落位矩形（DetailHeader 内标题位置）——【问题②修复】三路取值：
   *  - titleTargetRest：POP 起飞/淡出用，本页静止态活捕真实矩形（交接零跳变）
   *  - titleTargetPush：PUSH 落位用，结构算术 + 活捕行高修正 y（变换免疫）
   *  - titleTargetArithmetic：公共算术兜底（组件不可达时） */
  private titleTargetRest(ui: UIContext, W0: number, spaceMd: number): TitleTarget {
    // 静止态（盒 scale=1、translate=0、'100%'）：窗口坐标=内容坐标，活捕即精确
    // ——图标占位/行内垂直居中/分栏列宽全部天然吸收
    const cap: RectPx | null = HeroRectUtils.captureRectPx(ui, `detail-title-${this.hid}`);
    if (cap !== null) {
      const target: TitleTarget = new TitleTarget();
      target.x = ui.px2vp(cap.left);
      target.y = ui.px2vp(cap.top);
      target.w = ui.px2vp(cap.width);
      target.h = ui.px2vp(cap.height);
      if (target.x >= 0 && target.y >= 0 && target.w > 0 && target.w <= W0) {
        return target;
      }
    }
    return this.titleTargetArithmetic(W0, spaceMd);
  }

  /** PUSH 落位终点：80ms 闭包时本页盒已渲染初态（scale<1 缩放中）——getRectangleById
   *  的窗口坐标在祖先变换下语义不确定，仅取变换无关的组件自身高度修正 y 的行内
   *  垂直居中偏移（(28−标题行高)/2，28=返回图标行高）；x/w 用结构算术
   *  （DetailHeader 布局结构恒定，算术即精确）；活捕失败回退纯算术 */
  private titleTargetPush(ui: UIContext, W0: number, spaceMd: number): TitleTarget {
    const target: TitleTarget = this.titleTargetArithmetic(W0, spaceMd);
    const cap: RectPx | null = HeroRectUtils.captureRectPx(ui, `detail-title-${this.hid}`);
    if (cap !== null) {
      // 组件自身 size 不含祖先缩放（变换无关），高度即真实行高
      target.y = target.y + (28 - ui.px2vp(cap.height)) / 2;
      // A4：覆盖层盒高同步取真实行高（PUSH 落位端与真实标题重合）
      target.h = ui.px2vp(cap.height);
    }
    return target;
  }

  /** 算术兜底（内容区 vp）：DetailHeader Row 实际结构 = 左 padding space_md + 返回
   *  图标 24 宽 + Row 间距 space_sm + 标题（layoutWeight(1) 撑满余宽）。
   *  【问题②】旧算术 backOffset=40+space_sm 把图标内边距重复计入（图标
   *  .width(24) 的 padding 在盒内不外占，box 就 24 宽），终点偏右 16vp——平板
   *  实测 1946px vs 真实 1874px 的主成分之一，按真实占位 24 修正 */
  private titleTargetArithmetic(W0: number, spaceMd: number): TitleTarget {
    const target: TitleTarget = new TitleTarget();
    const spaceSm: number = HeroTransition.resNumber(this.getUIContext(), $r('app.float.space_sm'), 8);
    const backOffset: number = 24 + spaceSm;
    // 大屏横屏与 md-landscape 横屏停留均走左右分栏（标题在右列顶部）；
    // 竖屏大屏与小屏同为上下堆叠
    const sideBySide: boolean = this.isSplitLayout();
    if (sideBySide) {
      const colW: number = this.windowSize.breakpoint === WidthBreakpoint.XL ? W0 * 0.62 : W0 * 0.55;
      target.x = colW + spaceMd + backOffset;
      // 分栏右列顶部垫状态栏高（DetailHeader 让开时钟），标题随之下移
      target.y = this.statusBarVp() + spaceMd;
      target.w = W0 - colW - spaceMd * 2 - backOffset;
    } else {
      target.x = spaceMd + backOffset;
      target.y = W0 / 1.7778 + spaceMd;
      target.w = W0 - spaceMd * 2 - backOffset;
    }
    // A4：算术兜底行高 24≈单行 17fp 标题行高（TitleTarget 字段默认，显式自证）
    target.h = 24;
    return target;
  }

  // ==================== 半屏 → 全屏 ====================

  /** 全屏是否需要先旋转窗口（§3.1）：窗口高>宽（竖屏窗口：手机竖屏/平板竖屏/折叠
   *  展开竖持）且非半折叠态（笔记本/帐篷态几何不稳不旋转）→ push 前先经 arbiter
   *  转横屏；横屏/方形窗口纯缩放直进 */
  private needsRotateForFullscreen(): boolean {
    return this.windowSize.windowHeightVp > this.windowSize.windowWidthVp &&
      !HeroTransition.isHalfFolded();
  }

  /** 半屏 → 全屏（§3.1 先旋转后展开）：竖屏窗口先经 OrientationArbiter.requestEnter
   *  转横屏（LANDSCAPE + 几何稳定确认；粘性容器超时重置重发一次，再超时按当前几何
   *  降级推进保底可用），再采集 rect 组 PlayerExpandParam 走 Player 同几何纯缩放
   *  转场；采集失败降级普通跳转（两条路径均同帧移交节点宿主）；自由窗形态先
   *  maximize(ENTER_IMMERSIVE) 进全屏沉浸再采集（R6） */
  private async enterFullscreen(): Promise<void> {
    // 旋转提速观测：点击锚点（t=0，进出全屏耗时分解基准）
    hilog.info(0x0000, 'TucaoDetail', 'enterFullscreen: clicked');
    this.stopControlsTimer();
    this.stopNodeRestoreTimer();
    this.stopExpandAutoRestoreTimer();
    // 控制层随冻结收起（§2.5-10，freezeDetailLayoutForEnter 内执行）：等待
    // 视觉=纯视频带；节点移交时随宿主自然卸载，无残留闪烁
    // 【旋转提速·前移】非自由窗：requestImmersive 恒 no-op 且点击瞬间几何稳定
    // （旋转事件系统侧 52-203ms 后才到）——方向记忆、下方冻结、LANDSCAPE 请求
    // 全部前移到点击瞬间同帧执行（LANDSCAPE 较原时序提前采集/起播等前置杂项，
    // 并省 getLastWindow IPC 串行段）；自由窗保持 maximize 后原时序（几何经
    // maximize 变化，方向记忆与旋转判定必须在其后）
    const fastEnter: boolean = !WindowModeHelper.isFloating();
    let enterGen: number = -1;
    if (fastEnter) {
      this.expandFromPortrait = this.needsRotateForFullscreen();
      if (this.expandFromPortrait) {
        this.freezeDetailLayoutForEnter();
        this.enterFullscreenWaiting = true;
        enterGen = OrientationArbiter.beginEnter();
      }
    } else {
      // R6 自由窗：全屏按钮把悬浮窗 maximize 成全屏沉浸（非自由窗 no-op）；
      // 等窗口几何稳定后再采集源矩形，转场目标即最大化后的真实布局
      await WindowModeHelper.requestImmersive();
      this.expandFromPortrait = this.needsRotateForFullscreen();
      if (this.expandFromPortrait) {
        this.freezeDetailLayoutForEnter();
        this.enterFullscreenWaiting = true;
      }
    }
    const ui: UIContext = this.getUIContext();
    const clickRect: RectPx | null = HeroRectUtils.captureRectPx(ui, `player-area-${this.hid}`);
    // 封面态进全屏：自动起播（对齐安卓语义；仅本页视频就绪，防 VM 残留上一视频）
    if (!this.vm.started && this.videoLoaded()) {
      this.vm.startPlay();
    }
    // §3.1 步骤 3-5：竖屏窗口先旋转后展开。等待期冻结下方 Tab 区（窗口转横屏触发
    // MD 断点重排版，堆叠布局溢出裁切）；横屏/方形窗口纯缩放直进无等待。
    // 【任务⓪方向记忆】以旋转前（当前）窗口形态记录来源：竖屏来源 POP 落位后
    // 自动阶梯归还；横屏来源（B 档停留态再进）保持停留
    // 【B7】旋转两轮超时降级标记：按未确认几何强推自定义转场会令窗口变更与
    // 转场起帧重叠（框架 double-arm 转场超时，残臂再触发动画的根源）——
    // 降级为普通跳转（无自定义转场），保底可用
    let degradeSkipFlight: boolean = false;
    if (this.expandFromPortrait) {
      let landscapeReady: boolean;
      if (enterGen >= 0) {
        // 快速路径：LANDSCAPE 已于点击瞬间发出（beginEnter），此处仅补几何
        // 稳定确认（含粘性兜底）——等待期与冻结期和原时序完全重叠
        landscapeReady = await OrientationArbiter.awaitEnterStable(enterGen);
      } else {
        // 自由窗 maximize 后判定旋转债 / 非自由窗 beginEnter 缓存缺失回退：
        // 整体等待式（内部 getLastWindow 兜底），时序与拆分前一致
        landscapeReady = await OrientationArbiter.requestEnter();
      }
      this.enterFullscreenWaiting = false;
      if (this.pageTornDown) {
        // 等待期间页面销毁（快速双返回）：方向归还已由 aboutToDisappear 发起，不再推进
        return;
      }
      if (!landscapeReady) {
        // 粘性容器两轮超时（罕见）：解冻 + 降级普通跳转（下方 degradeSkipFlight 支路），
        // 不再按未确认几何强推飞行
        hilog.warn(0x0000, 'TucaoDetail', 'enterFullscreen: landscape unconfirmed, degrade to plain jump');
        this.unfreezeDetailLayout();
        degradeSkipFlight = true;
      }
      // 竖屏来源（手机 + 平板/折叠统一）：【问题B·§2.4 + 退向两段式治理】冻结
      // 贯穿会话——不在等待末/飞行中段解冻（原 B7 scheduleUnfreezeAfterMorph
      // 已随"退向必回竖屏"方向记忆废弃：解冻建出的横屏分栏只会成为 POP 落位的
      // 中间态）。横屏窗口中冻结态恒为堆叠结构（视频带满宽贴顶+折叠线下骨架
      // 不可见），等待期/飞行周边/全屏停留期/退向旋转期全程视觉只剩视频；POP
      // 活捕 = 冻结视频带（盒飞回带原位，落位帧=骨架非分栏）；解冻由退向竖屏
      // 稳定后 @Monitor 300ms 稳定拍接管（push 后 ForEnter 清零），restoreNodeHost
      // 重挂 20s 兜底 + 横屏落定检测
    } else {
      // 非旋转进入（B-档横屏停留再进 / 平板纯缩放）：hold 态残留冻结归一为
      // 现状（POP 活捕=分栏面板，落位无缝）
      if (this.layoutFrozen) {
        this.unfreezeDetailLayout();
      }
    }
    // §3.6 转场静默期（"more than once" 根因治理）：进场前预隐藏三栏，使 Player
    // willShow 的栏关闭退化为无变化空调用；再静默一拍等旋转布局冲刷与栏 inset
    // 事件全部落定——任何窗口变动不得与自定义转场起帧重叠（实测重叠会令框架
    // double-arm 转场超时，我方合法 finish 后超时残臂仍触发并打出错误日志）。
    // 【旋转提速】300→150：静默前几何已过 150ms 稳定拍（两采样一致），旋转布局
    // 冲刷已完成；静默仅需覆盖本行 setPlayerEntryBars 触发的栏 inset 事件流
    // （实测单事件帧级落定），150ms ≈ 9 帧余量充足；实测进向点击→起飞 -350ms
    this.setPlayerEntryBars(true);
    await new Promise<void>((resolve: (value: void) => void): void => {
      setTimeout((): void => {
        resolve();
      }, 150);
    });
    if (this.pageTornDown) {
      // 静默期内页面销毁（未 push）：三栏已隐藏须就地恢复（willShow 兜底不会发生）
      this.setPlayerEntryBars(false);
      return;
    }
    if (degradeSkipFlight || clickRect === null) {
      this.nodeAway = this.vm.started;
      this.nodeHost = undefined;
      // 降级普通跳转（【B7】旋转超时未确认几何 / 【问题B·§2.5-5 扩展】采集
      // 失败）：与过渡路径同款收尾冻结会话旗标（ForEnter 清零武装 @Monitor
      // 退向支路；安全兜底移交退向重挂）——否则该路径 @Monitor 被静默、
      // 返回仅靠 20s 兜底
      this.layoutFrozenForEnter = false;
      this.stopFreezeSafetyTimer();
      Router.goPlayer(this.hid);
      return;
    }
    // §3.1 步骤 6：源矩形以旋转后布局为真（同几何飞行的起点必须在当前窗口坐标系）
    const sourceRect: RectPx = this.expandSourceRect(ui, clickRect);
    // param 窗口几何取当前实时值（旋转后）：Player 飞行初态/盒初态基准，
    // 监听未就绪回退点击时刻值（先旋转后展开下两者同几何，等价）
    const expandParam: PlayerExpandParam = new PlayerExpandParam();
    expandParam.sourceLeftPx = sourceRect.left;
    expandParam.sourceTopPx = sourceRect.top;
    expandParam.sourceWidthPx = sourceRect.width;
    expandParam.sourceHeightPx = sourceRect.height;
    expandParam.sourceHid = this.hid;
    // 【B5】冻结横屏 pillarbox 会话标记：push 时仍冻结（手机竖屏来源）→ 置位，
    // Player POP 垫底纯黑对齐冻结详情页；平板/横屏停留/降级路径未冻结 → 不置位
    expandParam.frozenLandscape = this.frozenLandscapePillar();
    expandParam.windowWidthPx = Math.round(ui.vp2px(this.contentWidthVp()));
    expandParam.windowHeightPx = Math.round(ui.vp2px(this.contentHeightVp()));
    expandParam.onNodeReturn = (): void => {
      this.restoreNodeHost();
    };
    this.nodeAway = this.vm.started;
    this.nodeHost = undefined;
    // 【问题B·§2.5-5】push 后收尾：进向等待旗标退位——@Monitor 退向解冻支路
    // 武装（push 后窗口恒横屏，armed 亦不误触发；会话中被覆盖期收到竖屏几何
    // 事件（折叠/展开/外部归还）同样解冻预建内容，无害）；冻结安全兜底停表，
    // 移交退向 restoreNodeHost 重挂（阶梯期覆盖 + 旋转彻底失效 20s 终端兜底）
    this.layoutFrozenForEnter = false;
    this.stopFreezeSafetyTimer();
    Router.goPlayerWithTransition(this.hid, expandParam);
  }

  /** Player 进场三栏窗口开关（与 Index.toggleSystemBars 同源三调用；进场前预隐藏
   *  是 §3.6 静默期的另一半：Player willShow 的真实关闭调用因此退化为无变化空调用，
   *  转场窗口内不再产生 inset 事件） */
  private setPlayerEntryBars(hidden: boolean): void {
    const context = AppContextHolder.get();
    if (context === null) {
      return;
    }
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      mainWindow.setSpecificSystemBarEnabled('status', !hidden).catch((_err: BusinessError): void => {
        // 失败仅告警：进场侧 Index willShow 幂等重试自愈；中断侧下次导航自愈
        hilog.warn(0x0000, 'TucaoDetail', 'setPlayerEntryBars status failed');
      });
      mainWindow.setSpecificSystemBarEnabled('navigation', !hidden).catch((_err: BusinessError): void => {
        hilog.warn(0x0000, 'TucaoDetail', 'setPlayerEntryBars navigation failed');
      });
      mainWindow.setSpecificSystemBarEnabled('navigationIndicator', !hidden).catch((_err: BusinessError): void => {
        hilog.warn(0x0000, 'TucaoDetail', 'setPlayerEntryBars indicator failed');
      });
    }).catch((_err: BusinessError): void => {
      hilog.warn(0x0000, 'TucaoDetail', 'setPlayerEntryBars getLastWindow failed');
    });
  }

  /** 转场源矩形（旋转后布局为真）：活捕当前节点优先（播放器面板不冻结，随旋转
   *  重排版到横屏真实位置，活捕即真相）；活捕失败按当前窗口布局真值兜底——
   *  与 DetailContent 同判定（isSplitLayout）：lg/xl 与 md-landscape 横屏分栏
   *  左列（XL 62%/其余 55%）内 16:9 面板居中；其余（竖屏大屏/小屏）上下堆叠：
   *  播放区恒满宽贴顶 16:9——比点击时刻快照更贴真实落位；
   *  窗口几何缺失回退点击时刻快照 */
  private expandSourceRect(ui: UIContext, clickRect: RectPx): RectPx {
    const liveRect: RectPx | null = HeroRectUtils.captureRectPx(ui, `player-area-${this.hid}`);
    if (liveRect !== null && liveRect.width > 0 && liveRect.height > 0) {
      return liveRect;
    }
    const winWVp: number = this.windowSize.windowWidthVp;
    const winHVp: number = this.windowSize.windowHeightVp;
    if (winWVp <= 0 || winHVp <= 0) {
      return clickRect;
    }
    const result: RectPx = new RectPx();
    const winWpx: number = ui.vp2px(winWVp);
    const winHpx: number = ui.vp2px(winHVp);
    if (this.isSplitLayout() && !this.layoutFrozen) {
      // 横屏分栏（md-landscape）：左列宽度 + 列内 16:9 面板（受窗高
      // 约束）双向居中。
      // 【问题B·§2.4】冻结期活捕失败也按堆叠真相兜底（与 DetailContent 同门控）：
      // 满宽贴顶 16:9 视频带，转场起点=等待末帧所见
      const colWpx: number = winWpx *
        (this.windowSize.breakpoint === WidthBreakpoint.XL ? 0.62 : 0.55);
      const panelWpx: number = Math.min(colWpx, winHpx * 1.7778);
      const panelHpx: number = panelWpx / 1.7778;
      result.left = Math.round((colWpx - panelWpx) / 2);
      result.top = Math.round((winHpx - panelHpx) / 2);
      result.width = Math.round(panelWpx);
      result.height = Math.round(panelHpx);
    } else if (this.frozenLandscapePillar()) {
      // 【B5】冻结横屏 pillarbox 兜底：与渲染层同几何（窗高 16:9 带水平居中、
      // 两侧黑边）——活捕失败时飞行源 rect 仍 = 等待末帧所见
      const bandWpx: number = Math.min(winWpx, winHpx * 1.7778);
      result.left = Math.round((winWpx - bandWpx) / 2);
      result.top = 0;
      result.width = Math.round(bandWpx);
      result.height = Math.round(winHpx);
    } else {
      // 上下堆叠：播放区恒满宽贴顶 16:9（手机横屏 MD 堆叠溢出裁切同此真相）
      result.left = 0;
      result.top = 0;
      result.width = Math.round(winWpx);
      result.height = Math.round(winWpx / 1.7778);
    }
    return result;
  }

  /** POP 落位内容裁切基准：播放区矩形（px，窗口坐标）。【A2】落位数学把播放区
   *  Cover 映射进卡片可见窗（旧数学整页等比落位，卡比 16:9 更"高"时卡内露出
   *  播放区下方的标题/信息条）。活捕优先（POP 起点静止态，盒 scale=1 无变换，
   *  采集即真值）；活捕失败按 DetailContent 同门控算术兜底（冻结期恒堆叠满宽
   *  贴顶 16:9，非冻结横屏分栏=左列内 16:9 面板双向居中，与 expandSourceRect 同式） */
  private playAreaRectPx(ui: UIContext): RectPx {
    const liveRect: RectPx | null = HeroRectUtils.captureRectPx(ui, `player-area-${this.hid}`);
    if (liveRect !== null && liveRect.width > 0 && liveRect.height > 0) {
      return liveRect;
    }
    const result: RectPx = new RectPx();
    const winWpx: number = ui.vp2px(this.contentWidthVp());
    const winHpx: number = ui.vp2px(this.contentHeightVp());
    if (this.isSplitLayout() && !this.layoutFrozen) {
      // 横屏分栏（md-landscape）：左列宽度 + 列内 16:9 面板双向居中
      const colWpx: number = winWpx *
        (this.windowSize.breakpoint === WidthBreakpoint.XL ? 0.62 : 0.55);
      const panelWpx: number = Math.min(colWpx, winHpx * 1.7778);
      result.left = Math.round((colWpx - panelWpx) / 2);
      result.top = Math.round((winHpx - panelWpx / 1.7778) / 2);
      result.width = Math.round(panelWpx);
      result.height = Math.round(panelWpx / 1.7778);
    } else if (this.frozenLandscapePillar()) {
      // 【B5】冻结横屏 pillarbox 兜底：与渲染层同几何（窗高 16:9 带水平居中），
      // hero POP 落位裁切基准与冻结页所见一致
      const bandWpx: number = Math.min(winWpx, winHpx * 1.7778);
      result.left = Math.round((winWpx - bandWpx) / 2);
      result.top = 0;
      result.width = Math.round(bandWpx);
      result.height = Math.round(winHpx);
    } else {
      // 上下堆叠：播放区恒满宽贴顶 16:9
      result.left = 0;
      result.top = 0;
      result.width = Math.round(winWpx);
      result.height = Math.round(winWpx / 1.7778);
    }
    return result;
  }

  // ==================== 坐标/尺寸辅助 ====================

  /** 内容区宽 vp（hero 盒坐标系 W0） */
  private contentWidthVp(): number {
    const w: number = this.windowSize.windowWidthVp;
    return w > 0 ? w : 360;
  }

  /** 盒空间高 vp（hero 盒坐标系 H0）：沉浸路由（§3.3）下详情页恒 pad=0，
   *  盒空间即整窗空间（全断点一致；密度未就绪回退 640） */
  private contentHeightVp(): number {
    const h: number = this.windowSize.windowHeightVp;
    return h > 0 ? h : 640;
  }

  private statusBarVp(): number {
    return this.getUIContext().px2vp(this.windowSize.statusBarHeightPx);
  }

  // ==================== 顶部沉浸（§3.3 沉浸路由） ====================

  /** 续播提示条顶部避让 vp：播放区顶着窗口顶（沉浸路由 pad=0），先让开状态栏
   *  时钟再留常规间距（全断点一致） */
  private resumeTipTopVp(): number {
    const spaceMd: number = HeroTransition.resNumber(this.getUIContext(), $r('app.float.space_md'), 12);
    return this.statusBarVp() + spaceMd;
  }

  /** 半屏控制层顶部内边距 vp：控制层顶栏（含返回钮）让开状态栏时钟区域（全断点
   *  一致）；控制层组件不在本页修改范围（文件边界），在宿主侧整体下垫——顶栏落于
   *  时钟之下，底栏仍贴合播放区底边（内层 '100%' 随 padding 收缩） */
  private controlTopInsetVp(): number {
    return this.statusBarVp();
  }

  /** 沉浸态状态栏前景同步（§3.3）：沉浸路由下详情页可见即视频/品牌栏垫在时钟
   *  之下（全断点、含横屏停留态），前景恒切白字保证可读；页面不可见时按深浅色
   *  恢复全局策略（与 EntryAbility.applySystemBarColors 同式）。
   *  只动 statusBarContentColor，不碰 navigationBar*（小白条前景归全局策略管） */
  private syncStatusBarTint(): void {
    const shouldTint: boolean = this.pageVisible;
    if (shouldTint === this.statusBarTinted) {
      return;
    }
    this.statusBarTinted = shouldTint;
    const context = AppContextHolder.get();
    if (context === null) {
      return;
    }
    const dark: boolean = GlobalState.colorModeState().isDark;
    const contentColor: string = shouldTint ? '#FFFFFF' : (dark ? '#FFFFFF' : '#000000');
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      mainWindow.setWindowSystemBarProperties({
        statusBarContentColor: contentColor
      }).catch((err: BusinessError): void => {
        hilog.warn(0x0000, 'TucaoDetail', 'setStatusBarContentColor failed: %{public}s', JSON.stringify(err));
      });
    }).catch((err: BusinessError): void => {
      hilog.warn(0x0000, 'TucaoDetail', 'getLastWindow for tint failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 断点切换（折叠展开/分屏拖拽）：沉浸形态随之开关，状态栏前景即时同步 */
  @Monitor('windowSize.breakpoint')
  onWindowBreakpointChanged(): void {
    this.syncStatusBarTint();
  }

  /** 旋转窗口几何变化：
   *  【B8】退向旋转首拍冻结（平板/折叠）：本回调与 EntryAbility 同步写 @Trace
   *  同拍触发、先于新几何 measure——exitRotationWatch 武装期（POP 落位起）窗口
   *  转竖屏的第一个几何拍立即冻结，首个竖屏帧即骨架（规避旋转落定全量 build
   *  风暴在可见页面上的卡顿）；触发即解除监视（一次性，之后旋转回归常规浏览
   *  行为），冻结安全兜底同拍挂上，解冻落入下方既有支路
   *  【问题B·§2.4】退向解冻主通道——ForEnter 旗标在 push 后清零（§2.5-5），
   *  本支路自全屏会话起全程 armed：POP 落位阶梯归还竖屏（PORTRAIT 生效）→
   *  300ms 稳定拍后解冻一次性 build 真实内容；会话中被覆盖期收到竖屏几何
   *  事件（折叠/展开/外部归还）同样解冻预建，无害。进向等待期仍被 ForEnter
   *  静默（窗口自竖屏出发，几何事件会被误判"已回竖屏"提前解冻） */
  @Monitor('windowSize.windowWidthVp', 'windowSize.windowHeightVp')
  onWindowGeometryChanged(): void {
    const win: WindowSizeInfo = this.windowSize;
    if (!this.layoutFrozen && this.exitRotationWatch &&
      win.windowWidthVp > 0 && win.windowHeightVp > win.windowWidthVp) {
      this.exitRotationWatch = false;
      this.layoutFrozen = true;
      this.armFreezeSafety();
      hilog.info(0x0000, 'TucaoDetail', 'exit rotation first beat: freeze before portrait measure');
    }
    if (!this.layoutFrozen || this.layoutFrozenForEnter) {
      return;
    }
    if (win.windowHeightVp > win.windowWidthVp) {
      this.scheduleUnfreezeOnPortrait();
    }
  }

  /** 矩形与当前视口是否相交（窗口 px 坐标系；视口信息缺失时保守放行） */
  private rectIntersectsViewport(rect: RectPx): boolean {
    const winWVp: number = this.windowSize.windowWidthVp;
    const winHVp: number = this.windowSize.windowHeightVp;
    if (winWVp <= 0 || winHVp <= 0) {
      return true;
    }
    const ui: UIContext = this.getUIContext();
    const winW: number = ui.vp2px(winWVp);
    const winH: number = ui.vp2px(winHVp);
    return rect.left < winW && rect.left + rect.width > 0 &&
      rect.top < winH && rect.top + rect.height > 0;
  }

  /** 转场入口参数是否可信（封面/标题矩形均在视口内） */
  private heroParamInView(param: HeroCardParam): boolean {
    return this.rectIntersectsViewport(param.coverRect) &&
      this.rectIntersectsViewport(param.titleRect);
  }

  /** 当前 VM 数据是否属于本页视频（VM 单例：换视频加载窗口期残留上一视频） */
  private videoLoaded(): boolean {
    const video: Video | null = this.vm.video;
    return video !== null && video.hid === this.hid;
  }

  /** 播放区封面：本页视频封面；加载窗口期回落转场入口封面（VM 单例残留上一视频） */
  private coverUrl(): string {
    const video: Video | null = this.vm.video;
    if (video !== null && video.hid === this.hid) {
      return video.thumb;
    }
    const heroParam: HeroCardParam | undefined = this.heroParam;
    return heroParam !== undefined ? heroParam.coverUrl : '';
  }

  /** 评论参数：视频 typeid（本页视频未就绪为 0，防 VM 残留上一视频） */
  private videoTypeid(): number {
    const video: Video | null = this.vm.video;
    return video !== null && video.hid === this.hid ? video.typeid : 0;
  }

  /** 评论参数：视频 hid（hid 守卫后恒等于路由参数） */
  private videoHid(): string {
    return this.hid;
  }

  /** 页面标题：本页视频标题；加载窗口期回落转场入口标题（hero 飞行标题先行渲染） */
  private heroTitle(): string {
    const video: Video | null = this.vm.video;
    if (video !== null && video.hid === this.hid) {
      return video.title;
    }
    const heroParam: HeroCardParam | undefined = this.heroParam;
    if (heroParam !== undefined) {
      return heroParam.title;
    }
    return '';
  }

  // ==================== 布局 ====================

  build() {
    NavDestination() {
      // 顶部沉浸（定案）：沉浸路由（Index 沉浸集）下壳层顶部避让恒为 0，
      // NavDestination 内容区自窗口顶 [0,0] 铺满整窗——根 Stack 无需任何补偿
      // （高度 '100%' 即整窗高），视频区顶边贴合窗口物理顶、状态栏透明浮于
      // 视频之上（前景色归 syncStatusBarTint）。历史方案 A 的根负 margin 与
      // 壳层 pad 互抵对（双重补偿、脆弱耦合）已随  拆除——注意：a11y dump
      // 对伸入状态栏区的内容统一裁剪报 top≈137px，验证布局真值须以 ▶ 中心
      // 数学或截图像素采样为准，勿信 dump 顶带读数
      Stack({ alignContent: Alignment.Top }) {
        if (this.heroParam !== undefined) {
          this.HeroContent()
        } else {
          this.DetailContent()
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    // hero 飞行透出列表页（盒自身提供页底色）；普通进入保持页底色
    .backgroundColor(this.heroParam !== undefined ? Color.Transparent : $r('app.color.page_background'))
    // 方向归 OrientationArbiter 单通道（§3.5）：声明式 preferredOrientation 已拆——
    // 框架销毁时自动释放注入的 UNSPECIFIED 噪声随之消失（曾打断归还序列）
    .onShown((): void => {
      // 手机沉浸：状态栏前景切白（视频深色底垫在时钟下）
      this.pageVisible = true;
      this.syncStatusBarTint();
      // 从全屏返回：POP 回调异常时兜底恢复节点宿主（正常路径 onNodeReturn 已恢复并取消）
      if (this.vm.started && this.nodeHost === undefined) {
        this.startNodeRestoreTimer();
      }
      this.syncSurfaceId();
      // 【B8】冻结残留防御：覆盖期间错过几何事件（旋转冻结触发后被覆盖/阶梯
      // 被取消）时 onShown 补一拍解冻调度（回调内复查竖屏，横屏静默等下一次
      // 几何事件；20s 安全兜底仍在）——防再现时带出过期骨架
      if (this.layoutFrozen && !this.layoutFrozenForEnter) {
        this.scheduleUnfreezeOnPortrait();
      }
      // 窗口方向归还不在此处重申：onShown 触发时机相对 POP 飞行无契约保证——
      // B 档两段式返回下手机 POP 落位本就不归还（横屏停留=横屏浏览态），
      // 归还唯一触发点=aboutToDisappear（离开本页时发起阶梯，页面销毁后 arbiter
      // 静态序列继续收敛）；节点宿主兜底仍由上方 700ms 计时器负责
      // 从全屏返回：重置画面缩放（半屏画面框固定 16:9，裁剪/变形模式不适用）
      this.vm.setScaleMode('fit');
      // 碰一碰分享注册（直发通道）：页面可见才监听，轻碰对端即分享当前视频
      // （播放中/未播放均生效；能力不支持时内部静默跳过）
      KnockShareController.getInstance().listen((): Video | null => this.vm.video);
    })
    .onHidden((): void => {
      this.stopControlsTimer();
      this.stopNodeRestoreTimer();
      // 任务⓪：被新页面覆盖（如落位后快速点开相关视频）则取消待发的自动归还
      // ——方向债随新页面生命周期走（§3.6：不得在他页转场窗口附近做窗口变动）
      this.stopExpandAutoRestoreTimer();
      // 【B8】解除退向旋转监视：覆盖期间传感器旋转不再冻结本页（不可见页面
      // 冻结无意义，再现时会带出过期骨架闪帧）
      this.exitRotationWatch = false;
      this.showControls = false;
      // 沉浸着色恢复：离开可见态交还全局深浅色策略（被覆盖页/弹出均适用）
      this.pageVisible = false;
      this.syncStatusBarTint();
      // 碰一碰分享注销：被覆盖（全屏页/相关视频等）即停止监听，防覆盖态误触发
      KnockShareController.getInstance().unlisten();
    })
    .onReady((context: NavDestinationContext): void => {
      const pageId: string = context.navDestinationId ?? '';
      if (pageId.length === 0) {
        return;
      }
      this.pageId = pageId;
      if (this.heroParam === undefined) {
        return;
      }
      const callback: HeroAnimateCallback = new HeroAnimateCallback();
      callback.animation = (isPush: boolean): void => {
        this.runHeroAnimation(isPush);
      };
      // 注册超时 = 唯一合法 finish（契约见 HeroAnimateCallback）：弹簧大距离稳定可超
      // 1s，80 推迟 + 稳定时长 ≈ 1.1s，1250 留余量且仍小于 markSource 1600ms 自清窗
      callback.timeout = 1250;
      HeroTransition.register(pageId, callback);
    })
  }

  /** hero 模式：三层盒结构（根 Stack(Top) > 盒(缩放/裁剪/圆角/背景) > 内容冻结层）+ 飞行标题覆盖层 */
  @Builder
  HeroContent() {
    Stack({ alignContent: Alignment.Top }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.DetailContent()
        }
        .width(this.heroAnim.contentWidth)
        .height(this.heroAnim.contentHeight)
        // A2：POP 落位内容裁切——内容层随飞行平移，播放区 Cover 映射进卡片窗
        .translate({
          x: this.heroAnim.contentTranslateX,
          y: this.heroAnim.contentTranslateY
        })
      }
      .width(this.heroAnim.clipWidth)
      .height(this.heroAnim.clipHeight)
      .scale({
        x: this.heroAnim.scaleValue,
        y: this.heroAnim.scaleValue
      })
      .translate({
        x: this.heroAnim.translateX,
        y: this.heroAnim.translateY
      })
      .borderRadius(this.heroAnim.radius)
      .backgroundColor(this.heroAnim.navBgColor)
      .clip(true)
      .opacity(this.heroAnim.boxOpacity)

      // 飞行标题覆盖层（卡片标题 → DetailHeader 标题位；字色随飞行在两端点间插值）
      // 常挂载 + 透明度门控：同帧「建节点 + animateTo」时 fontSize 无前帧渲染态、
      // 插值失效（POP 末段标题停留大字号缺陷的根因）；常挂载保证任意时刻有前帧可插值。
      // hitTestBehavior(None)：常挂载后静止态（透明）不得拦截 DetailHeader 返回钮命中
      Text(this.heroTitle())
        .fontSize(this.heroAnim.overlayFontSize)
        .fontColor(this.heroAnim.overlayFontColor)
        // A4：maxLines(2) 对齐源卡标题行数上限（原 1 行致 2 行卡标起飞/落位
        // 瞬间行数跳变）；盒高随飞行插值（卡片端盒高 → 标题栏端行高），
        // 内容在盒内垂直居中与源端同律——长文字在标题栏端被裁剪为可接受边角
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .height(this.heroAnim.overlayHeight)
        .position({
          x: this.heroAnim.overlayX,
          y: this.heroAnim.overlayY
        })
        .width(this.heroAnim.overlayWidth)
        .opacity(this.heroAnim.overlayVisible ? this.heroAnim.overlayOpacity : 0)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
  }

  /** 页面内容（hero 模式下作为盒内冻结内容；普通模式直接挂 NavDestination） */
  @Builder
  DetailContent() {
    Stack() {
      // 大屏横屏与 md-landscape 横屏停留（B 档浏览态）均走左右分栏；
      // 竖屏大屏（平板竖持）与小屏同为上下堆叠，播放器撑满宽 16:9 +
      // 标题/简介评论在下，避免竖屏分栏两列过窄。
      // 【问题B·§2.4】冻结期强制堆叠结构：横屏窗口中堆叠=视频带满宽贴顶 +
      // 折叠线下骨架（窗口裁掉底部），全屏会话全程只见视频——消灭中间态①②
      // 的结构基础（冻结贯穿期间不再呈现横屏分栏浏览态）
      if (this.isSplitLayout() && !this.layoutFrozen) {
        // ===== 大屏横屏分栏：左播放器右详情 =====
        Row() {
          Column() {
            this.PlayerArea()
          }
          .width(this.windowSize.breakpoint === WidthBreakpoint.XL ? '62%' : '55%')
          .height('100%')
          .backgroundColor(Color.Black)
          .justifyContent(FlexAlign.Center)

          Column() {
            this.DetailHeader()
            this.DetailTabs()
          }
          .layoutWeight(1)
          .height('100%')
          // 沉浸路由 pad=0：右列自窗口顶布局，顶部垫状态栏高让 DetailHeader
          // 离开时钟区（左列播放器深色底垫在时钟下，白字前景可读）
          .padding({ top: this.statusBarVp() })
        }
        .width('100%')
        .height('100%')
      } else {
        // ===== 上下堆叠（小屏 + 竖屏大屏） =====
        Column() {
          this.PlayerArea()
          this.DetailHeader()
          this.DetailTabs()
        }
        .width('100%')
        .height('100%')
        // 【B5】冻结横屏 pillarbox 态：视频带居中后两侧露本层底色，置黑与
        // 视频带/转场盒黑边连续；其余态透明，保持页面底色（hero 盒底色）透出
        .backgroundColor(this.frozenLandscapePillar() ? Color.Black : Color.Transparent)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 页面级标题栏（hero 标题锚点；飞行中由覆盖层接管，titleOpacity 隐藏本体）。
   *  常驻返回入口（图标对齐 PlayerControlView 顶栏惯例），不依赖播放器控制层唤出 */
  @Builder
  DetailHeader() {
    Row({ space: $r('app.float.space_sm') }) {
      Image($r('app.media.ic_video_back'))
        .width(24)
        .height(28)
        .objectFit(ImageFit.Contain)
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_sm')
        })
        .onClick((): void => {
          Router.back();
        })
      Text(this.heroTitle())
        .fontSize($r('app.float.font_size_title'))
        .fontColor($r('app.color.text_on_brand'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .opacity(this.heroAnim.titleOpacity)
        // hid 后缀防叠页 id 冲突（详情→相关视频→详情，getRectangleById 会命中
        // 栈底页同 id 组件）；与 player-area-${hid} 同一约定
        .id(`detail-title-${this.hid}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.brand'))
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md'),
      top: $r('app.float.space_md')
    })
  }

  /** 播放器区：封面（未播常驻兜底）/ NodeContainer 活节点 + 弹幕层 + 控制层/浮层（已播）。
   *  ：进入不再自动播放，点 ▶ 才起播；全屏飞行时本区露封面非空洞 */
  @Builder
  PlayerArea() {
    Stack({ alignContent: Alignment.Top }) {
      // 封面（常驻：起播后垫在节点下，转场移交/归还间隙兜底；
      // 加载窗口期 VM 残留上一视频，回落转场入口封面）
      NetworkImage({
        url: this.coverUrl(),
        imageWidth: '100%',
        imageHeight: '100%',
        fit: ImageFit.Cover
      })

      if (this.vm.started && this.nodeHost !== undefined) {
        NodeContainer(this.nodeHost)
          .width('100%')
          .height('100%')
        // 点击区：切换控制层
        Column()
          .width('100%')
          .height('100%')
          .onClick((): void => {
            if (this.showControls) {
              this.showControls = false;
              this.stopControlsTimer();
            } else {
              this.showControlsWithTimer();
            }
          })

        // 弹幕渲染层（→  接线）：节点之上、控制层之下；半屏限制滚动 5 行
        DanmakuView({ limitScrollLines: 5 })

        // 断点续播提示条（VM 单例：仅本页视频数据就绪时展示，防上一视频残留闪现）
        if (this.videoLoaded()) {
          ResumeTipBar({ vm: this.vm })
            .alignSelf(ItemAlign.Start)
            .margin({ top: this.resumeTipTopVp() })
        }

        // 控制层（半屏形态）
        if (this.showControls) {
          PlayerControlView({
            vm: this.vm,
            visible: this.showControls,
            fullscreen: false,
            onBack: (): void => {
              Router.back();
            },
            onToggleFullscreen: (): void => {
              this.enterFullscreen();
            },
            onInteraction: (): void => {
              this.resetControlsTimer();
            },
            onOpenParts: (): void => {
              // 半屏形态：切回简介 Tab 让分集列表可见
              this.tabsController.changeIndex(0);
            },
            onOpenSettings: (): void => {
              // 半屏形态：无设置按钮（fullscreen=false 隐藏），留空占位
            },
            onToggleControls: (): void => {
              // 点击控制层空白：隐藏控制层
              this.showControls = false;
              this.stopControlsTimer();
            }
          })
            // 手机沉浸：控制层顶栏（含返回钮）让开状态栏时钟区（底栏仍贴播放区底边）
            .padding({ top: this.controlTopInsetVp() })
        }

        // 分集切换/缓冲浮层
        if (this.vm.partLoading || this.vm.isBuffering) {
          Column({ space: $r('app.float.space_sm') }) {
            LoadingProgress()
              .width(32)
              .height(32)
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
      } else if (!this.nodeAway) {
        // 封面态：点击整块播放区起播（播放按钮为视觉引导，点击区域不限）；
        // 节点外借期间（全屏转场飞行/全屏停留）不渲染引导层，仅露封面兜底
        Column() {
          Text('▶')
            .fontSize(30)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .width(68)
            .height(68)
            .borderRadius(34)
            .backgroundColor('rgba(0,0,0,0.55)')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('rgba(0,0,0,0.18)')
        .onClick((): void => {
          if (this.videoLoaded()) {
            this.vm.startPlay();
          }
        })

        // 续播提示条（封面态亦可见，点击直接续播；仅本页视频就绪时展示）
        if (this.videoLoaded()) {
          ResumeTipBar({ vm: this.vm })
            .alignSelf(ItemAlign.Start)
            .margin({ top: this.resumeTipTopVp() })
        }
      }
    }
    // 【B5】冻结横屏 pillarbox 态取窗高 16:9 居中带宽（Column 默认水平居中），
    // 其余态满宽——渲染层与 expandSourceRect/playAreaRectPx 兜底同几何
    .width(this.playerAreaWidth())
    .aspectRatio(1.7778)
    .backgroundColor(Color.Black)
    // 半屏 → 全屏转场源矩形：半屏播放区整体
    .id(`player-area-${this.hid}`)
  }

  /** 冻结期轻量骨架（§3.4）：静态占位块，无懒建/无图片/无动画——旋转落定的
   *  全量重排中 measure 面积恒定且极小，避开 GetAllChildrenWithBuild 懒建风暴；
   *  结构仿 InfoView 头部（缩略图 + 两行文字）与分集胶囊行，解冻切换无跳变感 */
  @Builder
  FrozenSkeleton() {
    Column({ space: $r('app.float.space_md') }) {
      Row({ space: $r('app.float.space_md') }) {
        Row()
          .width(120)
          .height(75)
          .borderRadius(8)
          .backgroundColor($r('app.color.divider'))
        Column({ space: $r('app.float.space_xs') }) {
          Row()
            .width('70%')
            .height(14)
            .borderRadius(7)
            .backgroundColor($r('app.color.divider'))
          Row()
            .width('50%')
            .height(14)
            .borderRadius(7)
            .backgroundColor($r('app.color.divider'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row()
        .width('100%')
        .height(40)
        .borderRadius(12)
        .backgroundColor($r('app.color.divider'))
      Row()
        .width('100%')
        .height(40)
        .borderRadius(12)
        .backgroundColor($r('app.color.divider'))
      Row()
        .width('100%')
        .height(40)
        .borderRadius(12)
        .backgroundColor($r('app.color.divider'))
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.space_md'))
  }

  /** 详情区：旋转窗口冻结骨架 / 加载态 / 简介+评论 Tab */
  @Builder
  DetailTabs() {
    if (this.layoutFrozen) {
      this.FrozenSkeleton()
    } else if (this.vm.loading) {
      LoadingState({ message: '加载中…' })
        .layoutWeight(1)
    } else if (this.vm.error.length > 0) {
      ErrorRetry({
        message: this.vm.error,
        onRetry: (): void => {
          this.vm.retryLoadDetail();
        }
      })
        .layoutWeight(1)
    } else {
      Tabs({ index: this.selectedTab, controller: this.tabsController }) {
        TabContent() {
          InfoView({ vm: this.vm })
        }
        .tabBar('简介')

        TabContent() {
          // 评论区（→  接线）：评论走主站 PHP 端点——列表 RawApi.COMMENT（HTML 分页）、
          // 楼中楼 JsonApi.REPLY、发送 RawApi.SEND_COMMENT、点赞 RawApi.SUPPORT；
          // 旧版独立评论门户已随站点废弃
          CommentsView({ typeid: this.videoTypeid(), hid: this.videoHid() })
        }
        .tabBar('评论')
      }
      .barMode(BarMode.Fixed)
      .layoutWeight(1)
      .width('100%')
      .onChange((index: number): void => {
        this.selectedTab = index;
      })
    }
  }
}

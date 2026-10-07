/**
 * 应用骨架（一多导航）
 * - 单一 NavPathStack 经 Router 全局共享，三形态共用
 * - 全形态统一底部悬浮玻璃 Tab 栏（手机/平板一致，uiMaterial 沉浸光感材质；
 *   平板上依据 UI Design Kit「半屏居中对齐」建议，仅宽度约束居中，
 *   barFloatingStyle 悬浮系统材质与手机完全一致）
 * - 六频道真实视图：推荐/新番/影剧/游戏/动画/频道宫格；
 *   手机形态 TabContent 懒加载门控（active），避免启动期五路并发请求
 * - 手机形态双击返回退出提示；Ctrl+F 聚焦搜索
 * - 自定义转场统一驱动：customNavContentTransition 查 HeroTransition 注册表，
 *   PUSH 查目标页 / POP 查来源页；卡片⇄详情 hero 与半屏⇄全屏展开共用同一驱动
 * - 沉浸联动（定案）：路由栈拦截按落位页同步沉浸态——沉浸集（Player/
 *   OfflinePlayer/VideoDetail）置顶时壳层顶部避让归零（shellPadTopVp=0），
 *   详情页视频区贴窗口物理顶（状态栏透明浮于其上，前景色归详情页）；播放页
 *   另窗口级隐藏系统栏（安全区收缩→内容自动铺满整窗）；其余页面恢复壳层避让
 */
import { AppContextHolder, GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { ContinuePayload, ContinuationSlot, MissionContinueSwitch } from '../common/ContinuationState';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { HomeTab } from '../common/Constants';
import { Router, SearchRevealParam } from '../common/Router';
import { SessionService } from '../service/session/SessionService';
import { HomeVM } from '../viewmodel/HomeVM';
import { RecommendView } from '../views/home/RecommendView';
import { ChannelListView } from '../views/home/ChannelListView';
import { ChannelGridView } from '../views/home/ChannelGridView';
import { MineCenterView } from '../views/mine/MineCenterView';
import { HeroAnimateCallback, HeroTransition, HeroRectUtils, RectPx } from '../common/HeroTransition';
import uiMaterial from '@ohos.arkui.uiMaterial';

@Entry
@ComponentV2
struct Index {
  /** 窗口几何/避让区单例：@Local 持有成员 + @Trace 字段链（shellPadTopVp 读
   *  immersiveTop）建立 V2 精确追踪依赖，immersiveTop 翻转后壳层 padding
   *  可靠重渲（沉浸路由的依赖基线） */
  @Local windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();
  pathStack: NavPathStack = new NavPathStack();
  /** 双击返回退出计时 */
  private lastBackAt: number = 0;
  private vm: HomeVM = HomeVM.shared();
  private unsubscribeUnread: (() => void) | null = null;
  /** 自定义转场期间禁用导航交互（防止动画中操作导致布局错乱） */
  @Local isTransitioning: boolean = false;
  /** 首页被目的地覆盖（PUSH 隐藏搜索 FAB，POP 露出导航栏才恢复；多级栈不误亮） */
  @Local fabHiddenByDest: boolean = false;
  /** 转场兜底定时器（onTransitionEnd 丢失时强制恢复交互） */
  private transitionSafetyTimer: number = -1;
  /** 在途转场 proxy 持有（契约见 HeroAnimateCallback）：框架超时任务=唯一合法 finish，
   *  以 weak 引用唤起 native proxy——JS 包装若先被 GC 则任务静默流产、转场永不收尾；
   *  钉住包装生命周期至 onTransitionEnd（各页注册超时 ≤1300 < 兜底 1500） */
  private activeTransitionProxy: NavigationTransitionProxy | null = null;
  /** 系统栏当前隐藏态（沉浸路由：仅播放页隐藏；详情页 pad=0 但保留状态栏） */
  private barsHidden: boolean = false;

  aboutToAppear(): void {
    Router.init(this.pathStack);
    // 启动即同步登录态（持久化 User → SessionState）：否则冷启后 isLoggedIn/unread
    // 恒为初值 false/0，我的页/侧边栏在首个登录事件到来前永远显示未登录
    SessionService.shared().syncSessionState();
    // 沉浸页壳层避让驱动（F 终局）：willShow/didShow 按落位页切换 immersiveTop——
    // Player/OfflinePlayer 置顶归零壳层 padding（视频铺满整窗）并窗口级隐藏系统栏，
    // 其余页面/首页恢复避让与系统栏。willShow 先于目的页创建触发，
    // 转场起点两侧坐标已就位（与全屏前窗口扩展时机同构）
    this.pathStack.setInterception({
      willShow: (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
        _operation: NavigationOperation, _isAnimated: boolean): void => {
        this.syncImmersiveTop(to);
      },
      didShow: (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
        _operation: NavigationOperation, _isAnimated: boolean): void => {
        this.syncImmersiveTop(to);
      }
    });
    // 未读数联动（UNREAD_CHANGED → SessionState）
    this.unsubscribeUnread = this.vm.bindUnread();
    // 多端接续恢复：接续启动（onWindowStageRestore 直达骨架 / 热启动重建）
    // 时接续槽非空 → 直达详情页；分集/时位等续播点由 VideoDetailVM.loadDetail 按
    // hid 消费（接续槽 peek 不清——导航只取 hid，续播点留给 VM）
    const cont: ContinuePayload | null = ContinuationSlot.shared().peek();
    if (cont !== null) {
      hilog.info(0x0000, 'TucaoIndex', '[Continuation] 接续直达详情页: hid=%{public}s', cont.hid);
      Router.goVideoDetail(cont.hid);
    }
  }

  /** 按落位页同步沉浸态（to 为 'navBar' 即首页；目的页取路由名）——定案：
   *  immersiveTop 标记"沉浸页置顶"（详情页与播放页），壳层顶部避让随它归零/
   *  恢复（详情页视频贴物理顶的充分必要机制，页面侧零补偿）；系统栏隐藏仅
   *  播放页（hideBars）——安全区随栏收缩，播放内容自动铺满整窗。willShow+
   *  didShow 双发，两标记均未变时跳过（窗口调用幂等去重） */
  private syncImmersiveTop(to: NavDestinationContext | NavBar): void {
    const name: string = typeof to === 'string' ? '' : to.pathInfo.name;
    // 多端接续入口动态开关：仅播放场景（在线详情/全屏）向系统全局接续
    // 入口亮出本应用；离线播放目标端无本地文件不参与，首页/其余页面隐藏
    // （须置于幂等早退之前——每次落位都驱动；开关内部自带去重）
    MissionContinueSwitch.setActive(name === 'Player' || name === 'VideoDetail');
    const immersive: boolean = name === 'Player' || name === 'OfflinePlayer' || name === 'VideoDetail';
    const hideBars: boolean = name === 'Player' || name === 'OfflinePlayer';
    hilog.info(0x0000, 'TucaoIndex', 'syncImmersiveTop name=%{public}s immersive=%{public}s hideBars=%{public}s curTop=%{public}s',
      name, `${immersive}`, `${hideBars}`, `${this.windowSize.immersiveTop}`);
    if (this.windowSize.immersiveTop === immersive && this.barsHidden === hideBars) {
      return;
    }
    this.windowSize.immersiveTop = immersive;
    this.barsHidden = hideBars;
    this.toggleSystemBars(hideBars);
  }

  /** 沉浸态窗口级系统栏开关（hideBars=true 隐藏三栏，仅播放页）：全屏布局模式下
   *  NavDestination 的 enableStatusBar/enableNavigationIndicator 实测不生效（状态栏
   *  仍可见并拦截触摸、避让区零事件），须按窗口调 setSpecificSystemBarEnabled
   *  （该 API 仅全屏/最大化窗口生效，本应用 setWindowLayoutFullScreen(true) 常开，
   *  条件天然满足）。恢复三栏全开对齐启动默认；失败仅告警（下次导航幂等重试自愈） */
  private toggleSystemBars(hideBars: boolean): void {
    const context = AppContextHolder.get();
    if (context === null) {
      return;
    }
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      mainWindow.setSpecificSystemBarEnabled('status', !hideBars).catch((err: BusinessError): void => {
        hilog.warn(0x0000, 'TucaoIndex', 'setSpecificSystemBarEnabled status failed: %{public}s', JSON.stringify(err));
      });
      mainWindow.setSpecificSystemBarEnabled('navigation', !hideBars).catch((err: BusinessError): void => {
        hilog.warn(0x0000, 'TucaoIndex', 'setSpecificSystemBarEnabled navigation failed: %{public}s', JSON.stringify(err));
      });
      mainWindow.setSpecificSystemBarEnabled('navigationIndicator', !hideBars).catch((err: BusinessError): void => {
        hilog.warn(0x0000, 'TucaoIndex', 'setSpecificSystemBarEnabled indicator failed: %{public}s', JSON.stringify(err));
      });
    }).catch((err: BusinessError): void => {
      hilog.warn(0x0000, 'TucaoIndex', 'getLastWindow failed: %{public}s', JSON.stringify(err));
    });
  }

  aboutToDisappear(): void {
    if (this.unsubscribeUnread !== null) {
      this.unsubscribeUnread();
      this.unsubscribeUnread = null;
    }
  }

  /** 手机形态双击返回退出；栈内可返回时交由 Navigation 处理 */
  onBackPress(): boolean {
    if (this.pathStack.size() > 0) {
      return false;
    }
    const now: number = Date.now();
    if (now - this.lastBackAt < 2000) {
      return false;
    }
    this.lastBackAt = now;
    this.getUIContext().getPromptAction().showToast({ message: '再按一次退出吐槽' });
    return true;
  }

  /** 自定义转场驱动（HeroTransition 注册表统一调度）。
   *  PUSH 查目标页 / POP 查来源页——首页无 navDestinationId 天然不参与，
   *  故不做 demo 的双侧 id 守卫（那会杀掉列表 → 详情的 hero 进入） */
  private runCustomTransition(from: NavContentInfo, to: NavContentInfo,
    operation: NavigationOperation): NavigationAnimatedTransition | undefined {
    const isPush: boolean = operation === NavigationOperation.PUSH;
    const side: NavContentInfo = isPush ? to : from;
    const pageId: string = side.navDestinationId ?? '';
    // 首页搜索 FAB 显隐驱动（先于一切 early return，任何导航操作都会路过）：
    // PUSH 一律覆盖隐藏；POP 露出导航栏（目标侧无 navDestinationId）才恢复，
    // 多级栈弹出中间页（如 Player→Detail）时首页仍被覆盖，不误亮
    const toId: string = to.navDestinationId ?? '';
    this.fabHiddenByDest = isPush || toId.length > 0;
    if (pageId.length === 0) {
      return undefined;
    }
    const callback: HeroAnimateCallback | undefined = HeroTransition.get(pageId);
    if (callback === undefined) {
      return undefined;
    }
    const resolvedTimeout: number = callback.resolveTimeout !== null ?
      callback.resolveTimeout(isPush) : callback.timeout;
    return {
      // 注册超时 = 唯一合法 finish（契约见 HeroAnimateCallback）：页面飞完落位后，
      // 框架死线任务走同一 finishWrapper 链收尾并回调本 onTransitionEnd(success=true)
      timeout: resolvedTimeout,
      transition: (transitionProxy: NavigationTransitionProxy): void => {
        // 持有 proxy 至 onTransitionEnd：死线任务 weak 升级必达（见成员注释）
        this.activeTransitionProxy = transitionProxy;
        this.isTransitioning = true;
        // 兜底：onTransitionEnd 丢失时强制恢复交互（1.5s > 各页注册超时上限 1300ms）
        if (this.transitionSafetyTimer >= 0) {
          clearTimeout(this.transitionSafetyTimer);
        }
        this.transitionSafetyTimer = setTimeout((): void => {
          this.isTransitioning = false;
          this.transitionSafetyTimer = -1;
          this.activeTransitionProxy = null;
        }, 1500);
        callback.animation(isPush);
      },
      onTransitionEnd: (_isSuccess: boolean): void => {
        if (this.transitionSafetyTimer >= 0) {
          clearTimeout(this.transitionSafetyTimer);
          this.transitionSafetyTimer = -1;
        }
        this.isTransitioning = false;
        this.activeTransitionProxy = null;
      }
    };
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        // 全形态统一底部悬浮玻璃 Tab 栏（平板按半屏宽度居中，见 TabletTabBar）
        this.TabShell()
        // 首页搜索悬浮入口（Ctrl+F 的触屏等价物）：非『我的』频道且首页未被覆盖
        if (!this.fabHiddenByDest && this.vm.currentChannel !== HomeTab.MINE) {
          this.SearchFab()
        }
      }
      .width('100%')
      .height('100%')
      // 全局沉浸避让（定案 + 底部延伸）：窗口 layoutFullScreen 下系统不再代管
      // 顶部避让，壳层仅垫顶部状态栏高（时钟/电量可见，R1 验收要求）——首页等
      // 普通页由此让开时钟区；沉浸集（Player/OfflinePlayer/VideoDetail）置顶时
      // shellPadTopVp 归零（见 syncImmersiveTop）：详情页视频贴窗口物理顶
      // （状态栏透明浮于视频上），播放页叠加窗口级隐藏系统栏。
      // 底部不垫——小白条透明悬浮于内容之上，页面内容延伸到胶囊底下滚动穿行
      // （iOS 式），吸底交互件（Tab 栏/FAB）在自身 margin 内让位指示条高度
      .padding({
        top: this.windowSize.shellPadTopVp
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .focusable(true)
    .defaultFocus(true)
    .keyboardShortcut('f', [ModifierKey.CTRL], (): void => {
      Router.goSearch();
    })
  }

  /** 首页搜索悬浮按钮：右下角悬浮于 Tab 栏上方（底边距 = 指示条让位 + 栏底距 12 +
   *  栏高约 56 + 间距 16），出入走 200ms 淡入淡出；点击与 Ctrl+F 同源路由 */
  @Builder
  SearchFab() {
    Stack() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(24)
        .fontColor([$r('app.color.text_on_brand')])
    }
    .width(48)
    .height(48)
    .borderRadius(24)
    .backgroundColor($r('app.color.brand'))
    .margin({
      bottom: 84 + this.windowSize.navBarHeightVp,
      right: $r('app.float.space_lg')
    })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
    .id('search-fab')
    .onClick((): void => {
      // 水波揭示（R3）：点击时采集悬浮球圆心/直径（px 窗口坐标），随路由传入 Search 页
      // 播放圆形揭示；采集失败（极端时序）回退普通进入
      const fabRect: RectPx | null = HeroRectUtils.captureRectPx(this.getUIContext(), 'search-fab');
      if (fabRect === null) {
        Router.goSearch();
        return;
      }
      const revealParam: SearchRevealParam = new SearchRevealParam();
      revealParam.centerXpx = fabRect.left + fabRect.width / 2;
      revealParam.centerYpx = fabRect.top + fabRect.height / 2;
      revealParam.diameterPx = fabRect.width;
      Router.goSearchWithReveal(revealParam);
    })
  }

  /** 内容分发（index → 视图；active 由手机形态 Tab 门控）
   *  频道 + "我的" 共七项：MINE 为虚拟频道，展示 MineCenterView（全形态同源功能清单） */
  @Builder
  HomeTabContent(index: number, active: boolean) {
    if (index === HomeTab.RECOMMEND) {
      RecommendView({ active: active })
    } else if (index === HomeTab.CHANNEL) {
      ChannelGridView()
    } else if (index === HomeTab.MINE) {
      MineCenterView()
    } else {
      ChannelListView({
        tid: HomeTab.LIST_TIDS[`${index}`],
        active: active
      })
    }
  }

  /** 底部 Tab 标签（自定义样式，选中加粗 brand 色）。
   *  ForEach itemGenerator 不随状态重跑，标签选中态须由子组件读共享 VM 自行响应 */
  @Builder
  TabLabel(index: number) {
    HomeTabLabel({ index: index })
  }

  /** 全形态统一壳：Navigation 单栏（详情全屏覆盖 Tab 栏）+ 底部悬浮 glass Tabs。
   *  平板侧栏取消，改与手机一致；Tab 栏启用悬浮沉浸材质 */
  @Builder
  TabShell() {
    Navigation(this.pathStack) {
      Tabs({ barPosition: BarPosition.End, index: this.vm.currentChannel }) {
        ForEach(HomeTab.TITLES, (title: string, index: number) => {
          TabContent() {
            this.HomeTabContent(index, !this.windowSize.isCompact() || this.vm.currentChannel === index)
          }
          .tabBar(this.TabLabel(index))
        }, (title: string) => title)
      }
      .scrollable(false)
      .vertical(false)
      .barOverlap(true)
      .barFloatingStyle({
        systemMaterial: new uiMaterial.ImmersiveMaterial(),
        // 平板半屏居中胶囊 Tab 栏（API26 FloatingTabBarStyle.barWidth，
        //   对齐 UI Design Kit「设置页签栏的悬浮样式 / 半屏居中对齐样式」）
        barWidth: {
          smallBarWidth: '100%',
          mediumBarWidth: '50%',
          largeBarWidth: '50%'
        },
        // 壳层底部不垫后指示条悬浮于内容，Tab 栏让出指示条高度保持原视觉位置
        // （壳层零底部 padding 后内容在胶囊底下滚动穿行，iOS 式）
        barBottomMargin: 12 + this.windowSize.navBarHeightVp
      })
      .layoutWeight(1)
      .width('100%')
      .onChange((index: number) => {
        this.vm.currentChannel = index;
        // ForEach 预建 TabContent 后 active 参数冻结为初始值，
        // 切换时须显式触发内容频道首屏加载（loadChannel 自带防重入守卫，幂等）
        const tid: number | undefined = HomeTab.LIST_TIDS[`${index}`];
        if (tid !== undefined) {
          this.vm.loadChannel(tid);
        }
      })
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    // PiP navigationId 依赖：小窗全屏按钮恢复页面时定位此 Navigation
    .id('MainNavigation')
    .enabled(!this.isTransitioning)
    // 自定义转场统一驱动（lambda 包装保 this 绑定；未注册页面返回 undefined 走系统默认转场）
    .customNavContentTransition((from: NavContentInfo, to: NavContentInfo,
      operation: NavigationOperation): NavigationAnimatedTransition | undefined => {
      return this.runCustomTransition(from, to, operation);
    })
    .width('100%')
    .height('100%')
  }
}

/** 底部 Tab 标签（响应式：读共享 VM 选中态，规避 ForEach itemGenerator 冻结） */
@ComponentV2
struct HomeTabLabel {
  @Param index: number = 0;
  private vm: HomeVM = HomeVM.shared();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  build() {
    Text(HomeTab.TITLES[this.index])
      .fontSize(this.windowSize.isExpanded() ? $r('app.float.font_size_body')
        : $r('app.float.font_size_caption'))
      .fontWeight(this.vm.currentChannel === this.index ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.vm.currentChannel === this.index
        ? $r('app.color.brand')
        : $r('app.color.tab_inactive'))
  }
}

/**
 * 全局状态单例（State Management V2）
 * 三个 @ObservedV2 单例经 AppStorageV2.connect 注册，供 Ability/页面/VM 全局联动：
 * - WindowSizeInfo：窗口尺寸/断点/避让区（EntryAbility 注册监听后写入）
 * - SessionState：登录态/用户摘要/未读数（SessionService 写入，侧边栏等联动刷新）
 * - ColorModeState：深浅色模式（onConfigurationUpdate 写入）
 */
import { AppStorageV2 } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

/** 宽度断点（对齐一多规范：sm<600 / md<840 / lg<1440 / xl>=1440 vp） */
export enum WidthBreakpoint {
  SM = 'sm',
  MD = 'md',
  LG = 'lg',
  XL = 'xl'
}

/** 窗口尺寸与避让区信息（px 单位由 EntryAbility 写入，同时换算 vp） */
@ObservedV2
export class WindowSizeInfo {
  /** 窗口宽度 vp */
  @Trace windowWidthVp: number = 0;
  /** 窗口高度 vp */
  @Trace windowHeightVp: number = 0;
  /** 状态栏避让高度 px */
  @Trace statusBarHeightPx: number = 0;
  /** 底部系统避让高度 px（导航条） */
  @Trace navBarHeightPx: number = 0;
  /** 屏幕像素密度（px→vp 换算基准；EntryAbility 初次同步窗口尺寸时写入，恒 > 0） */
  @Trace density: number = 1;
  /** 挖孔屏左侧避让宽度 px（横屏全屏播放控制层左侧避让） */
  @Trace cutoutLeftPx: number = 0;
  /** 挖孔屏右侧避让宽度 px（横屏全屏播放控制层右侧避让） */
  @Trace cutoutRightPx: number = 0;
  /** 键盘避让高度 px（弹幕输入条键盘遮挡处理用） */
  @Trace keyboardHeightPx: number = 0;
  /** 当前宽度断点 */
  @Trace breakpoint: WidthBreakpoint = WidthBreakpoint.SM;

  /** 沉浸页（Player/OfflinePlayer/VideoDetail）置顶标记：壳层顶部避让随它归零/
   *  恢复（Index 壳层 padding 读 shellPadTopVp）——详情页视频贴窗口物理顶的
   *  充分必要机制；播放页另由 Index 窗口级隐藏系统栏（栏隐→安全区收缩→内容
   *  自动铺满整窗）。layoutFullScreen 模式下 enableStatusBar(false) 不生效且
   *  不触发避让区事件（已实测），系统栏显隐须走 setSpecificSystemBarEnabled */
  @Trace immersiveTop: boolean = false;

  /** 用像素宽高刷新（内部换算 vp 并计算断点） */
  updateByPixel(widthPx: number, heightPx: number, density: number): void {
    const safeDensity: number = density > 0 ? density : 1;
    this.density = safeDensity;
    this.windowWidthVp = widthPx / safeDensity;
    this.windowHeightVp = heightPx / safeDensity;
    this.breakpoint = WindowSizeInfo.breakpointOf(this.windowWidthVp);
  }

  /** 状态栏避让高度 vp（全局沉浸壳层避让基准；密度未就绪时回退 0） */
  get statusBarHeightVp(): number {
    return this.density > 0 ? this.statusBarHeightPx / this.density : 0;
  }

  /** 底部系统避让高度 vp（小白条/导航条；密度未就绪时回退 0）——壳层不再整体
   *  垫高（见 shellPadBottomVp），仅供吸底交互件（Tab 栏/FAB/回复发射框）让位计算 */
  get navBarHeightVp(): number {
    return this.density > 0 ? this.navBarHeightPx / this.density : 0;
  }

  /** 壳层顶部避让 vp（Index 壳层 padding 绑定）：沉浸页（Player/OfflinePlayer/
   *  VideoDetail）置顶时归零（详情页视频贴物理顶），其余页面垫状态栏高（时钟/
   *  电量可读）；Search 揭示直径预计算亦引用（避让区覆盖补偿） */
  get shellPadTopVp(): number {
    return this.immersiveTop ? 0 : this.statusBarHeightVp;
  }

  /** 壳层底部避让 vp——恒 0（iOS 式底部沉浸）：小白条（手势指示条）透明悬浮于
   *  内容之上，页面内容延伸到胶囊底下滚动穿行，不再整层垫出均匀底色衬底带
   *  （用户报告的"白边不透明"，2b601a3 曾落地后随 6b29678 整体回退一并丢失，
   *  本次仅恢复底部延伸，顶部状态栏避让维持 F 终局可见时钟方案）。
   *  吸底交互件（Tab 栏/搜索 FAB/回复发射框）各自让位指示条高度 */
  get shellPadBottomVp(): number {
    return 0;
  }

  /** 是否手机形态（底部 Tabs） */
  isCompact(): boolean {
    return this.breakpoint === WidthBreakpoint.SM;
  }

  /** 是否中等宽度（竖向 rail） */
  isMedium(): boolean {
    return this.breakpoint === WidthBreakpoint.MD;
  }

  /** 是否大屏（常驻侧栏） */
  isExpanded(): boolean {
    return this.breakpoint === WidthBreakpoint.LG || this.breakpoint === WidthBreakpoint.XL;
  }

  /** 断点计算（xs 归并到 sm） */
  static breakpointOf(widthVp: number): WidthBreakpoint {
    if (widthVp >= 1440) {
      return WidthBreakpoint.XL;
    }
    if (widthVp >= 840) {
      return WidthBreakpoint.LG;
    }
    if (widthVp >= 600) {
      return WidthBreakpoint.MD;
    }
    return WidthBreakpoint.SM;
  }
}

/** 会话状态（登录态与用户摘要，供全局 UI 联动） */
@ObservedV2
export class SessionState {
  /** 是否已登录（以 User.name 非空为准，由 SessionService 维护；2026-09 改版后个人页无邮箱行） */
  @Trace isLoggedIn: boolean = false;
  /** 用户昵称 */
  @Trace userName: string = '';
  /** 用户头像地址 */
  @Trace userAvatar: string = '';
  /** 未读私信数（侧边栏角标） */
  @Trace unreadMessageCount: number = 0;
}

/** 深浅色模式状态 */
@ObservedV2
export class ColorModeState {
  /** 是否深色模式（跟随系统 onConfigurationUpdate 实时切换） */
  @Trace isDark: boolean = false;
}

/** 应用上下文持有器（EntryAbility onCreate 写入一次，服务层无 context 时取用） */
export class AppContextHolder {
  private static context: common.UIAbilityContext | null = null;

  static set(context: common.UIAbilityContext): void {
    AppContextHolder.context = context;
  }

  static get(): common.UIAbilityContext | null {
    return AppContextHolder.context;
  }
}

/** 全局单例访问器 */
export class GlobalState {
  private static readonly WINDOW_SIZE_KEY: string = 'global:window_size';
  private static readonly SESSION_KEY: string = 'global:session';
  private static readonly COLOR_MODE_KEY: string = 'global:color_mode';

  /** 窗口尺寸单例 */
  static windowSizeInfo(): WindowSizeInfo {
    const info: WindowSizeInfo | undefined = AppStorageV2.connect(
      WindowSizeInfo, GlobalState.WINDOW_SIZE_KEY, (): WindowSizeInfo => new WindowSizeInfo());
    return info ?? new WindowSizeInfo();
  }

  /** 会话状态单例 */
  static sessionState(): SessionState {
    const state: SessionState | undefined = AppStorageV2.connect(
      SessionState, GlobalState.SESSION_KEY, (): SessionState => new SessionState());
    return state ?? new SessionState();
  }

  /** 深浅色状态单例 */
  static colorModeState(): ColorModeState {
    const state: ColorModeState | undefined = AppStorageV2.connect(
      ColorModeState, GlobalState.COLOR_MODE_KEY, (): ColorModeState => new ColorModeState());
    return state ?? new ColorModeState();
  }
}

/**
 * 连续缩放（活画面）转场公共契约
 * - HeroTransition：pageId → 动画回调注册表（Index.customNavContentTransition 统一驱动），
 *   附设备折叠态判定与 float/color 资源数值取数（animateTo 数值插值需 number，不用 Resource）
 * - HeroCardParam：卡片 → 详情 hero 转场参数（点击时采集 rect，随路由传入 VideoDetail）
 * - PlayerExpandParam：半屏 → 全屏转场参数（onToggleFullscreen 时采集，随路由传入 Player）
 * - HeroSourceState/HeroSource：转场期间隐藏列表源卡片封面/标题的全局联动状态（AppStorageV2）；
 *   源隐藏与节点 id 均以卡片实例 token 键控（A1：同屏同 hid 多实例不串扰）
 * - HeroRectUtils：componentUtils rect 采集（含 scale 补偿的窗口坐标可视外接矩形）
 * - HeroDetailAnim/PlayerBoxAnim：@ObservedV2 动画状态载体（页面持有 @Local 驱动盒结构）
 */
import { AppStorageV2, componentUtils, display, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 组件可视外接矩形（px，窗口坐标；含 scale 补偿） */
export class RectPx {
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;
}

/** 卡片 → 详情 hero 转场参数（点击时采集，随路由传入 VideoDetail） */
export class HeroCardParam {
  /** 封面矩形（px，窗口坐标） */
  coverRect: RectPx = new RectPx();
  /** 标题矩形（px，窗口坐标） */
  titleRect: RectPx = new RectPx();
  /** 视频标题（详情页标题先行渲染，不等待网络） */
  title: string = '';
  /** 封面地址（转场首帧封面兜底显示） */
  coverUrl: string = '';
  /** 卡片圆角 vp（hero 初态圆角） */
  cornerRadius: number = 0;
  /** 发射页封面节点 id（各页前缀不同：rank-row- / star-row- / …，含实例 token 后缀），
   * 详情页窗口变更重查按此 id 定位；空串回退旧约定 cover-{hid} */
  coverId: string = '';
  /** 发射页标题节点 id（含实例 token 后缀），空串回退 title-{hid} */
  titleId: string = '';
  /** 发射卡片组件实例 token（A1：同屏同 hid 多实例时区分 rect 采集与
   *  源隐藏键控目标；详情页 POP 起飞前按此 token 重标记源卡） */
  sourceToken: string = '';
}

/** 半屏 → 全屏转场参数（onToggleFullscreen 时采集，随路由传入 Player） */
export class PlayerExpandParam {
  /** push 时刻窗口宽 px（§3.1 先旋转后展开：窗口旋转已先行完成，此为最终几何快照；
   *  GlobalState 窗口监听未就绪时 Player 侧的回退基准） */
  windowWidthPx: number = 0;
  /** push 时刻窗口高 px */
  windowHeightPx: number = 0;
  /** 半屏播放区矩形（px，窗口坐标；最终几何下的采集值） */
  sourceLeftPx: number = 0;
  sourceTopPx: number = 0;
  sourceWidthPx: number = 0;
  sourceHeightPx: number = 0;
  /** 源播放区节点 id 后缀（hid）：Player 侧 PUSH/POP 转场时活捕 `player-area-${sourceHid}`，
   *  空串或活捕失败回退上方 push 时刻矩形快照（R4/R5 活算；先旋转后展开下
   *  PUSH/POP 同几何，快照与活捕等价） */
  sourceHid: string = '';
  /** 【B5】冻结横屏 pillarbox 会话标记（手机竖屏来源：push 时窗口已转横屏且
   *  详情页冻结贯穿）：源详情页 = 纯黑底 + 窗高 16:9 视频带水平居中，Player
   *  POP 垫底层据此置纯黑底色（垫底封面同位铺黑底、盒外区域与冻结页黑边
   *  连续）；其余会话（平板分栏/横屏停留/降级跳转）保持页面底色复现真页面 */
  frozenLandscape: boolean = false;
  /** POP 完成回调：节点归还详情页（重建 NodeContainer + surface 重绑；窗口方向
   *  归还亦由详情页 restoreNodeHost 经 OrientationArbiter 执行——§3.5 单一所有者） */
  onNodeReturn: () => void = () => {
  };
}

/** hero 源实例 token 序列（进程内单调自增；组件实例构造时取号，全局唯一） */
let heroSourceTokenSeq: number = 0;

/** hero 转场源隐藏状态（列表卡片在转场期间隐藏封面/标题，避免与飞行画面双重露出） */
@ObservedV2
export class HeroSourceState {
  /** 正在转场的卡片实例 token（空串 = 无转场进行中）。
   *  【A1】由 hid 键控改为实例 token 键控：同屏同 hid 多卡（首页多分组/多 Tab、
   *  排行榜多榜 Tab）时仅隐藏所点实例，未点击的孪生卡封面不再被误隐藏 */
  @Trace activeToken: string = '';
  private clearTimer: number = -1;

  /** 标记源开始转场（1600ms 兜底自清，覆盖 POP 回调被中断的场景）。
   *  A5：成功路径 INFO 留痕——冒烟核对 token 键控/隐藏目标时无需断点 */
  markSource(token: string): void {
    this.activeToken = token;
    hilog.info(0x0001, 'HeroSource', 'markSource token=%{public}s', token);
    if (this.clearTimer >= 0) {
      clearTimeout(this.clearTimer);
    }
    this.clearTimer = setTimeout((): void => {
      this.activeToken = '';
      this.clearTimer = -1;
    }, 1600);
  }

  /** 清除源标记（POP onFinish 正常路径调用） */
  clearSource(): void {
    if (this.clearTimer >= 0) {
      clearTimeout(this.clearTimer);
      this.clearTimer = -1;
    }
    this.activeToken = '';
  }
}

/** hero 源状态单例访问器（AppStorageV2 跨视图联动，GlobalState 同模式） */
export class HeroSource {
  private static readonly KEY: string = 'global:hero_source';

  static getState(): HeroSourceState {
    const state: HeroSourceState | undefined = AppStorageV2.connect(
      HeroSourceState, HeroSource.KEY, (): HeroSourceState => new HeroSourceState());
    return state ?? new HeroSourceState();
  }
}

/** 页面注册的转场动画回调（Index customNavContentTransition 统一调度） */
export class HeroAnimateCallback {
  /** 动画执行体：isPush=true 进入 / false 返回。
   *  【契约】动画结束【禁止】调用 proxy.finishTransition()：框架为每次自定义转场注册的
   *  超时任务（ExecuteAddAnimation → PostDelayedTask "ArkUINavigationTransitionProxyFinish"）
   *  永不取消，我方提前 finish 后死线任务仍会触发——native proxy 存活（取决于 JS 包装
   *  对象是否已被 GC，纯彩票）即打出 "not support to finish custom animation more than
   *  once" E 级日志。定论方案：注册超时即【唯一合法 finish】，页面只管飞完落位（落位
   *  动作与转场收尾解耦），框架死线任务走同一 finishWrapper 链收尾（源码级验证该路径
   *  正常走完并 endCallback(true)）；Index 持有 proxy 至 onTransitionEnd，保证死线任务
   *  weak 升级必达 */
  animation: (isPush: boolean) => void =
    (_isPush: boolean): void => {
    };
  /** 转场超时 ms = 唯一合法 finish 时刻：须 ≥ 落位时长 + 余量（过短会截断飞行收早了） */
  timeout: number = 1000;
  /** 按方向/设备形态动态解析超时（如自由窗 POP 几何稳定等待需更长）；null 时退回 timeout */
  resolveTimeout: ((isPush: boolean) => number) | null = null;
}

/** 转场注册表 + 设备形态/资源取数工具 */
export class HeroTransition {
  private static readonly callbacks: Map<string, HeroAnimateCallback> = new Map();

  /** 生成下一个源卡片实例 token（A1：每个卡片组件实例构造时取一次，全程复用；
   *  进程内单调自增保证全局唯一——节点 id、HeroCardParam 透传、源隐藏键控
   *  三处共用同一 token，同屏同 hid 多实例互不串扰） */
  static nextSourceToken(): string {
    heroSourceTokenSeq += 1;
    return `t${heroSourceTokenSeq}`;
  }

  /** 目标页 onReady 注册（覆盖式） */
  static register(pageId: string, callback: HeroAnimateCallback): void {
    HeroTransition.callbacks.set(pageId, callback);
  }

  /** 页面销毁注销 */
  static unregister(pageId: string): void {
    HeroTransition.callbacks.delete(pageId);
  }

  /** Index 驱动查询 */
  static get(pageId: string): HeroAnimateCallback | undefined {
    return HeroTransition.callbacks.get(pageId);
  }

  /** 折叠屏展开/半展开（非折叠设备返回 false） */
  static isExpandedOrHalfFolded(): boolean {
    let expanded: boolean = false;
    try {
      expanded = display.getFoldStatus() === display.FoldStatus.FOLD_STATUS_EXPANDED ||
        display.getFoldStatus() === display.FoldStatus.FOLD_STATUS_HALF_FOLDED;
    } catch (_err) {
      expanded = false;
    }
    return expanded;
  }

  /** 折叠屏半折叠（笔记本/帐篷态窗口几何不稳，旋转支路禁用；非折叠设备返回 false） */
  static isHalfFolded(): boolean {
    let half: boolean = false;
    try {
      half = display.getFoldStatus() === display.FoldStatus.FOLD_STATUS_HALF_FOLDED;
    } catch (_err) {
      half = false;
    }
    return half;
  }

  /** 取 float 资源数值（资源缺失/上下文未就绪回退 fallback）。
   *  【问题②根因修复】getNumber 返回 px 语义值（数值×屏幕密度；平板 density=2
   *  实测 space_md=12 取回 24、font_size_title=17 取回 34，手机 density=3 取回
   *  15→45）——直接使用会令飞行标题字号/间距随密度膨胀（平板 POP 末段标题停留
   *  34fp 大字号 + 终点偏移的根因之一）。除以密度还原 fp/vp 数值后再返回 */
  static resNumber(ui: UIContext, resource: Resource, fallback: number): number {
    try {
      const context = ui.getHostContext();
      if (context !== undefined) {
        return ui.px2vp(context.resourceManager.getNumber(resource.id));
      }
    } catch (_err) {
      // 回退 fallback
    }
    return fallback;
  }

  /** 取 color 资源数值（0xAARRGGBB；失败回退 fallback） */
  static resColor(ui: UIContext, resource: Resource, fallback: number): number {
    try {
      const context = ui.getHostContext();
      if (context !== undefined) {
        return context.resourceManager.getColorSync(resource.id);
      }
    } catch (_err) {
      // 回退 fallback
    }
    return fallback;
  }
}

/** rect 采集工具（componentUtils，含 scale 补偿） */
export class HeroRectUtils {
  /** 按组件 id 采集可视外接矩形（px，窗口坐标）；组件不存在/尺寸非法返回 null */
  static captureRectPx(ui: UIContext, id: string): RectPx | null {
    try {
      const info: componentUtils.ComponentInfo = ui.getComponentUtils().getRectangleById(id);
      const widthScaleGap: number = info.size.width * (1 - info.scale.x) / 2;
      const heightScaleGap: number = info.size.height * (1 - info.scale.y) / 2;
      const left: number = info.translate.x + info.windowOffset.x + widthScaleGap;
      const top: number = info.translate.y + info.windowOffset.y + heightScaleGap;
      const right: number = info.translate.x + info.windowOffset.x + info.size.width - widthScaleGap;
      const bottom: number = info.translate.y + info.windowOffset.y + info.size.height - heightScaleGap;
      const rect: RectPx = new RectPx();
      rect.left = left;
      rect.top = top;
      rect.width = right - left;
      rect.height = bottom - top;
      if (rect.width <= 0 || rect.height <= 0) {
        hilog.warn(0x0001, 'HeroRectUtils', 'captureRectPx invalid size id=%{public}s', id);
        return null;
      }
      // A5：成功路径 INFO 留痕（px 取整）——核对 hero 起飞/落位 rect 与
      // token 键控采集目标；失败路径已有 WARN，全链路可观测
      hilog.info(0x0001, 'HeroRectUtils',
        'captureRectPx ok id=%{public}s l=%{public}d t=%{public}d w=%{public}d h=%{public}d',
        id, Math.round(rect.left), Math.round(rect.top), Math.round(rect.width), Math.round(rect.height));
      return rect;
    } catch (_err) {
      hilog.warn(0x0001, 'HeroRectUtils', 'captureRectPx failed id=%{public}s', id);
      return null;
    }
  }
}

/** 详情页 hero 动画状态（三层盒结构：盒裁剪 + 内容冻结 + 飞行标题覆盖层，Top 基准坐标） */
@ObservedV2
export class HeroDetailAnim {
  /** 盒缩放系数（初态 = 卡片封面 → 目标内容的适配比例） */
  @Trace scaleValue: number = 1;
  /** 盒平移 vp */
  @Trace translateX: number = 0;
  @Trace translateY: number = 0;
  /** 盒裁剪宽（飞行中数值冻结，静止态 '100%' 响应窗口变化） */
  @Trace clipWidth: Length = '100%';
  @Trace clipHeight: Length = '100%';
  /** 盒圆角 vp */
  @Trace radius: number = 0;
  /** 盒背景色数值（0 = 透明 → page_background 数值） */
  @Trace navBgColor: number = 0;
  /** 盒整体透明度（降级返回淡出用） */
  @Trace boxOpacity: number = 1;
  /** 页面标题透明度（飞行中由覆盖层接管，落位后显示） */
  @Trace titleOpacity: number = 1;
  /** 内容冻结宽（飞行中 W0 数值防重排，静止 '100%'） */
  @Trace contentWidth: Length = '100%';
  @Trace contentHeight: Length = '100%';
  /** 内容冻结层平移 vp（A2：POP 落位把播放区 Cover 映射进卡片可见窗——内容层
   *  随飞行平移，落位帧卡内恰为视频画面，播放区下方的标题/信息条被移出裁剪窗；
   *  PUSH 全程与静止态恒 0） */
  @Trace contentTranslateX: number = 0;
  @Trace contentTranslateY: number = 0;
  /** 飞行标题覆盖层可见性 */
  @Trace overlayVisible: boolean = false;
  @Trace overlayX: number = 0;
  @Trace overlayY: number = 0;
  @Trace overlayWidth: number = 0;
  /** 飞行标题盒高 vp（A4：卡片端=源卡标题盒高（定高 42 盒复刻垂直居中），
   *  标题栏端=真实标题行高；两端与源端文字重合，飞行中数值插值平滑过渡；
   *  恒正数，maxLines(2) 长文字在标题栏端被裁剪为可接受边角） */
  @Trace overlayHeight: number = 24;
  @Trace overlayFontSize: number = 15;
  @Trace overlayOpacity: number = 1;
  /** 飞行标题字色（0xAARRGGBB 数值：随飞行在卡片标题色与品牌栏白字间插值） */
  @Trace overlayFontColor: number = 0xFF222222;
}

/** 全屏播放页盒动画状态（宽/高/平移，中心基准；§3.1 后飞行恒为当前窗口内纯缩放，
 *  needsRotate 时代的 rotate -90 → 0 支路已删） */
@ObservedV2
export class PlayerBoxAnim {
  @Trace width: Length = '100%';
  @Trace height: Length = '100%';
  @Trace translateX: number = 0;
  @Trace translateY: number = 0;
}

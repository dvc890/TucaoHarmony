/**
 * 搜索页（大屏 UX 适配）
 * - 输入即搜：回车（搜索键）或「搜索」按钮当场出结果；带关键词进页自动搜
 * - TagFilter 双筛选：频道（全部分类/动画/音乐/游戏/三次元/影剧/新番）+ 排序
 * - 历史态：历史标签点击回搜、单条删除（×）、清空输入回到历史态
 *   （SM 标签云基线；MD+ 关键词多列小卡 3/4/6 列，限宽 720 居中）
 * - 结果态：下拉刷新、触底翻页；空态「什么也没有找到~」
 *   （撤  缩进壳；SM 单列行基线；MD/LG/XL 全宽视频卡网格 3/4/6 列，
 *    照搬 ChannelDetail 网格写法）
 * - 输入簇：SM 全宽基线；MD+ 限宽 720 居中（不再满窗拉伸）
 * - 结果行卡：hero 双 rect 采集进播放页（失败降级普通跳转）+ 悬停帧轮播（previewFrames 为空休眠）
 * - 水波转场（R3 收尾版，双向）：悬浮球入口携带 SearchRevealParam（圆心/直径 px）时，
 *   进入=内容层 clipShape 圆形裁剪直径逐帧扩张至全屏 + 波前沿圆（实心主题色，
 *   直径随裁剪同步扩张、透明度 1→0）渐隐露出内容——"波前沿始终是色、色后露出
 *   内容"的水波质感；退出=同一机制反向（直径收拢至 FAB 位、透明度 0→1 渐现
 *   实心），色波吞回悬浮球。中途返回（POP 打断在飞进入）例外：不反向收拢
 *   （在飞动画上二次 animateTo 同属性接管异常，设备实测整页冻结），放行进入
 *   自然播完以完成态持有至超时收尾。动画全程在自定义转场窗口内播完（转场
 *   保持开启，源页首页持续可见），收尾交由注册超时（唯一合法 finish，见
 *   HeroAnimateCallback 契约）；注册生命周期保持到页面销毁（退出收拢依赖
 *   POP 回调）。
 *   无参入口（关键词字符串/空）不注册，系统默认转场行为不变
 * - 路由：router_map.json → SearchBuilder（param = keyword 字符串或
 *   { keyword, revealParam } 轻量对象）
 */
import { CircleShape } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Router, SearchRevealParam } from '../common/Router';
import { SearchVM } from '../viewmodel/SearchVM';
import { Video } from '../model/entity/BaseEntities';
import { SearchChannelFilter, SortOrder, SortOrderText } from '../common/Constants';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { ContentWidth, VideoGridColumns } from '../common/BreakpointLayout';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { EmptyView } from '../components/EmptyView';
import { NetworkImage } from '../components/NetworkImage';
import { TagFilter } from '../components/TagFilter';
import { VideoGridView } from '../components/VideoGridView';
import { PlayCountText, HoverPreviewController } from '../views/home/VideoCardView';
import { HeroCardParam, HeroRectUtils, HeroSource, HeroSourceState, HeroAnimateCallback, HeroTransition, RectPx } from '../common/HeroTransition';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function SearchBuilder(name: string, param: Object) {
  SearchPage({ routeParam: param })
}

/** 结果行卡 hero 转场起始圆角：与封面 borderRadius(radius_card=12fp) 一致 */
const SEARCH_ROW_CORNER_RADIUS: number = 12;

/** 水波进入时长 ms（FAB 同位实心圆 → 扩散覆盖全屏；对齐安卓 search_enter
 *  400ms linear_out_slow_in，取 450） */
const SEARCH_REVEAL_ENTER_DURATION_MS: number = 450;
/** 水波退出时长 ms（全屏收拢回 FAB 位；search_return 600ms 偏慢，取 400 更跟手） */
const SEARCH_REVEAL_EXIT_DURATION_MS: number = 400;
/** 进入转场注册超时 ms（= 唯一合法 finish，契约见 HeroAnimateCallback：
 *  进入动画 450ms + 余量兜底，转场全程保持开启让源页可见） */
const SEARCH_REVEAL_ENTER_TIMEOUT_MS: number = 600;
/** 退出转场注册超时 ms（退出动画 400ms + 余量兜底） */
const SEARCH_REVEAL_EXIT_TIMEOUT_MS: number = 550;

/** 圆形揭示几何（@AnimatableExtend 插值载体：直径/进度逐帧插值，圆心恒定）。
 *  @ObservedV2+@Trace：V2 观察体系下动画逐帧刷新依赖类字段级观察（faqs-arkui-565 同构指引） */
@ObservedV2
class SearchRevealGeom implements AnimatableArithmetic<SearchRevealGeom> {
  /** 圆心 x（页面内容区局部坐标 vp） */
  @Trace cx: number = 0;
  /** 圆心 y（页面内容区局部坐标 vp） */
  @Trace cy: number = 0;
  /** 揭示圆直径 vp */
  @Trace diameter: number = 0;
  /** 揭示进度 0→1：波前沿圆 opacity = 1 - progress（进入 1→0 渐隐露出内容 /
   *  退出 0→1 渐现实心）。与直径同载体插值 ⇒ 波前沿边缘与透明度逐帧严格同步 */
  @Trace progress: number = 0;

  constructor(cx: number, cy: number, diameter: number, progress: number) {
    this.cx = cx;
    this.cy = cy;
    this.diameter = diameter;
    this.progress = progress;
  }

  plus(rhs: SearchRevealGeom): SearchRevealGeom {
    return new SearchRevealGeom(this.cx + rhs.cx, this.cy + rhs.cy,
      this.diameter + rhs.diameter, this.progress + rhs.progress);
  }

  subtract(rhs: SearchRevealGeom): SearchRevealGeom {
    return new SearchRevealGeom(this.cx - rhs.cx, this.cy - rhs.cy,
      this.diameter - rhs.diameter, this.progress - rhs.progress);
  }

  multiply(scale: number): SearchRevealGeom {
    return new SearchRevealGeom(this.cx * scale, this.cy * scale,
      this.diameter * scale, this.progress * scale);
  }

  equals(rhs: SearchRevealGeom): boolean {
    return this.cx === rhs.cx && this.cy === rhs.cy
      && this.diameter === rhs.diameter && this.progress === rhs.progress;
  }
}

/** 内容层圆形揭示裁剪：clipShape 的形状几何非原生可动画属性，经自定义可动画属性逐帧驱动；
 *  圆形经 .offset 锚定悬浮球圆心，直径随插值扩张（官方 faqs-arkui-558 同构方案） */
@AnimatableExtend(Column)
function circularReveal(geom: SearchRevealGeom) {
  .clipShape(new CircleShape({ width: geom.diameter, height: geom.diameter })
    .offset({ x: geom.cx - geom.diameter / 2, y: geom.cy - geom.diameter / 2 }))
}

@ComponentV2
struct SearchPage {
  /** 路由参数（keyword 字符串，aboutToAppear 收窄；空则进历史态） */
  @Param routeParam: Object = new Object();

  /** 页面级实例：每次进页重置 */
  @Local vm: SearchVM = new SearchVM();

  /** 频道筛选选项（标签取自 SearchChannelFilter.ALL） */
  private channelTids: string[] = ['0', '19', '20', '21', '22', '23', '24'];
  private channelLabels: string[] = [];
  /** 排序选项（取自 SortOrder/SortOrderText） */
  private orders: SortOrder[] = [SortOrder.DATE, SortOrder.MUKIO, SortOrder.PLAY];
  private orderLabels: string[] = [];
  /** 窗口断点（SM/MD+ 分支切换） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  /** 水波转场（R3）：裁剪分支开关——进入/退出动画期间为 true，进入完毕回落常态分支
   *  （无常驻 clip 开销）；退出起播时从常态分支切回（全屏 clip ≡ 无 clip，无跳变） */
  @Local revealOn: boolean = false;
  /** 揭示几何（恒有实例；动画由实例替换 + animateTo 逐帧插值驱动，见 circularReveal） */
  @Local revealGeom: SearchRevealGeom = new SearchRevealGeom(0, 0, 0, 0);
  /** 起点几何（FAB 同位小圆，progress=0）：进入 t=0 / 退出 t=1 */
  private revealStartGeom: SearchRevealGeom = new SearchRevealGeom(0, 0, 0, 0);
  /** 终态几何（直径覆盖全屏，progress=1）：进入 t=1 / 退出 t=0 */
  private revealFinalGeom: SearchRevealGeom = new SearchRevealGeom(0, 0, 0, 0);
  /** 转场注册页 id（注册保持到页面销毁——退出收拢依赖 POP 回调，进入完毕不注销） */
  private revealPageId: string = '';
  /** 进入动画在飞标记：playRevealEnter 起播置 true、其 onFinish 清 false。
   *  中途返回（POP 打断在飞进入）的判定依据 */
  private revealEntering: boolean = false;
  /** 退出已接管标记：进入 onFinish 不得翻 revealOn——中途返回时翻分支会弃
   *  裁剪/波前终态，闪现整页无裁剪内容（设备实测确认） */
  private revealExiting: boolean = false;

  aboutToAppear(): void {
    for (let i = 0; i < this.channelTids.length; i++) {
      const tid: string = this.channelTids[i];
      this.channelLabels.push(SearchChannelFilter.ALL[tid] ?? tid);
    }
    for (let i = 0; i < this.orders.length; i++) {
      this.orderLabels.push(SortOrderText.of(this.orders[i]));
    }
    this.vm.loadHistory();
    // 路由参数收窄：字符串 = 初始关键词（Showtime/Rank/Ctrl+F 入口，行为不变）；
    // 对象 = { keyword, revealParam? }（悬浮球水波揭示入口）
    const param: Object = this.routeParam;
    if (typeof param === 'string' && param.length > 0) {
      this.vm.search(param);
    } else if (param !== null && typeof param === 'object') {
      const record: Record<string, Object> = param as Record<string, Object>;
      const keywordValue: Object = record['keyword'];
      if (typeof keywordValue === 'string' && keywordValue.length > 0) {
        this.vm.search(keywordValue);
      }
      const revealValue: Object | undefined = record['revealParam'];
      if (revealValue !== undefined && revealValue !== null) {
        this.setupReveal(revealValue as SearchRevealParam);
      }
    }
  }

  aboutToDisappear(): void {
    // 注册生命周期保持到页面销毁（进入完毕不注销——退出收拢需要 POP 回调）
    this.unregisterReveal();
  }

  /** 揭示几何就位：px 窗口坐标 → 页面内容区局部 vp（扣除 Index 壳层顶部避让），
   *  预计算双向几何——起点（FAB 同位小圆）与终态（直径覆盖全屏，含顶栏
   *  expandSafeArea 延伸区），进入与退出共用（退出即反向插值） */
  private setupReveal(param: SearchRevealParam): void {
    const density: number = this.windowSize.density;
    if (density <= 0 || param.diameterPx <= 0) {
      return;
    }
    const padTop: number = this.windowSize.shellPadTopVp;
    const cx: number = param.centerXpx / density;
    const cy: number = param.centerYpx / density - padTop;
    const d0: number = param.diameterPx / density;
    const w: number = this.windowSize.windowWidthVp;
    const h: number = this.windowSize.windowHeightVp - padTop - this.windowSize.shellPadBottomVp;
    const topExtend: number = -this.windowSize.statusBarHeightVp;
    const maxDist: number = Math.max(
      Math.sqrt(cx * cx + (cy - topExtend) * (cy - topExtend)),
      Math.sqrt((w - cx) * (w - cx) + (cy - topExtend) * (cy - topExtend)),
      Math.sqrt(cx * cx + (h - cy) * (h - cy)),
      Math.sqrt((w - cx) * (w - cx) + (h - cy) * (h - cy))
    );
    this.revealStartGeom = new SearchRevealGeom(cx, cy, d0, 0);
    this.revealGeom = new SearchRevealGeom(cx, cy, d0, 0);
    this.revealFinalGeom = new SearchRevealGeom(cx, cy, 2 * maxDist, 1);
    this.revealOn = true;
    // 不设自启兜底定时器：转场回调（onReady 注册 → Index 统一驱动）是唯一动画
    // 起播源，转场自身注册超时即收尾兜底；时序异常路径见 onReady 降级处理
  }

  /** 进入水波：转场回调内起播，动画全程在转场窗口内播完（转场保持开启，源页
   *  首页持续可见，圆外透出首页=真水波）。首帧基线（FAB 同位小圆裁剪 + 同位
   *  实心波前沿）由 aboutToAppear 预置；同一条 animateTo 驱动全部揭示绑定插值
   *  ——裁剪直径扩张 + 波前沿渐隐（progress 0→1 ⇒ 波前沿 opacity 1→0，
   *  同一插值载体，直径与透明度逐帧严格同步） */
  private playRevealEnter(): void {
    if (!this.revealOn) {
      return;
    }
    hilog.info(0x0000, 'TucaoSearch', 'playRevealEnter d0=%{public}d', this.revealStartGeom.diameter);
    this.revealEntering = true;
    this.getUIContext().animateTo({
      duration: SEARCH_REVEAL_ENTER_DURATION_MS,
      curve: Curve.LinearOutSlowIn,
      onFinish: (): void => {
        this.revealEntering = false;
        if (this.revealExiting) {
          // 中途返回：退出已接管（转场等注册超时收尾），保持裁剪分支与终态
          // 几何让页面以「揭示完成态」持有至 POP——翻状态会闪现整页无裁剪内容
          return;
        }
        // 只切回无裁剪常态分支（无常驻 clip 开销），不注销注册——退出收拢仍需
        // POP 回调；转场收尾由注册超时（唯一合法 finish）兜底
        this.revealOn = false;
      }
    }, (): void => {
      this.revealGeom = this.revealFinalGeom;
    });
  }

  /** 退出水波：色波反向吞回悬浮球。常态分支（进入已完成）先无动画切回裁剪
   *  分支：全屏 clip ≡ 无 clip、波前沿全透明（progress=1），无视觉跳变。
   *  中途返回（进入在飞）不反向收拢：在飞进入动画上二次 animateTo 同属性，
   *  设备实测接管异常——内容层裁剪冻结在打断值（整页内容外露）、波前沿跳
   *  终值（孤立实心圆盘），页面冻结 0.5s+ 直到 POP。改为放行进入动画自然
   *  播完（起播必早于 POP，450ms < 退出注册超时 550ms，必先于收尾落位），
   *  揭示以完成态持有至超时 finish → 系统落回首页。
   *  不设 onFinish：终帧（FAB 同位实心波前沿）须保持到转场注册超时收尾、页面
   *  销毁——翻状态会闪现整页内容 */
  private playRevealExit(): void {
    if (!this.revealOn) {
      this.revealOn = true;
      this.revealGeom = this.revealFinalGeom;
    }
    if (this.revealEntering) {
      // 中途返回：只护住进入 onFinish 不翻分支（见 playRevealEnter），
      // 揭示完成态持有至注册超时收尾
      this.revealExiting = true;
      hilog.info(0x0000, 'TucaoSearch', 'playRevealExit skip: enter in flight');
      return;
    }
    hilog.info(0x0000, 'TucaoSearch', 'playRevealExit d=%{public}d', this.revealGeom.diameter);
    this.getUIContext().animateTo({
      duration: SEARCH_REVEAL_EXIT_DURATION_MS,
      curve: Curve.FastOutLinearIn
    }, (): void => {
      this.revealGeom = this.revealStartGeom;
    });
  }

  /** 注销转场注册：仅页面销毁时调用（进入完毕不注销——退出收拢依赖回调） */
  private unregisterReveal(): void {
    if (this.revealPageId.length > 0) {
      HeroTransition.unregister(this.revealPageId);
      this.revealPageId = '';
    }
  }

  private get channelIndex(): number {
    const idx: number = this.channelTids.indexOf(this.vm.tid);
    return idx >= 0 ? idx : 0;
  }

  private get orderIndex(): number {
    const idx: number = this.orders.indexOf(this.vm.order);
    return idx >= 0 ? idx : 0;
  }

  build() {
    NavDestination() {
      Stack() {
        if (this.revealOn) {
          // 内容层：圆形揭示裁剪，圆心锚定悬浮球，直径逐帧扩张至全屏。
          //  不设背板层——转场期间圆外透出下层首页（真·水波，NavDestination
          //  已透明化），圆内底色由本层自带 page_background 负责
          Column() {
            this.SearchTopbar()
            this.SearchBody()
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.page_background'))
          .circularReveal(this.revealGeom)

          // 波前沿层（用户设计§〇，替代原衔接圆片+描边环两层）：整屏主题色层
          //  经同一 circularReveal 裁剪出实心波前沿圆——与内容裁剪绑定同一
          //  revealGeom、走同一 @AnimatableExtend 插值与 paint 渲染管线，
          //  波前沿边缘与 clip 边界逐帧严格重合（同一插值实例，构造性同步）；
          //  opacity = 1 - progress（paint 域属性，与裁剪同管线，实测逐帧同步）。
          //  进入 1→0 渐隐露出内容（波前沿始终是色、色后露出内容）/ 退出
          //  0→1 渐现实心（色波吞回 FAB）。
          //  注：不可改用 Circle+width/height/position——布局属性动画走 UI 线程
          //  布局管线，转场高负载下滞后 paint 域裁剪 ~3-10 帧（设备实测波前出现
          //  60-90vp 未着色内容超前带），两管线不可混用于同一波前沿
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.brand'))
            .circularReveal(this.revealGeom)
            .opacity(1 - this.revealGeom.progress)
            .hitTestBehavior(HitTestMode.None)
        } else {
          // 常态（无参入口 / 进入揭示完毕）：无裁剪，结构与原布局一致
          Column() {
            this.SearchTopbar()
            this.SearchBody()
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.page_background'))
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    // NavDestination 默认白底不透明，会在转场期间顶掉下层首页（圆外露白而非首页）。
    // 透明化后：进入/退出全程圆外透出首页=真·水波（§〇 前提）；常态由内容层
    // page_background 整屏遮盖，透明底不外露。
    .backgroundColor(Color.Transparent)
    .onReady((context: NavDestinationContext): void => {
      if (!this.revealOn) {
        // 无参入口（Ctrl+F/Showtime/Rank 带词）：不注册，系统默认转场
        return;
      }
      const pageId: string = context.navDestinationId ?? '';
      if (pageId.length === 0) {
        // 极端时序降级：回常态分支 + 系统默认转场（不注册，避免卡死在小圆基线）
        this.revealOn = false;
        return;
      }
      this.revealPageId = pageId;
      const callback: HeroAnimateCallback = new HeroAnimateCallback();
      callback.animation = (isPush: boolean): void => {
        // 水波替代系统推入/弹出转场：动画全程在转场窗口内播完（转场保持开启，
        // 源页首页持续可见）；收尾交由注册超时（唯一合法 finish，契约见
        // HeroAnimateCallback）——B2 重构后 transitionProxy 参数已移除，页面
        // 侧不持有收尾入口。进入完毕不注销注册：POP 时反向收拢仍需本回调
        if (isPush) {
          this.playRevealEnter();
        } else {
          this.playRevealExit();
        }
      };
      // 注册超时 = 唯一合法 finish：进入 450ms / 退出 400ms 动画 + 余量兜底
      callback.timeout = SEARCH_REVEAL_ENTER_TIMEOUT_MS;
      callback.resolveTimeout = (isPush: boolean): number => {
        return isPush ? SEARCH_REVEAL_ENTER_TIMEOUT_MS : SEARCH_REVEAL_EXIT_TIMEOUT_MS;
      };
      HeroTransition.register(pageId, callback);
      hilog.info(0x0000, 'TucaoSearch', 'reveal registered pageId=%{public}s', pageId);
    })
  }

  /** 标题栏：返回 + 搜索框 + 搜索按钮（中性底；MD+ 输入簇限宽 720 居中） */
  @Builder
  SearchTopbar() {
        // ===== 标题栏：返回 + 搜索框 + 搜索按钮（中性底；MD+ 输入簇限宽 720 居中） =====
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

          // 输入簇包装：占满剩余宽度，MD+ 时把限宽输入簇居中（SM 全宽几何不变）
          Row() {
            Row({ space: $r('app.float.space_sm') }) {
              TextInput({ placeholder: '搜索视频', text: this.vm.keyword })
                .layoutWeight(1)
                .height(36)
                .backgroundColor($r('app.color.card_background'))
                .borderRadius($r('app.float.radius_button'))
                .padding({
                  left: $r('app.float.space_lg'),
                  right: $r('app.float.space_lg')
                })
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .placeholderFont({ size: $r('app.float.font_size_body') })
                .enterKeyType(EnterKeyType.Search)
                .onChange((text: string) => {
                  this.vm.onKeywordChange(text);
                })
                .onSubmit((enterKey: EnterKeyType) => {
                  this.vm.search(this.vm.keyword);
                })

              Text('搜索')
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.brand'))
                .padding($r('app.float.space_sm'))
                .onClick((): void => {
                  this.vm.search(this.vm.keyword);
                })
            }
            .width('100%')
            .constraintSize({
              maxWidth: ContentWidth.cap(720, !this.windowSize.isCompact())
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_sm'),
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })
        // 全局沉浸：topbar 底色仅扩展绘制延伸到状态栏下（不改布局，内容绝对位置不变）
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  /** 内容区：历史态（SM 标签云 / MD+ 多列小卡）或结果态（SM 单列行 / MD+ 全宽网格） */
  @Builder
  SearchBody() {
        // ===== 内容区 =====
        if (!this.vm.inSearchMode) {
          // ----- 历史态 -----
          Scroll() {
            Column() {
              if (this.vm.history.length === 0) {
                EmptyView({ message: '暂无搜索历史' })
              } else {
                Text('搜索历史')
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .padding({
                    left: $r('app.float.space_lg'),
                    top: $r('app.float.space_sm'),
                    bottom: $r('app.float.space_sm')
                  })

                if (this.windowSize.isCompact()) {
                  // SM 基线：标签云
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.vm.history, (keyword: string) => {
                      Row({ space: $r('app.float.space_xs') }) {
                        Text(keyword)
                          .fontSize($r('app.float.font_size_caption'))
                          .fontColor($r('app.color.text_primary'))
                          .maxLines(1)
                          .constraintSize({ maxWidth: 180 })
                          .padding({
                            left: $r('app.float.space_md'),
                            top: $r('app.float.space_xs'),
                            bottom: $r('app.float.space_xs')
                          })
                          .onClick((): void => {
                            this.vm.search(keyword);
                          })
                        Text('×')
                          .fontSize($r('app.float.font_size_caption'))
                          .fontColor($r('app.color.text_tertiary'))
                          .padding({
                            right: $r('app.float.space_md'),
                            top: $r('app.float.space_xs'),
                            bottom: $r('app.float.space_xs')
                          })
                          .onClick((): void => {
                            this.vm.removeHistory(keyword);
                          })
                      }
                      .backgroundColor($r('app.color.card_background'))
                      .borderRadius($r('app.float.radius_button'))
                      .margin({
                        left: $r('app.float.space_sm'),
                        bottom: $r('app.float.space_sm')
                      })
                    }, (keyword: string) => keyword)
                  }
                  .width('100%')
                  .padding({
                    left: $r('app.float.space_sm'),
                    right: $r('app.float.space_sm'),
                    bottom: $r('app.float.space_lg')
                  })
                } else {
                  // MD+ 关键词多列小卡（3/4/6 列），容器限宽 720 居中
                  Column() {
                    Grid() {
                      ForEach(this.vm.history, (keyword: string) => {
                        GridItem() {
                          Row() {
                            Text(keyword)
                              .fontSize($r('app.float.font_size_body'))
                              .fontColor($r('app.color.text_primary'))
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                              .layoutWeight(1)
                              .onClick((): void => {
                                this.vm.search(keyword);
                              })
                            Text('×')
                              .fontSize($r('app.float.font_size_body'))
                              .fontColor($r('app.color.text_tertiary'))
                              .padding({ left: $r('app.float.space_sm') })
                              .onClick((): void => {
                                this.vm.removeHistory(keyword);
                              })
                          }
                          .width('100%')
                          .padding({
                            left: $r('app.float.space_md'),
                            right: $r('app.float.space_md'),
                            // 平板触控目标加厚（SM 标签云保持 8fp 基线不动）：
                            // 12+15+12 ≈ 45vp，接近 48vp 推荐触控高
                            top: $r('app.float.space_md'),
                            bottom: $r('app.float.space_md')
                          })
                          .backgroundColor($r('app.color.card_background'))
                          .borderRadius($r('app.float.radius_card'))
                        }
                      }, (keyword: string) => keyword)
                    }
                    .columnsTemplate(VideoGridColumns.template(this.windowSize.breakpoint))
                    .columnsGap($r('app.float.space_sm'))
                    .rowsGap($r('app.float.space_sm'))
                    .width('100%')
                  }
                  .width('100%')
                  .constraintSize({ maxWidth: 720 })
                  .padding({
                    left: $r('app.float.space_md'),
                    right: $r('app.float.space_md'),
                    bottom: $r('app.float.space_lg')
                  })
                }
              }
            }
            .width('100%')
          }
          .layoutWeight(1)
          // Scroll+layoutWeight 内容不足视口时默认垂直居中（官方 FAQ faqs-arkui-725），
          // 历史条目少时"搜索历史"标题悬浮半空 → 顶部对齐修正
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
        } else {
          // ----- 结果态（撤  缩进壳；SM 单列行基线 / MD+ 全宽网格） -----
          if (this.windowSize.isCompact()) {
            // SM 基线：单列行（原结构）
            Column() {
              TagFilter({
                labels: this.channelLabels,
                selectedIndex: this.channelIndex,
                onSelect: (index: number) => {
                  this.vm.changeTid(this.channelTids[index]);
                }
              })
              TagFilter({
                labels: this.orderLabels,
                selectedIndex: this.orderIndex,
                onSelect: (index: number) => {
                  this.vm.changeOrder(this.orders[index]);
                }
              })

              if (this.vm.searching && !this.vm.searchedOnce) {
                LoadingState({ message: '正在搜索…' })
              } else if (this.vm.error.length > 0 && !this.vm.searchedOnce) {
                ErrorRetry({
                  message: this.vm.error,
                  onRetry: (): void => {
                    this.vm.refresh();
                  }
                })
              } else if (this.vm.videos.length === 0) {
                EmptyView({ message: '什么也没有找到~' })
              } else {
                Refresh({ refreshing: this.vm.refreshing }) {
                  List({ space: 12 }) {
                    Repeat(this.vm.videos)
                      .each((repeatItem: RepeatItem<Video>) => {
                        ListItem() {
                          SearchRowView({ video: repeatItem.item })
                        }
                      })
                      .key((video: Video, index: number) => `${video.hid}-${index}`)
                      .virtualScroll({ totalCount: this.vm.videos.length })

                    // 加载更多尾态
                    if (this.vm.loadingMore) {
                      ListItem() {
                        LoadingState({ message: '加载中…' })
                      }
                    } else if (this.vm.noMore) {
                      ListItem() {
                        Text('没有更多了')
                          .fontSize($r('app.float.font_size_caption'))
                          .fontColor($r('app.color.text_tertiary'))
                          .width('100%')
                          .textAlign(TextAlign.Center)
                          .padding($r('app.float.space_md'))
                      }
                    }

                    // 追加失败提示（列表非空时的错误）
                    if (this.vm.error.length > 0) {
                      ListItem() {
                        Text(this.vm.error)
                          .fontSize($r('app.float.font_size_caption'))
                          .fontColor($r('app.color.text_tertiary'))
                          .width('100%')
                          .textAlign(TextAlign.Center)
                          .padding($r('app.float.space_sm'))
                      }
                    }
                  }
                  .width('100%')
                  .layoutWeight(1)
                  // 防御性顶对齐（与历史态 Scroll、VideoGridView 同款写法）。
                  // 注：item"撑满居中"错乱的真正根因不在 List 容器，而在
                  // SearchRowView 标题的 layoutWeight（分配基准是父容器约束上限
                  // 而非内容需求，唯一 item 时把整行撑到视口高）——已去除，见
                  // search-row-title 处注释
                  .align(Alignment.Top)
                  .scrollBar(BarState.Off)
                  .edgeEffect(EdgeEffect.None)
                  .onReachEnd(() => {
                    this.vm.loadMore();
                  })
                }
                .onRefreshing(() => {
                  this.vm.refresh();
                })
                .width('100%')
                .layoutWeight(1)
              }
            }
            .width('100%')
            .layoutWeight(1)
          } else {
            // MD/LG/XL 全宽视频卡网格 3/4/6 列（照搬 ChannelDetail 网格写法）
            Refresh({ refreshing: this.vm.refreshing }) {
              Column() {
                TagFilter({
                  labels: this.channelLabels,
                  selectedIndex: this.channelIndex,
                  onSelect: (index: number) => {
                    this.vm.changeTid(this.channelTids[index]);
                  }
                })
                TagFilter({
                  labels: this.orderLabels,
                  selectedIndex: this.orderIndex,
                  onSelect: (index: number) => {
                    this.vm.changeOrder(this.orders[index]);
                  }
                })

                if (this.vm.searching && !this.vm.searchedOnce) {
                  LoadingState({ message: '正在搜索…' })
                } else if (this.vm.error.length > 0 && !this.vm.searchedOnce) {
                  ErrorRetry({
                    message: this.vm.error,
                    onRetry: (): void => {
                      this.vm.refresh();
                    }
                  })
                } else if (this.vm.videos.length === 0) {
                  EmptyView({ message: '什么也没有找到~' })
                } else {
                  VideoGridView({
                    videos: this.vm.videos,
                    onReachEnd: (): void => {
                      this.vm.loadMore();
                    }
                  })

                  // 加载更多尾态
                  if (this.vm.loadingMore) {
                    LoadingState({ message: '加载中…' })
                  } else if (this.vm.noMore) {
                    Text('没有更多了')
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor($r('app.color.text_tertiary'))
                      .width('100%')
                      .textAlign(TextAlign.Center)
                      .padding($r('app.float.space_md'))
                  }

                  // 追加失败提示（列表非空时的错误）
                  if (this.vm.error.length > 0) {
                    Text(this.vm.error)
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor($r('app.color.text_tertiary'))
                      .width('100%')
                      .textAlign(TextAlign.Center)
                      .padding($r('app.float.space_sm'))
                  }
                }
              }
              .width('100%')
              .height('100%')
            }
            .onRefreshing(() => {
              this.vm.refresh();
            })
            .width('100%')
            .layoutWeight(1)
          }
        }
  }
}

/** 搜索结果行：封面 + 标题 + 播放数；点击进播放页（hero 采集 + 悬停帧轮播） */
@ComponentV2
struct SearchRowView {
  @Param video: Video = new Video();
  /** hero 转场源状态（activeToken 命中本行实例时隐藏封面/文字块） */
  @Local heroSource: HeroSourceState = HeroSource.getState();
  /** 本行实例 token（构造时一次性取号；同 hid 多实例时区分采集与隐藏目标） */
  private heroToken: string = HeroTransition.nextSourceToken();
  /** 悬停帧轮播控制器（搜索结果走 api_v2 JSON，暂无 previewFrames 字段时空数组休眠） */
  private hoverPreview: HoverPreviewController = new HoverPreviewController();
  /** 长按触发轮播后抑制随后的 onClick（长按成功后释放仍会派发点击）；下次按下复位 */
  private suppressClickAfterLongPress: boolean = false;

  /** hero 封面节点 id（hid + 实例 token，全树唯一） */
  private coverNodeId(): string {
    return `search-row-cover-${this.video.hid}-${this.heroToken}`;
  }

  /** hero 标题节点 id（hid + 实例 token，全树唯一） */
  private titleNodeId(): string {
    return `search-row-title-${this.video.hid}-${this.heroToken}`;
  }

  aboutToDisappear(): void {
    this.hoverPreview.stop();
  }

  /** 虚拟滚动节点换绑条目时终止旧轮播，防止帧地址串卡 */
  @Monitor('video')
  onItemRebind(): void {
    this.hoverPreview.stop();
  }

  /** 点击进详情：双 rect 采集成功 → hero 连续缩放转场；任一失败 → 普通跳转 */
  private openDetail(): void {
    // 路由前清场：终止本行（或全局任意卡）悬停轮播
    HoverPreviewController.stopActive();
    const coverRect: RectPx | null =
      HeroRectUtils.captureRectPx(this.getUIContext(), this.coverNodeId());
    const titleRect: RectPx | null =
      HeroRectUtils.captureRectPx(this.getUIContext(), this.titleNodeId());
    if (coverRect === null || titleRect === null) {
      Router.goVideoDetail(this.video.hid);
      return;
    }
    const heroParam: HeroCardParam = new HeroCardParam();
    heroParam.coverRect = coverRect;
    heroParam.titleRect = titleRect;
    heroParam.title = this.video.title;
    heroParam.coverUrl = this.video.thumb;
    heroParam.cornerRadius = SEARCH_ROW_CORNER_RADIUS;
    heroParam.coverId = this.coverNodeId();
    heroParam.titleId = this.titleNodeId();
    heroParam.sourceToken = this.heroToken;
    this.heroSource.markSource(this.heroToken);
    Router.goVideoDetailWithTransition(this.video.hid, heroParam);
  }

  build() {
    Row({ space: $r('app.float.space_md') }) {
      // 尺寸挂 Stack（内置节点）而非 NetworkImage 宿主：轮播换帧重建 option 时宿主
      // 测量会退化为内容尺寸，fit-content Stack 随之撑满父行、标题列被挤没（对齐
      // VideoCardView 网格卡模式）
      Stack({ alignContent: Alignment.TopEnd }) {
        NetworkImage({
          url: this.hoverPreview.displayUrl(this.video.thumb),
          imageWidth: '100%',
          imageHeight: '100%',
          fit: ImageFit.Cover
        })
          .aspectRatio(1.6)
          .borderRadius($r('app.float.radius_card'))

        // 悬停轮播帧进度指示（底部细进度条，静态封面态不渲染）
        if (this.hoverPreview.state.frameIndex >= 0 && this.hoverPreview.state.frameCount > 0) {
          Row() {
            Blank()
            Progress({
              value: this.hoverPreview.state.frameIndex + 1,
              total: this.hoverPreview.state.frameCount,
              type: ProgressType.Linear
            })
              .width('38%')
              .height(3)
              .color(Color.White)
              .backgroundColor('rgba(255,255,255,0.35)')
              .borderRadius(2)
          }
          .width('100%')
          .padding($r('app.float.space_xs'))
          .position({ x: 0, y: '100%' })
          .markAnchor({ x: 0, y: '100%' })
        }
      }
      .width(120)
      .aspectRatio(1.6)
      .id(this.coverNodeId())
      .visibility(this.heroSource.activeToken === this.heroToken
        ? Visibility.Hidden : Visibility.Visible)

      Column({ space: $r('app.float.space_xs') }) {
        Text(this.video.title)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 不设 layoutWeight：本 SDK（26.0.0）List 唯一/少量 item 时 ListItem 被拉伸
          // 撑满视口，layoutWeight 会把拉伸的剩余高度全部分给标题盒 → 标题撑满
          // 整列、播放数沉底（"撑满居中"错乱）。正常场景行高由封面撑住，
          // layoutWeight 本无作用，去掉后内容自适应永不变形
          .id(this.titleNodeId())

        Text(`▶ ${PlayCountText.format(this.video.play)}`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .visibility(this.heroSource.activeToken === this.heroToken
        ? Visibility.Hidden : Visibility.Visible)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({
      left: $r('app.float.space_lg'),
      right: $r('app.float.space_lg')
    })
    .onClick((): void => {
      if (this.suppressClickAfterLongPress) {
        this.suppressClickAfterLongPress = false;
        return;
      }
      if (this.video.hid.length > 0) {
        this.openDetail();
      }
    })
    .onHover((isHover: boolean) => {
      if (isHover) {
        this.hoverPreview.start(this.video.previewFrames);
      } else {
        this.hoverPreview.stop();
      }
    })
    // 长按即看：触屏无悬停能力，长按 500ms 直接触发预览轮播；松手/滚动手势打断即停
    .parallelGesture(LongPressGesture({ repeat: false, duration: 500 })
      .onAction((): void => {
        this.suppressClickAfterLongPress = true;
        this.hoverPreview.start(this.video.previewFrames, true);
      })
      .onActionEnd((): void => {
        this.hoverPreview.stop();
      })
      .onActionCancel((): void => {
        this.hoverPreview.stop();
      }))
    // 按下即复位长按抑制标志：滚动打断长按（无点击派发）后标志不残留
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.suppressClickAfterLongPress = false;
      }
    })
  }
}

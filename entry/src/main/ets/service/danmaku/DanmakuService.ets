/**
 * 弹幕服务
 *
 * 职责（对齐安卓 DanmuVideoPlayer.setUpDanmu / sendDanmu / configDanmuStyle）：
 * - 解析：TucaoDanmakuParser 将 Danmaku[] 装载为引擎弹幕集（在线 XML 与本地 danmu.xml 同源）
 * - 绑定：bindModel 为每页 Model 构建独立 DanmakuContext + 解析器（换集/换页重绑走 stop→prepare，
 *   引擎 PREPARE 轮询视图就绪后回调 prepared，届时 start(startMs) 并按播放态停靠）
 * - 样式：透明度/字号倍率/滚动速度热更新（倍速下按 config.danmakuSpeed * speed 补偿滚动节奏，
 *   对齐安卓 setSpeed 实现；时间轴跟随由 DanmakuVM 周期对齐）
 * - 屏蔽：KeywordBlockFilter 渲染期过滤（安卓为解析期过滤需重拉；本版 bump FILTER_RESET_FLAG
 *   全量重滤，屏上含屏蔽词弹幕立即消失）
 * - 发送：POST mukio post?playerID={id}（user=test / size=25 / mode=1 / color=16777215，
 *   tucao_verify cookie），静默失败；本地回显红字绿边、优先级 1、engineTime+1200ms
 */
import {
  BaseDanmaku,
  BaseDanmakuFilter,
  BaseDanmakuParser,
  Callback,
  DANMAKU_STYLE_STROKEN,
  DanmakuContext,
  DanmakuFactory,
  DanmakuTimer,
  DanmakuUtils,
  DanmakuViewV2,
  Danmakus,
  IDanmakus
} from '@ohos/danmakuflamemaster';
import { DanmuConst, RawApi } from '../../common/Constants';
import { PlayerConfig } from '../../model/entity/BaseEntities';
import { DanmakuMode, DanmakuPool, DanmakuPoolLoader } from '../../model/entity/DanmakuEntities';
import { PreferenceStore } from '../../data/PreferenceStore';
import { HtmlParseUtil } from '../api/HtmlParseUtil';
import { TucaoApiClient } from '../api/TucaoApiClient';
import { Danmaku } from '../../model/entity/BaseEntities';

/** tucao 弹幕解析器（对齐安卓 TucaoDanmukuParser；Danmaku[] → 引擎弹幕集） */
export class TucaoDanmakuParser extends BaseDanmakuParser {
  private readonly source: Danmaku[];

  constructor(source: Danmaku[]) {
    super();
    this.source = source;
  }

  protected parse(): IDanmakus {
    const result: Danmakus = new Danmakus({});
    if (this.mContext === null || this.mContext === undefined) {
      return result;
    }
    const context: DanmakuContext = this.mContext as DanmakuContext;
    // 预置工厂上下文：否则 createDanmaku 因 sLastConfig 缺失回退 3800ms 默认时长
    context.mDanmakuFactory.notifyDispSizeChanged(context);
    const factory: DanmakuFactory = context.mDanmakuFactory;
    for (let i = 0; i < this.source.length; i++) {
      const raw: Danmaku = this.source[i];
      const item: BaseDanmaku = factory.createDanmaku(DanmakuMode.normalize(raw.mode));
      // 必须回填 timer：否则 item.mTimer=null → isTimeOut()/isLate() 恒真，
      // 渲染器会把所有弹幕当超时直接 recycle 跳过，弹幕永远不渲染
      item.setTimer(this.getTimer());
      // 必须回填 flags（库 bug：仅 DrawHandler.addDanmaku 直播路径会赋值，parser 装载路径漏掉）：
      // 否则 item.flags=null → isShown()/isMeasured()/isPrepared() 恒 false，渲染门控跳过所有弹幕
      item.flags = context.mGlobalFlagValues;
      item.setTime(raw.stime);
      DanmakuUtils.fillText(item, HtmlParseUtil.decodeBasicEntities(raw.text));
      item.textColor = raw.color;
      // 安卓 textColor<=Color.BLACK 符号位比较的实际语义：纯黑(rgb=0)白描边，其余黑描边
      item.textShadowColor = raw.color === 0 ? 0xFFFFFFFF : 0xFF000000;
      item.textSize = raw.size * (this.mDispDensity - 0.6);
      result.addItem(item);
    }
    return result;
  }
}

/**
 * 关键词屏蔽过滤器（渲染期热更新）
 * 词表实时读取 PlayerConfig（blockEnable/blockList），reset/clear 不清空词表；
 * 命中时置自定义过滤位（内置占用 1~512，取 1024），供 isFiltered() 判定跳过。
 */
export class KeywordBlockFilter extends BaseDanmakuFilter<Object> {
  private static readonly FILTER_BIT_CUSTOM: number = 1024;
  private readonly config: PlayerConfig;

  constructor(config: PlayerConfig) {
    super();
    this.config = config;
  }

  filter(danmaku: BaseDanmaku, index: number, totalsizeInScreen: number,
    timer: DanmakuTimer, fromCachingTask: boolean, danmakuContext: DanmakuContext): boolean {
    if (!this.config.blockEnable) {
      return false;
    }
    const words: string[] = this.config.blockList;
    const text: string = danmaku.text;
    for (let i = 0; i < words.length; i++) {
      if (text.includes(words[i])) {
        danmaku.mFilterParam |= KeywordBlockFilter.FILTER_BIT_CUSTOM;
        return true;
      }
    }
    return false;
  }

  setData(data: Object | null): void {
    // 词表实时读取 PlayerConfig，无需 setData
  }

  reset(): void {
    // 词表归属 PlayerConfig，reset 不清空
  }
}

/** 单个 Model 的绑定记录 */
class ModelBinding {
  readonly model: DanmakuViewV2.Model;
  readonly context: DanmakuContext;

  constructor(model: DanmakuViewV2.Model, context: DanmakuContext) {
    this.model = model;
    this.context = context;
  }
}

/** 弹幕服务单例 */
export class DanmakuService {
  private static instance: DanmakuService | null = null;

  static getInstance(): DanmakuService {
    if (DanmakuService.instance === null) {
      DanmakuService.instance = new DanmakuService();
    }
    return DanmakuService.instance;
  }

  private constructor() {
  }

  private readonly blockFilter: KeywordBlockFilter =
    new KeywordBlockFilter(PreferenceStore.playerConfig());
  private readonly bindings: Map<DanmakuViewV2.Model, ModelBinding> = new Map();

  // ---------- 数据装载 ----------

  /** 拉取在线弹幕池（带会话级缓存；失败返回 error 置位的空池） */
  async fetchPool(playerId: string): Promise<DanmakuPool> {
    return DanmakuPoolLoader.fetchOnlinePool(playerId);
  }

  /** 读取本地弹幕池（OfflinePlayer：{downloadDir}/{hid}/p{order}/danmu.xml） */
  loadLocalPool(playerId: string, danmuPath: string): DanmakuPool {
    return DanmakuPoolLoader.loadLocalPool(playerId, danmuPath);
  }

  // ---------- 绑定/解绑 ----------

  /**
   * 绑定模型：构建独立 Context + 解析器并 prepare。
   * 引擎视图就绪后回调 prepared：start(startMs)，非播放态 pause() 停靠，弹幕关闭态 hide()。
   * 重复绑定（换集/换页）内部先 stop 再重建（引擎 stop 后 prepare 会重建 DrawHandler/DrawTask）。
   */
  bindModel(model: DanmakuViewV2.Model, pool: DanmakuPool, startMs: number,
    playing: boolean, speed: number, limitScrollLines: number): void {
    this.unbindModel(model);
    const playerConfig: PlayerConfig = PreferenceStore.playerConfig();
    const context: DanmakuContext = this.buildContext(playerConfig, limitScrollLines);
    this.applyStyle(context, playerConfig, speed);
    const parser: TucaoDanmakuParser = new TucaoDanmakuParser(pool.danmakus);
    const callback: Callback = {
      prepared: (): void => {
        model.start(startMs);
        if (!playing) {
          model.pause();
        }
        if (!playerConfig.danmakuOn) {
          model.hide();
        }
      },
      updateTimer: (_timer: DanmakuTimer): void => {
      },
      danmakuShown: (_danmaku: BaseDanmaku): void => {
      },
      drawingFinished: (): void => {
      }
    };
    model.setCallback(callback);
    this.bindings.set(model, new ModelBinding(model, context));
    model.prepare(parser, context);
  }

  /** 解绑并停止（引擎资源随 stop 释放；Context 无显式 release，交由 GC） */
  unbindModel(model: DanmakuViewV2.Model): void {
    if (this.bindings.has(model)) {
      this.bindings.delete(model);
      model.stop();
    }
  }

  // ---------- 配置热更新 ----------

  /** 样式/速度下发（对齐安卓 configDanmuStyle；倍速按 danmakuSpeed*speed 补偿滚动节奏） */
  applyStyle(context: DanmakuContext, config: PlayerConfig, speed: number): void {
    context.setDanmakuTransparency(config.danmakuOpacity)
      .setScaleTextSize(config.danmakuScale)
      .setScrollSpeedFactor(config.danmakuSpeed * speed);
  }

  /** 样式/速度热更新：fan-out 到所有存活绑定 */
  applyStyleToAll(config: PlayerConfig, speed: number): void {
    this.bindings.forEach((binding: ModelBinding) => {
      this.applyStyle(binding.context, config, speed);
      binding.model.forceRender();
    });
  }

  /** 屏蔽词/屏蔽开关热更新：bump 过滤标志触发全量重滤（含屏上弹幕立即消失） */
  applyBlocklistToAll(): void {
    this.bindings.forEach((binding: ModelBinding) => {
      binding.context.mGlobalFlagValues.updateFilterFlag();
      binding.model.forceRender();
    });
  }

  // ---------- 发送与回显 ----------

  /**
   * 发送弹幕（对齐安卓 RawApiService.sendDanmu：
   * POST index.php?m=mukio&c=index&a=post?playerID={id}，表单 cid=playerId/stime(秒)/message/
   * user=test/size=25/mode=1/color=16777215，tucao_verify cookie；响应忽略，静默失败）
   */
  async send(playerId: string, stimeSec: number, message: string): Promise<boolean> {
    const fields: Record<string, string> = {
      'cid': playerId,
      'stime': `${stimeSec}`,
      'message': message,
      'user': DanmuConst.DEFAULT_USER,
      'size': '25',
      'mode': `${DanmakuMode.SCROLL_RL}`,
      'color': '16777215'
    };
    const path: string = `${RawApi.SEND_DANMU}?playerID=${encodeURIComponent(playerId)}`;
    try {
      await TucaoApiClient.getInstance().postFormText(path, fields, true);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 本地回显弹幕（对齐安卓 sendDanmu：红字白影绿边、优先级 1、当前引擎时间 +1200ms） */
  createEchoDanmaku(context: DanmakuContext, currentTimeMs: number, text: string): BaseDanmaku {
    const item: BaseDanmaku = context.mDanmakuFactory.createDanmaku(DanmakuMode.SCROLL_RL);
    item.padding = 5;
    // priority>0：不参与重叠过滤、永不被过滤位跳过（安卓同款设定）
    item.priority = 1;
    item.isLive = false;
    item.setTime(currentTimeMs + 1200);
    DanmakuUtils.fillText(item, HtmlParseUtil.decodeBasicEntities(text));
    item.textColor = 0xFFFF0000;
    item.textShadowColor = 0xFFFFFFFF;
    item.textSize = 25 * (context.getDisplayer().getDensity() - 0.6);
    item.borderColor = 0xFF00FF00;
    return item;
  }

  // ---------- 内部 ----------

  private buildContext(config: PlayerConfig, limitScrollLines: number): DanmakuContext {
    const context: DanmakuContext = DanmakuContext.create();
    // 描边样式对齐安卓：DANMAKU_STYLE_STROKEN + 3.0 描边宽度
    context.setDanmakuStyle(DANMAKU_STYLE_STROKEN, 3.0)
      .setDuplicateMergingEnabled(false);
    // 半屏（详情页）限制滚动弹幕行数，对齐安卓非全屏 setMaximumLines(SCROLL_RL=5)
    if (limitScrollLines > 0) {
      const lines: Map<number, number> = new Map<number, number>();
      lines.set(BaseDanmaku.TYPE_SCROLL_RL, limitScrollLines);
      context.setMaximumLines(lines);
    }
    // 防重叠：滚动 + 顶部固定，对齐安卓 preventOverlapping 配置
    const overlapping: Map<number, boolean> = new Map<number, boolean>();
    overlapping.set(BaseDanmaku.TYPE_SCROLL_RL, true);
    overlapping.set(BaseDanmaku.TYPE_FIX_TOP, true);
    context.preventOverlapping(overlapping);
    // 屏蔽词过滤器（单实例跨 Context 共享：词表实时读 PlayerConfig，无会话态）
    context.registerFilter(this.blockFilter);
    return context;
  }
}

/*
 * Copyright (C) 2022 Huawei Device Co., Ltd.
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
import { AbsDisplayer } from '../danmaku/model/AbsDisplayer';
import { BaseDanmaku }from '../danmaku/model/BaseDanmaku';
import { DanmakuTimer }from '../danmaku/model/DanmakuTimer';
import { IDanmakus, Consumer, DefaultConsumer, ST_BY_LIST }from '../danmaku/model/IDanmakus';
import { DanmakuContext, ConfigChangedCallback, DanmakuConfigTag } from '../danmaku/model/ohos/DanmakuContext';
import { Danmakus }from '../danmaku/model/ohos/Danmakus';
import { BaseDanmakuParser, Listener }from '../danmaku/parser/BaseDanmakuParser';
import { IRenderer, RenderingState, OnDanmakuShownListener }from '../danmaku/renderer/IRenderer';
import { DanmakuRenderer } from '../danmaku/renderer/ohos/DanmakuRenderer';
import { IDrawTask, TaskListener } from './IDrawTask'
import DanmakuView from '../ui/widget/DanmakuView'
import { DanmakuFilters } from './DanmakuFilters'
import SystemClock from '../danmaku/util/SystemClock';
import { IRenderBackend }from '../danmaku/model/render/RenderMode';

let self: DrawTask | null = null;

class Config implements ConfigChangedCallback {
  public onDanmakuConfigChanged(config: DanmakuContext, tag: DanmakuConfigTag, values: Object[]): boolean {
    if (self != null) {
      return self.onDanmakuConfigChanged(config, tag, values);
    }
    return false;
  }
};

class OnDanMuKu implements OnDanmakuShownListener {
  private that: DrawTask;
  constructor(that: DrawTask) {
    this.that = that
  }
  public onDanmakuShown(danmaku: BaseDanmaku): void {
    if (this.that.mTaskListener != null) {
      this.that.mTaskListener.onDanmakuShown(danmaku);
    }
  }
};

class Remove extends DefaultConsumer<BaseDanmaku> {
  private that: DrawTask;

  constructor(that: DrawTask) {
    super();
    this.that = that
  }

  public accept(danmaku: BaseDanmaku): number {
    if (danmaku.isLive) {
      this.that.onDanmakuRemoved(danmaku);
      danmaku.releasePixelMaps();
      return Consumer.ACTION_REMOVE;
    }
    return Consumer.ACTION_CONTINUE;
  }

  public result(): Object | null {
    return null;
  }
}
class RemoveUnused extends DefaultConsumer<BaseDanmaku> {
  private that: DrawTask;
  private msec: number;

  constructor(that: DrawTask, msec: number) {
    super();
    this.that = that
    this.msec = msec
  }

  startTime: number = SystemClock.uptimeMillis();

  public accept(danmaku: BaseDanmaku): number {
    let isTimeout: boolean = danmaku.isTimeOut();
    if (SystemClock.uptimeMillis() - this.startTime > this.msec) {
      return Consumer.ACTION_BREAK;
    }
    if (isTimeout) {
      this.that.danmakuList?.removeItem(danmaku);
      this.that.onDanmakuRemoved(danmaku);
      danmaku.releasePixelMaps();
      return Consumer.ACTION_REMOVE;
    } else {
      return Consumer.ACTION_BREAK;
    }
  }

  public result(): Object | null {
    return null;
  }
}

class SubDanMu extends DefaultConsumer<BaseDanmaku> {
  private visibleDanmakus: IDanmakus;

  constructor(visibleDanmakus: IDanmakus) {
    super();
    this.visibleDanmakus = visibleDanmakus
  }

  public accept(danmaku: BaseDanmaku): number {
    if (danmaku.isShown() && !danmaku.isOutside()) {
      this.visibleDanmakus.addItem(danmaku);
    }
    return Consumer.ACTION_CONTINUE;
  }

  public result(): Object | null {
    return null;
  }
}

class LoadDanMu implements Listener {
  private that: DrawTask;

  constructor(that : DrawTask) {
    this.that = that
  }
  public onDanmakuAdd(danmaku: BaseDanmaku): void {
    if (this.that.mTaskListener != null) {
      this.that.mTaskListener.onDanmakuAdd(danmaku);
    }
  }
}

class Running extends DefaultConsumer<BaseDanmaku> {
  private offsetMills: number;

  constructor(offsetMills: number) {
    super();
    this.offsetMills = offsetMills
  }

  public accept(danmaku: BaseDanmaku): number {
    if (danmaku.isOutside()) {
      return Consumer.ACTION_REMOVE;
    }
    danmaku.setTimeOffset(this.offsetMills + danmaku.timeOffset);
    return Consumer.ACTION_CONTINUE;
  }

  public result(): Object | null {
    return null;
  }
}

export class DrawTask implements IDrawTask {
  protected mContext: DanmakuContext;
  protected mDisp: AbsDisplayer<IRenderBackend, string>;
  public danmakuList: IDanmakus | null = null;
  protected mParser: BaseDanmakuParser | null = null;
  mTaskListener: TaskListener;
  mRenderer: IRenderer | null = null;
  mTimer: DanmakuTimer | null = null;
  private danmakus: IDanmakus = new Danmakus({ sortType: ST_BY_LIST });
  protected clearRetainerFlag: boolean= false;
  private mStartRenderTime: number = 0;
  private mRenderingState: RenderingState = new RenderingState();
  protected mReadyState: boolean = false;
  private mLastBeginMills: number = 0;
  private mLastEndMills: number = 0;
  protected mPlayState: number = 0;
  private mIsHidden: boolean = false;
  private mLastDanmaku: BaseDanmaku | null = null;
  private mLiveDanmakus: Danmakus = new Danmakus({ sortType: ST_BY_LIST });
  private mRunningDanmakus: IDanmakus | null = null;
  private mRequestRender: boolean = false;
  private mConfigChangedCallback: ConfigChangedCallback = new Config()

  public constructor(timer: DanmakuTimer, context: DanmakuContext,
    taskListener: TaskListener) {
    if (context == null) {
      throw new Error("context is null");
    }
    self = this
    this.mContext = context;
    this.mDisp = context.getDisplayer();
    this.mTaskListener = taskListener;
    this.mRenderer = new DanmakuRenderer(context);
    this.mRenderer.setOnDanmakuShownListener(new OnDanMuKu(this))
    this.mRenderer.setVerifierEnabled(this.mContext.isPreventOverlappingEnabled() || this.mContext.isMaxLinesLimited());
    this.initTimer(timer);
    let enable: boolean = this.mContext.isDuplicateMergingEnabled();
    if (enable) {
      this.mContext.mDanmakuFilters.registerFilter({ tag: DanmakuFilters.TAG_DUPLICATE_FILTER });
    } else {
      this.mContext.mDanmakuFilters.unregisterFilter({ tag: DanmakuFilters.TAG_DUPLICATE_FILTER });
    }
  }

  protected initTimer(timer: DanmakuTimer): void {
    this.mTimer = timer;
  }

  public addDanmaku(item: BaseDanmaku): void {
    try {
      if (this.danmakuList === null)
        return;
      if (item.isLive) {
        this.mLiveDanmakus.addItem(item);
        this.removeUnusedLiveDanmakusIn(10);
      }
      item.index = this.danmakuList.size();
      let subAdded: boolean = true;
      if (this.mLastBeginMills <= item.getActualTime() && item.getActualTime() <= this.mLastEndMills) {
        subAdded = this.danmakus.addItem(item);
      } else if (item.isLive) {
        subAdded = false;
      }
      let added: boolean = false;
      added = this.danmakuList.addItem(item);
      if (!subAdded || !added) {
        this.mLastBeginMills = this.mLastEndMills = 0;
      }
      if (added && this.mTaskListener != null) {
        this.mTaskListener.onDanmakuAdd(item);
      }
      if (this.mLastDanmaku == null || (item != null && this.mLastDanmaku != null && item.getActualTime() > this.mLastDanmaku.getActualTime())) {
        this.mLastDanmaku = item;
      }
    } catch (error) {
      console.log('addDanmaku failed: ' + JSON.stringify(error));
    }
  }

  public invalidateDanmaku(item: BaseDanmaku, remeasure: boolean): void {
    if (this.mContext != null && this.mContext.getDisplayer() != null && this.mContext.getDisplayer().getCacheStuffer() != null) {
      this.mContext.getDisplayer().getCacheStuffer().clearCache(item);
    }
    item.requestFlags |= BaseDanmaku.FLAG_REQUEST_INVALIDATE;
    if (remeasure) {
      item.paintWidth = -1;
      item.paintHeight = -1;
      item.requestFlags |= BaseDanmaku.FLAG_REQUEST_REMEASURE;
      item.measureResetFlag++;
    }
  }

  public removeAllDanmakus(isClearDanmakusOnScreen: boolean): void {
    if (this.danmakuList === null || this.danmakuList.isEmpty()) {
      return;
    }
    // Release PixelMap native resources for all danmakus before clearing,
    // to prevent memory leaks from image/animation danmakus.
    let allDanmakus: BaseDanmaku[] = this.danmakuList.getCollection();
    for (let i = 0; i < allDanmakus.length; i++) {
      allDanmakus[i].releasePixelMaps();
    }
    if (!isClearDanmakusOnScreen) {
      if (this.mTimer == null || this.mContext == null) return;
      let beginMils: number = this.mTimer.currMillisecond - this.mContext.mDanmakuFactory.MAX_DANMAKU_DURATION - 100;
      let endMills: number = this.mTimer.currMillisecond + this.mContext.mDanmakuFactory.MAX_DANMAKU_DURATION;
      let tempDanmakus: IDanmakus | null = this.danmakuList.subnew(beginMils, endMills);
      if (tempDanmakus !== null)
        this.danmakus = tempDanmakus;
    }
    this.danmakuList.clear();
  }

  public onDanmakuRemoved(danmaku: BaseDanmaku): void {
    // override by CacheManagingDrawTask
  }

  public removeAllLiveDanmakus(): void {
    if (this.danmakus === null || this.danmakus.isEmpty()) {
      return;
    }
    this.danmakus.forEachSync(new Remove(this));

  }

  protected removeUnusedLiveDanmakusIn(msec: number): void {
    if (this.danmakuList == null || this.danmakuList.isEmpty() || this.mLiveDanmakus.isEmpty()) {
      return;
    }
    this.mLiveDanmakus.forEachSync(new RemoveUnused(this, msec));
  }

  public getVisibleDanmakusOnTime(time: number): IDanmakus {
    if (this.mContext == null || this.danmakuList == null) {
      return new Danmakus({ sortType: ST_BY_LIST });
    }
    let beginMills: number = time - this.mContext.mDanmakuFactory.MAX_DANMAKU_DURATION - 100;
    let endMills: number = time + this.mContext.mDanmakuFactory.MAX_DANMAKU_DURATION;
    let subDanmakus: IDanmakus | null = null;
    let i: number = 0;
    while (i++ < 3) { //avoid ConcurrentModificationException
      try {
        subDanmakus = this.danmakuList.subnew(beginMills, endMills);
        break;
      } catch (e) {
        // ignore
      }
    }
    let visibleDanmakus: IDanmakus = new Danmakus({});
    if (null != subDanmakus && !subDanmakus.isEmpty()) {
      subDanmakus.forEachSync(new SubDanMu(visibleDanmakus));
    }
    return visibleDanmakus;
  }

  // 修复：onFrame 渲染门控使用"时间窗内是否存在候选弹幕"判定，
  // 而非 isShown() 过滤结果。原门控存在自指死锁：
  // seek()/prepare 会 bump VISIBLE_RESET_FLAG 使所有弹幕 isShown()=false，
  // 而唯一能恢复 isShown 的 drawDanmakus 渲染又被门控跳过，导致弹幕永久消失。
  public hasDanmakusNear(time: number): boolean {
    if (this.mContext == null || this.danmakuList == null) {
      return false;
    }
    let beginMills: number = time - this.mContext.mDanmakuFactory.MAX_DANMAKU_DURATION - 100;
    let endMills: number = time + this.mContext.mDanmakuFactory.MAX_DANMAKU_DURATION;
    let i: number = 0;
    while (i++ < 3) {
      try {
        let subDanmakus: IDanmakus = this.danmakuList.subnew(beginMills, endMills);
        return subDanmakus != null && !subDanmakus.isEmpty();
      } catch (e) {
        // ignore and retry
      }
    }
    return false;
  }

  public draw(displayer: AbsDisplayer<IRenderBackend, string>): RenderingState {
    const result = this.drawDanmakus(displayer, this.mTimer);
    if (result == null) {
      let defaultState = new RenderingState();
      defaultState.nothingRendered = true;
      return defaultState;
    }
    return result;
  }

  public reset(): void {
    if (this.danmakus !== null)
      this.danmakus = new Danmakus({});
    if (this.mRenderer !== null)
      this.mRenderer.clear();
  }

  public seek(mills: number): void {
    this.reset();
    this.mContext?.mGlobalFlagValues.updateVisibleFlag();
    this.mContext?.mGlobalFlagValues.updateFirstShownFlag();
    this.mContext?.mGlobalFlagValues.updateSyncOffsetTimeFlag();
    this.mContext?.mGlobalFlagValues.updatePrepareFlag();
    this.mRunningDanmakus = new Danmakus({ sortType: ST_BY_LIST });
    this.mStartRenderTime = mills < 1000 ? 0 : mills;
    this.mRenderingState.reset();
    this.mRenderingState.endTime = this.mStartRenderTime;
    this.mLastBeginMills = this.mLastEndMills = 0;

    if (this.danmakuList !== null) {
      let last: BaseDanmaku | null = this.danmakuList.last();
      if (last != null && !last.isTimeOut()) {
        this.mLastDanmaku = last;
      }
    }
  }

  public clearDanmakusOnScreen(currMillis: number): void {
    this.reset();
    this.mContext?.mGlobalFlagValues.updateVisibleFlag();
    this.mContext?.mGlobalFlagValues.updateFirstShownFlag();
    this.mStartRenderTime = currMillis;
  }

  public start(): void {
    this.mContext?.registerConfigChangedCallback(this.mConfigChangedCallback);
  }

  public quit(): void {
    this.mContext?.unregisterAllConfigChangedCallbacks();
    if (this.mRenderer != null) {
      this.mRenderer.release();
    }
    this.releaseAllDanmakuResources();
  }

  private releaseAllDanmakuResources(): void {
    if (this.danmakuList != null && !this.danmakuList.isEmpty()) {
      let allDanmakus: BaseDanmaku[] = this.danmakuList.getCollection();
      for (let i = 0; i < allDanmakus.length; i++) {
        allDanmakus[i].releasePixelMaps();
      }
      this.danmakuList.clear();
    }
    if (this.danmakus != null && !this.danmakus.isEmpty()) {
      let screenDanmakus: BaseDanmaku[] = this.danmakus.getCollection();
      for (let i = 0; i < screenDanmakus.length; i++) {
        screenDanmakus[i].releasePixelMaps();
      }
      this.danmakus.clear();
    }
    if (this.mLiveDanmakus != null && !this.mLiveDanmakus.isEmpty()) {
      let liveDanmakus: BaseDanmaku[] = this.mLiveDanmakus.getCollection();
      for (let i = 0; i < liveDanmakus.length; i++) {
        liveDanmakus[i].releasePixelMaps();
      }
      this.mLiveDanmakus.clear();
    }
    if (this.mRunningDanmakus != null) {
      if (!this.mRunningDanmakus.isEmpty()) {
        let runningDanmakus: BaseDanmaku[] = this.mRunningDanmakus.getCollection();
        for (let i = 0; i < runningDanmakus.length; i++) {
          runningDanmakus[i].releasePixelMaps();
        }
      }
      this.mRunningDanmakus.clear();
      this.mRunningDanmakus = null;
    }
  }

  public prepare(): void {
    if (this.mParser == null) {
      return;
    }
    this.loadDanmakus(this.mParser);
    this.mLastBeginMills = this.mLastEndMills = 0;
    if (this.mTaskListener != null) {
      this.mTaskListener.ready();
      this.mReadyState = true;
    }
  }

  public onPlayStateChanged(state: number): void {
    this.mPlayState = state;
  }

  protected loadDanmakus(parser: BaseDanmakuParser): void {
    if(this.mContext && this.mDisp && this.mTimer) {
      this.danmakuList = parser.setConfig(this.mContext)
        .setDisplayer(this.mDisp)
        .setTimer(this.mTimer)
        .setListener(new LoadDanMu(this))
        .getDanmakus();
      this.mContext.mGlobalFlagValues.resetAll();
      if (this.danmakuList != null) {
        this.mLastDanmaku = this.danmakuList.last();
      }
    }
  }

  public setParser(parser: BaseDanmakuParser): void {
    this.mParser = parser;
    this.mReadyState = false;
  }

  protected drawDanmakus(disp: AbsDisplayer<IRenderBackend, string>, timer: DanmakuTimer | null): RenderingState | null {
    if (this.clearRetainerFlag && this.mRenderer != null) {
      this.mRenderer.clearRetainer();
      this.clearRetainerFlag = false;
    }
    if (this.danmakuList != null && timer != null && this.mContext != null && this.mRenderer != null && this.mDisp != null) {
      let backend: IRenderBackend = disp.getExtraData() as IRenderBackend;
      //DrawHelper.clearCanvas(canvas);
      if (this.mIsHidden && !this.mRequestRender) {
        return this.mRenderingState;
      }

      this.mRequestRender = false;
      let renderingState: RenderingState = this.mRenderingState;
      renderingState.timer = timer;
      // prepare screenDanmakus
      let beginMills: number = timer.currMillisecond - this.mContext.mDanmakuFactory.MAX_DANMAKU_DURATION - 100;
      let endMills: number = timer.currMillisecond + this.mContext.mDanmakuFactory.MAX_DANMAKU_DURATION;
      let screenDanmakus: IDanmakus | null = this.danmakus;
      if (this.mLastBeginMills > beginMills || timer.currMillisecond > this.mLastEndMills) {
        screenDanmakus = this.danmakuList.sub(beginMills, endMills);
        if (screenDanmakus != null) {
          this.danmakus = screenDanmakus;
        }
        this.mLastBeginMills = beginMills;
        this.mLastEndMills = endMills;
      } else {
        beginMills = this.mLastBeginMills;
        endMills = this.mLastEndMills;
      }

      // prepare runningDanmakus to draw (in sync-mode)
      let runningDanmakus: IDanmakus | null = this.mRunningDanmakus;
      this.beginTracing(renderingState, runningDanmakus, screenDanmakus);
      if (runningDanmakus != null && !runningDanmakus.isEmpty()) {
        this.mRenderingState.isRunningDanmakus = true;
        this.mRenderer.draw(disp, runningDanmakus, 0, this.mRenderingState);
      }

      // draw screenDanmakus
      this.mRenderingState.isRunningDanmakus = false;
      if (screenDanmakus != null && !screenDanmakus.isEmpty()) {
        this.mRenderer.draw(this.mDisp, screenDanmakus, this.mStartRenderTime, renderingState);
        this.endTracing(renderingState);
        if (renderingState.nothingRendered) {
          if (this.mLastDanmaku != null && this.mLastDanmaku.isTimeOut()) {
            this.mLastDanmaku = null;
            if (this.mTaskListener != null) {
              this.mTaskListener.onDanmakusDrawingFinished();
            }
          }
          if (renderingState.beginTime == RenderingState.UNKNOWN_TIME) {
            renderingState.beginTime = beginMills;
          }
          if (renderingState.endTime == RenderingState.UNKNOWN_TIME) {
            renderingState.endTime = endMills;
          }
        }
        return renderingState;
      } else {
        renderingState.nothingRendered = true;
        renderingState.beginTime = beginMills;
        renderingState.endTime = endMills;
        return renderingState;
      }
    }
    return null;
  }

  public requestClear(): void {
    this.mLastBeginMills = this.mLastEndMills = 0;
    this.mIsHidden = false;
  }

  public requestClearRetainer(): void {
    this.clearRetainerFlag = true;
  }

  public requestSync(fromTimeMills: number, toTimeMills: number, offsetMills: number): void {
    // obtain the running-danmakus which was drawn on screen
    let runningDanmakus: IDanmakus = this.mRenderingState.obtainRunningDanmakus();
    this.mRunningDanmakus = runningDanmakus;
    // set offset time for each running-danmakus

    runningDanmakus.forEachSync(new Running(offsetMills));
    this.mStartRenderTime = toTimeMills;
  }

  public onDanmakuConfigChanged(config: DanmakuContext, tag: DanmakuConfigTag,
    values: Object[]): boolean {
    let handled: boolean = this.handleOnDanmakuConfigChanged(config, tag, values);
    if (this.mTaskListener != null) {
      this.mTaskListener.onDanmakuConfigChanged();
    }
    return handled;
  }

  protected handleOnDanmakuConfigChanged(config: DanmakuContext, tag: DanmakuConfigTag, values: Object[]): boolean{
    let handled: boolean = false;
    if (tag === null || DanmakuConfigTag.MAXIMUM_NUMS_IN_SCREEN === tag) {
      handled = true;
    } else if (DanmakuConfigTag.DUPLICATE_MERGING_ENABLED === tag) {
      let enable: boolean = values[0] as boolean;
      if (enable) {
        this.mContext?.mDanmakuFilters.registerFilter({ tag: DanmakuFilters.TAG_DUPLICATE_FILTER });
      } else {
        this.mContext?.mDanmakuFilters.unregisterFilter({ tag: DanmakuFilters.TAG_DUPLICATE_FILTER });
      }
      handled = true;
    } else if (DanmakuConfigTag.SCALE_TEXTSIZE === tag || DanmakuConfigTag.SCROLL_SPEED_FACTOR === tag || DanmakuConfigTag.DANMAKU_MARGIN === tag) {
      this.requestClearRetainer();
      handled = false;
    } else if ((DanmakuConfigTag.MAXIMUN_LINES === tag || DanmakuConfigTag.OVERLAPPING_ENABLE === tag) && this.mContext) {
      if (this.mRenderer != null) {
        this.mRenderer.setVerifierEnabled(this.mContext.isPreventOverlappingEnabled() || this.mContext.isMaxLinesLimited());
      }
      handled = true;
    } else if (DanmakuConfigTag.ALIGN_BOTTOM === tag) {
      let enable: boolean = values[0] as boolean;
      if (this.mRenderer != null) {
        this.mRenderer.alignBottom(enable);
      }
      handled = true;
    }
    return handled;
  }

  public requestHide(): void {
    this.mIsHidden = true;
  }

  public requestRender(): void {
    this.mRequestRender = true;
  }

  private beginTracing(renderingState: RenderingState, runningDanmakus: IDanmakus | null, screenDanmakus: IDanmakus | null): void {
    renderingState.reset();
    renderingState.sysTime = SystemClock.uptimeMillis();
    renderingState.indexInScreen = 0;
    renderingState.totalSizeInScreen = (runningDanmakus != null ? runningDanmakus.size() : 0) + (screenDanmakus != null ? screenDanmakus.size() : 0);
  }

  private endTracing(renderingState: RenderingState): void {
    renderingState.nothingRendered = (renderingState.totalDanmakuCount == 0);
    if (renderingState.nothingRendered) {
      renderingState.beginTime = RenderingState.UNKNOWN_TIME;
    }
    let lastDanmaku: BaseDanmaku | null= renderingState.lastDanmaku;
    renderingState.lastDanmaku = null;
    renderingState.endTime = lastDanmaku != null ? lastDanmaku.getActualTime() : RenderingState.UNKNOWN_TIME;
    if(renderingState.timer) {
      renderingState.consumingTime = SystemClock.uptimeMillis() - renderingState.sysTime;
    }
  }
}
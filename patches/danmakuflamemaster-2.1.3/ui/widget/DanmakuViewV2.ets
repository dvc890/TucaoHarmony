/*
 * Copyright (C) 2022 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the 'License');
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an 'AS IS' BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { RenderingState } from '../../danmaku/renderer/IRenderer';
import { IDanmakuView, OnDanmakuClickListener, THREAD_TYPE_NORMAL_PRIORITY }from '../../controller/IDanmakuView'
import { IDanmakuViewController } from '../../controller/IDanmakuViewController'
import { DrawHandler, Callback, START } from '../../controller/DrawHandler'
import { Message } from '../../../../../compat/Handler'
import { IDanmakus, ST_BY_LIST } from '../../danmaku/model/IDanmakus'
import { BaseDanmaku } from '../../danmaku/model/BaseDanmaku'
import { BaseDanmakuParser } from '../../danmaku/parser/BaseDanmakuParser'
import { DanmakuContext } from '../../danmaku/model/ohos/DanmakuContext'
import SystemClock from '../../danmaku/util/SystemClock'
import { DrawHelper } from '../../controller/DrawHelper'
import { DanmakuTouchHelper } from './DanmakuTouchHelper'
import { LogUtil } from '../../../../../LogUtil'
import { Danmakus } from '../../danmaku/model/ohos/Danmakus'
import { GlobalContext } from '../../../../../../GlobalContext';
import { AnimatorResult } from '@kit.ArkUI';
import { RenderMode, IRenderBackend } from '../../danmaku/model/render/RenderMode';
import { Canvas2DBackend } from '../../danmaku/model/render/Canvas2DBackend';
import { XComponentSurfaceBackend } from '../../danmaku/model/render/XComponentSurfaceBackend';
import { XComponentTextureBackend } from '../../danmaku/model/render/XComponentTextureBackend';

const MAX_RECORD_SIZE: number = 50;
const ONE_SECOND: number = 1000;

class DefaultOnDanmakuClickListener implements OnDanmakuClickListener {
  onDanmakuClick(danmakus: IDanmakus): boolean {
    return false;
  }

  onDanmakuLongClick(danmakus: IDanmakus): boolean {
    return false;
  }

  onViewClick(view: IDanmakuView): boolean {
    return false;
  }
}

@ComponentV2
struct DanmakuViewV2 {
  @Param model: DanmakuViewV2.Model = new DanmakuViewV2.Model()
  @Event $model: (val: DanmakuViewV2.Model) => void = (val: DanmakuViewV2.Model) => {};
  @Local refreshGeneration: number = 0
  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  ready: boolean = false
  @Local viewWidth: number= 1920
  @Local viewHeight: number= 1080
  @Local renderMode: RenderMode = RenderMode.CANVAS_2D;
  private renderBackend: IRenderBackend | null = null;
  private canvasBackend: Canvas2DBackend | null = null;
  private surfaceBackend: XComponentSurfaceBackend | null = null;
  private textureBackend: XComponentTextureBackend | null = null;
  private xComponentController: XComponentController = new XComponentController();

  private mCallback: Callback | null = null;
  private handler: DrawHandler | null = null;
  private mOnDanmakuClickListener: OnDanmakuClickListener | null = null;
  private mXOff: number = 0;
  private mYOff: number = 0;
  private mTouchHelper: DanmakuTouchHelper | null = null;
  private mShowFps: boolean = false;
  @Local public mDanmakuVisible: boolean = true;
  protected mDrawingThreadType: number = THREAD_TYPE_NORMAL_PRIORITY;
  protected mRequestRender: boolean = false;
  private mDrawTimes: number[] | null = null;
  protected mClearFlag: boolean = false;
  private mAnimator: AnimatorResult | null = null;
  private mIsAnimating: boolean = false;
  private quitFlag: boolean = false;

  build() {
    Stack() {
      if (this.renderMode === RenderMode.CANVAS_2D) {
        Canvas(this.context)
          .onReady(() => {
            this.ready = true
            this.initCanvasBackend()
          }).width('100%').height('100%').backgroundColor(Color.Transparent)
      } else if (this.renderMode === RenderMode.XCOMPONENT_SURFACE) {
        XComponent({
          id: 'danmakuXComponentV2',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .onLoad(() => {
            this.ready = true
            this.initSurfaceBackend()
          })
          .width('100%').height('100%').backgroundColor(Color.Transparent)
      } else if (this.renderMode === RenderMode.XCOMPONENT_TEXTURE) {
        XComponent({
          id: 'danmakuXComponentV2',
          type: XComponentType.TEXTURE,
          controller: this.xComponentController
        })
          .onLoad(() => {
            this.ready = true
            this.initTextureBackend()
          })
          .width('100%').height('100%').backgroundColor(Color.Transparent)
      }
    }.width(this.model.getViewWidth() + 'px')
    .height(this.model.getViewHeight() + 'px')
    .visibility(this.mDanmakuVisible ? Visibility.Visible : Visibility.Hidden)
    .onTouch((event: TouchEvent): void => this.onTouchEvent(event))
  }

  invalidate() {
    this.refreshGeneration = (this.refreshGeneration + 1) % 65536;
    this.onDraw(this.context)
  }

  postInvalidate() {
    this.startAnimationIfNeeded();
  }

  aboutToAppear() {
    let uiContext = this.getUIContext();
    GlobalContext.getContext().setValue('uiContext', uiContext);
    LogUtil.log('aboutToAppear');
    // 重置 aboutToDisappear 中清理的状态，确保重新进入页面时能正常工作
    this.quitFlag = false;
    this.mIsAnimating = false;
    this.mAnimator = null;
    this.ready = false;
    this.mRequestRender = false;
    this.mClearFlag = false;
    this.mDrawTimes = null;
    this.handler = null;
    this.mTouchHelper = null;
    this.renderBackend = null;
    this.canvasBackend = null;
    this.surfaceBackend = null;
    this.textureBackend = null;
    this.model.delegate = this;
    this.init()
  }

  aboutToDisappear() {
    this.quitFlag = true;
    this.stopAnimation();
    if (this.handler != null) {
      this.handler.removeAllDanmakus(true);
    }
    this.stopDraw();
    if (this.canvasBackend) {
      this.canvasBackend.destroy();
      this.canvasBackend = null;
    }
    if (this.surfaceBackend) {
      this.surfaceBackend.destroy();
      this.surfaceBackend = null;
    }
    if (this.textureBackend) {
      this.textureBackend.destroy();
      this.textureBackend = null;
    }
    this.renderBackend = null;
    if (this.mDrawTimes != null) {
      this.mDrawTimes.length = 0;
      this.mDrawTimes = null;
    }
    this.handler = null;
    this.mTouchHelper = null;
    this.ready = false;
    this.model.delegate = null;
  }

  private init(): void {
    LogUtil.log('init');
    DrawHelper.useDrawColorToClearCanvas(true, false);
    this.mTouchHelper = DanmakuTouchHelper.instance(this.model);
    this.renderMode = this.model.getMode();
  }

  private initCanvasBackend(): void {
    if (this.surfaceBackend) {
      this.surfaceBackend.destroy();
    }
    if (this.textureBackend) {
      this.textureBackend.destroy();
    }
    if (this.canvasBackend == null) {
      this.canvasBackend = new Canvas2DBackend(this.context);
    }
    this.canvasBackend.setSize(this.viewWidth, this.viewHeight);
    this.renderBackend = this.canvasBackend;
    this.surfaceBackend = null;
    this.textureBackend = null;
    this.mRequestRender = true;
    this.startAnimationIfNeeded();
  }

  private initSurfaceBackend(): void {
    if (this.canvasBackend) {
      this.canvasBackend.destroy();
    }
    if (this.textureBackend) {
      this.textureBackend.destroy();
    }
    if (this.surfaceBackend == null) {
      this.surfaceBackend = new XComponentSurfaceBackend();
      this.surfaceBackend.init();
    }
    const surfaceIdStr = this.xComponentController.getXComponentSurfaceId();
    if (surfaceIdStr.length > 0) {
      this.surfaceBackend.setSurfaceId(surfaceIdStr);
    }
    this.surfaceBackend.setSize(this.viewWidth, this.viewHeight);
    this.renderBackend = this.surfaceBackend;
    this.canvasBackend = null;
    this.textureBackend = null;
    this.mRequestRender = true;
    this.startAnimationIfNeeded();
  }

  private initTextureBackend(): void {
    if (this.canvasBackend) {
      this.canvasBackend.destroy();
    }
    if (this.surfaceBackend) {
      this.surfaceBackend.destroy();
    }
    if (this.textureBackend == null) {
      this.textureBackend = new XComponentTextureBackend();
      this.textureBackend.init();
    }
    const surfaceIdStr = this.xComponentController.getXComponentSurfaceId();
    if (surfaceIdStr.length > 0) {
      this.textureBackend.setSurfaceId(surfaceIdStr);
    }
    this.textureBackend.setSize(this.viewWidth, this.viewHeight);
    this.renderBackend = this.textureBackend;
    this.canvasBackend = null;
    this.surfaceBackend = null;
    this.mRequestRender = true;
    this.startAnimationIfNeeded();
  }

  /**
   * 启动动画循环（如果尚未启动）
   */
  private startAnimationIfNeeded() {
    if (this.mIsAnimating || !this.mDanmakuVisible || this.quitFlag) {
      return;
    }
    this.mIsAnimating = true;

    // 确保之前的动画已经完全停止
    if (this.mAnimator) {
      this.mAnimator.finish();
      this.mAnimator = null;
    }

    this.mAnimator = this.getUIContext().createAnimator({
      duration: 16,
      easing: 'linear',
      begin: 0,
      end: 1,
      iterations: -1,
      fill: 'none',
      direction: 'normal',
      delay: 0
    })

    this.mAnimator.setExpectedFrameRateRange({
      min: 30,
      max: 120,
      expected: 60
    });

    this.mAnimator.onFrame= (value: number) => {
      if (!this.mDanmakuVisible || this.quitFlag) {
        this.mIsAnimating = false;
        return;
      }
      if (this.handler != null) {
        // 修复：改用候选弹幂判定替代 isShown 过滤集判定。
        // 原逻辑 hasVisibleDanmakus=getCurrentVisibleDanmakus().size()>0 存在死锁：
        // seek/prepare 后所有弹幕 isShown=false → 门控跳过渲染 →
        // drawDanmakus 永不执行 → 无弹幕能被重新标记 shown → 弹幕永久消失。
        const hasVisibleDanmakus = this.handler.hasCurrentDanmakusNear();

        if (!hasVisibleDanmakus && !this.mRequestRender && !this.mClearFlag) {
          return;
        }
        // Update the danmaku timer to the current wall-clock time before
        // rendering. Without this, the timer is only updated by the
        // DrawHandler's UPDATE message loop (~16ms), which is slightly out
        // of phase with the display refresh (~16.67ms). The phase drift causes
        // some frames to render with a stale timer → position freeze → stutter.
        this.handler.syncTimerForFrame();
      }

      this.refreshGeneration = (this.refreshGeneration + 1) % 65536;
      this.onDraw(this.context);
    };

    this.mAnimator.onFinish = () => {
      this.mIsAnimating = false;
    };

    this.mAnimator.play();
  }

  /**
   * 停止动画循环
   */
  private stopAnimation() {
    if (this.mAnimator) {
      this.mAnimator.finish();
      this.mAnimator = null;
    }
    this.mIsAnimating = false;
  }

  /**
   * danmaku.isLive == true的情况下,请在非UI线程中使用此方法,避免可能卡住主线程
   *
   * @param item
   */

  public addDanmaku(item: BaseDanmaku): void { // from IDanmakuView
    LogUtil.log('addDanmaku');
    if (!item) {
      LogUtil.log('addDanmaku: item is null');
      return;
    }
    if (this.handler != null) {
      try {
        this.handler.addDanmaku(item);
      } catch (error) {
        LogUtil.log('addDanmaku failed: ' + JSON.stringify(error));
      }
    }
  }

  public invalidateDanmaku(item: BaseDanmaku, remeasure: boolean): void { // from IDanmakuView
    LogUtil.log('invalidateDanmaku');
    if (this.handler != null) {
      this.handler.invalidateDanmaku(item, remeasure);
    }
  }

  public removeAllDanmakus(isClearDanmakusOnScreen: boolean): void { // from IDanmakuView
    LogUtil.log('removeAllDanmakus');
    if (this.handler != null) {
      this.handler.removeAllDanmakus(isClearDanmakusOnScreen);
    }
  }

  public removeAllLiveDanmakus(): void { // from IDanmakuView
    LogUtil.log('removeAllLiveDanmakus');
    if (this.handler != null) {
      this.handler.removeAllLiveDanmakus();
    }
  }

  public getCurrentVisibleDanmakus(): IDanmakus|null { // from IDanmakuView
    if (this.handler != null) {
      return this.handler.getCurrentVisibleDanmakus();
    }
    return null;
  }

  public setCallback(callback: Callback | null): void { // from IDanmakuView
    this.mCallback = callback;
    if (this.handler != null && callback != null) {
      this.handler.setCallback(callback);
    }
  }

  public release(): void {
    LogUtil.log('release');
    try {
      this.quitFlag = true;
      this.stopAnimation();
      this.stop();
      if (this.mDrawTimes != null) {
        this.mDrawTimes.length = 0;
      }
      this.mCallback = null;
      this.mOnDanmakuClickListener = null;
      this.mTouchHelper = null;
    } catch (error) {
      LogUtil.log('release failed: ' + JSON.stringify(error));
    }
  }

  public stop(): void { // from IDanmakuView 播放控制
    try {
      this.quitFlag = true;
      this.stopAnimation();
      this.stopDraw();
    } catch (error) {
      LogUtil.log('stop failed: ' + JSON.stringify(error));
    }
  }

  private stopDraw(): void {
    if (this.handler == null) {
      return;
    }
    this.handler.quit();
    this.handler = null;
  }

  private prepareInner(): void {
    if (this.handler == null) {
      this.handler = new DrawHandler(this.model, this.mDanmakuVisible);
    }
  }

  public prepare(parser: BaseDanmakuParser, config: DanmakuContext): void {
    LogUtil.log('prepare');
    if (!parser) {
      LogUtil.log('prepare: parser is null');
      return;
    }
    if (!config) {
      LogUtil.log('prepare: config is null');
      return;
    }
    try {
      this.prepareInner();
      if (this.handler) {
        this.handler.setConfig(config);
        this.handler.setParser(parser);
        if (this.mCallback) {
          this.handler.setCallback(this.mCallback);
        }
        this.handler.prepare();
      }
    } catch (error) {
      LogUtil.log('prepare failed: ' + JSON.stringify(error));
    }
  }

  public isPrepared(): boolean { // from IDanmakuView
    return this.handler != null && this.handler.isPrepared();
  }

  public getConfig(): DanmakuContext|null { // from IDanmakuView
    if (this.handler == null) {
      return null;
    }
    return this.handler.getConfig();
  }

  public showFPS(show: boolean): void { // from IDanmakuView
    this.mShowFps = show;
  }

  private fps(): number {
    if (this.mDrawTimes == null) return 0.0;
    let lastTime: number = SystemClock.uptimeMillis();
    this.mDrawTimes.push(lastTime);
    let first: number = this.mDrawTimes[0];
    if (first === undefined) {
      return 0.0;
    }
    let dtime: number = lastTime - first;
    let frames: number = this.mDrawTimes.length;
    if (frames > MAX_RECORD_SIZE) {
      this.mDrawTimes.shift();
    }
    return dtime > 0 ? this.mDrawTimes.length * ONE_SECOND / dtime : 0.0;
  }

  public drawDanmakus(): number { // from IDanmakuViewController
    if (!this.isShown())
      return -1;
    let stime: number = SystemClock.uptimeMillis();
    this.lockCanvas();
    return SystemClock.uptimeMillis() - stime;
  }

  private postInvalidateCompat(): void {
    this.mRequestRender = true;
    this.postInvalidate();
  }

  protected lockCanvas(): void {
    if (this.mDanmakuVisible == false) {
      return;
    }
    this.postInvalidateCompat();
  }

  protected onDraw(canvas: CanvasRenderingContext2D): number {
    if (!this.ready) {
      return 0
    }
    if ((!this.mDanmakuVisible) && (!this.mRequestRender)) {
      return 0;
    }

    let backend = this.renderBackend;
    if (backend == null) {
      backend = this.canvasBackend;
    }

    if (backend) {
      if (this.mClearFlag) {
        backend.clear();
        this.mClearFlag = false;
      }

      if (this.handler != null) {
        DrawHelper.clearBackend(backend);
        let rs: RenderingState = this.handler.draw(backend);
        if (this.mShowFps) {
          if (this.mDrawTimes == null)
            this.mDrawTimes = new Array<number>();
          let fps: string =
            'fps ' + this.fps().toFixed(2) + ',time:' + Math.floor(this.getCurrentTime() / 1000)
          DrawHelper.drawFPSBackend(backend, fps);
        }
      }

      if (this.surfaceBackend) {
        this.surfaceBackend.swapBuffers();
      } else if (this.textureBackend) {
        this.textureBackend.updateTexture();
      }
    }

    this.mRequestRender = false;
    return 0
  }

  @Monitor('viewWidth','viewHeight')
  protected onRelayout(): void {
    if (this.handler != null) {
      this.handler.notifyDispSizeChanged(this.viewWidth, this.viewHeight);
    }
  }

  public toggle(): void { // from IDanmakuView 播放控制
    if (this.handler == null) {
      this.start();
    } else if (this.handler.isStop()) {
      this.resume();
    } else {
      this.pause();
    }
  }


  public pause(): void { // from IDanmakuView 播放控制
    try {
      this.quitFlag = true;
      this.stopAnimation();
      if (this.handler != null) {
        this.handler.removeCallbacks(this.mResumeRunnable);
        this.handler.pause();
      }
    } catch (error) {
      LogUtil.log('pause failed: ' + JSON.stringify(error));
    }
  }

  private mResumeTryCount: number = 0;
  private mResumeRunnable = () => {
    let drawHandler: DrawHandler | null = this.handler;
    if (drawHandler == null) {
      return;
    }
    this.mResumeTryCount++;
    if (this.mResumeTryCount > 4) {
      drawHandler.resume();
    } else {
      drawHandler.postDelayed(this.mResumeRunnable, 100 * this.mResumeTryCount);
    }
  };

  public resume(): void { // from IDanmakuView 播放控制
    try {
      this.quitFlag = false;
      if (this.handler != null && this.handler.isPrepared()) {
        this.mResumeTryCount = 0;
        this.handler.post(this.mResumeRunnable);
        this.startAnimationIfNeeded();
      } else if (this.handler == null) {
        this.restart();
      }
    } catch (error) {
      LogUtil.log('resume failed: ' + JSON.stringify(error));
    }
  }

  public isPaused(): boolean { // from IDanmakuView
    if (this.handler != null) {
      return this.handler.isStop();
    }
    return false;
  }

  public restart(): void {
    this.stop();
    this.start();
  }

  public start(position: number = 0): void { // from IDanmakuView 播放控制
    try {
      this.quitFlag = false;
      let handlerLocal: DrawHandler | null = this.handler;
      if (handlerLocal == null) {
        this.prepareInner();
        handlerLocal = this.handler;
      } else {
        handlerLocal.removeCallbacksAndMessages();
      }
      if (handlerLocal != null) {
        handlerLocal.sendMessage(new Message({ what: START, obj: position }))
      }
      this.startAnimationIfNeeded();
    } catch (error) {
      LogUtil.log('start failed: ' + JSON.stringify(error));
    }
  }

  public onTouchEvent(event: TouchEvent): void {
    if (this.mTouchHelper) {
      this.mTouchHelper.onTouchEvent(event);
    }
  }

  public seekTo(ms: number): void { // from IDanmakuView 播放控制
    if (this.handler != null) {
      this.handler.seekTo(ms);
    }
  }

  public isViewReady(): boolean { // from IDanmakuViewController
    return this.ready;
  }

  public show(): void{ // from IDanmakuView 播放控制
    this.quitFlag = false;
    this.showAndResumeDrawTask(null);
    this.startAnimationIfNeeded();
  }

  /**
   * show the danmakuview again if you called hideAndPauseDrawTask()
   *
   * @param position The position you want to resume
   * @see #hideAndPauseDrawTask
   */

  public showAndResumeDrawTask(position: number | null): void {
    this.mDanmakuVisible = true;
    this.mClearFlag = false;
    if (this.handler == null) {
      return;
    }
    this.handler.showDanmakus(position ?? undefined);
    this.startAnimationIfNeeded();
  }

  public hide(): void { // from IDanmakuView 播放控制
    this.mDanmakuVisible = false;
    if (this.handler == null) {
      return;
    }
    this.handler.hideDanmakus(false);
    this.stopAnimation();
  }

  /**
   * hide the danmakuview and pause the drawtask
   *
   * @return the paused position
   * @see #showAndResumeDrawTask
   */

  public hideAndPauseDrawTask(): number { // from IDanmakuView 播放控制
    this.mDanmakuVisible = false;
    this.stopAnimation();
    if (this.handler == null) {
      return 0;
    }
    return this.handler.hideDanmakus(true);
  }

  public clear(): void { // from IDanmakuViewController
    if (!this.isViewReady()) {
      return;
    }
    this.mClearFlag = true;
    this.postInvalidateCompat();
  }

  public isShown(): boolean { // from IDanmakuView View方法
    return this.mDanmakuVisible
  }

  /**
   * @param type One of THREAD_TYPE_MAIN_THREAD, THREAD_TYPE_HIGH_PRIORITY, THREAD_TYPE_NORMAL_PRIORITY, or THREAD_TYPE_LOW_PRIORITY.
   */

  public setDrawingThreadType(threadType: number): void { // from IDanmakuView
    this.mDrawingThreadType = threadType;
  }

  /**
   * for getting the accurate play-time. use this method instead of parser.getTimer().currMillisecond
   *
   * @return
   */

  public getCurrentTime(): number { // from IDanmakuView
    if (this.handler != null) {
      return this.handler.getCurrentTime();
    }
    return 0;
  }

  public clearDanmakusOnScreen(): void {
    if (this.handler != null) {
      this.handler.clearDanmakusOnScreen();
    }
  }

  public setOnDanmakuClickListener(listener: OnDanmakuClickListener | null, xOff?: number, yOff?: number): void { // from IDanmakuView Click Listener
    this.mOnDanmakuClickListener = listener;
    if (xOff !== undefined) {
      this.mXOff = xOff;
    }
    if (yOff !== undefined) {
      this.mYOff = yOff;
    }
  }

  public getOnDanmakuClickListener(): OnDanmakuClickListener { // from IDanmakuView Click Listener
    return this.mOnDanmakuClickListener ?? new DefaultOnDanmakuClickListener();
  }

  public getXOff(): number { // from IDanmakuView Click Listener
    return this.mXOff;
  }

  public getYOff(): number { // from IDanmakuView Click Listener
    return this.mYOff;
  }

  public forceRender(): void { // from IDanmakuView Click Listener
    this.mRequestRender = true;
    if(this.handler) {
      this.handler.forceRender();
    }
    this.startAnimationIfNeeded();
  }
}

namespace DanmakuViewV2 {
  export class Model implements IDanmakuView, IDanmakuViewController {
    delegate: DanmakuViewV2 | null = null
    public renderMode: RenderMode = RenderMode.CANVAS_2D;

    setMode(mode: RenderMode): void {
      this.renderMode = mode;
      if (this.delegate) {
        this.delegate.renderMode = mode;
      }
    }

    getMode(): RenderMode {
      return this.renderMode;
    }

    isPrepared(): boolean{
      return this.delegate?.isPrepared() ?? false;
    }

    isPaused(): boolean{
      return this.delegate?.isPaused() ?? false;
    }
    /**
     *
     * @param type One of THREAD_TYPE_MAIN_THREAD, THREAD_TYPE_HIGH_PRIORITY, THREAD_TYPE_NORMAL_PRIORITY, or THREAD_TYPE_LOW_PRIORITY.
     */
    setDrawingThreadType(threadType: number): void{
      this.delegate?.setDrawingThreadType(threadType);
    }

    showFPS(show: boolean): void{
      this.delegate?.showFPS(show);
    }

    /**
     * danmaku.isLive == true的情况下,请在非UI线程中使用此方法,避免可能卡住主线程
     * @param item
     */
    addDanmaku(item: BaseDanmaku): void{
      this.delegate?.addDanmaku(item);
    }

    invalidateDanmaku(item: BaseDanmaku, remeasure: boolean): void{
      this.delegate?.invalidateDanmaku(item, remeasure);
    }

    removeAllDanmakus(isClearDanmakusOnScreen: boolean): void{
      this.delegate?.removeAllDanmakus(isClearDanmakusOnScreen);
    }

    removeAllLiveDanmakus(): void{
      this.delegate?.removeAllLiveDanmakus();
    }

    getCurrentVisibleDanmakus(): IDanmakus {
      const danmakus = this.delegate?.getCurrentVisibleDanmakus();
      if (danmakus == null) {
        return new Danmakus({ sortType: ST_BY_LIST });
      }
      return danmakus;
    }

    setCallback(callback: Callback | null): void{
      this.delegate?.setCallback(callback);
    }

    /**
     * for getting the accurate play-time. use this method instead of parser.getTimer().currMillisecond
     * @return
     */
    getCurrentTime(): number{
      return this.delegate?.getCurrentTime() ?? 0;
    }

    getConfig(): DanmakuContext {
      const config = this.delegate?.getConfig();
      if (config == null) {
        throw new Error('DanmakuContext not initialized');
      }
      return config;
    }

    getView(): IDanmakuView{
      return this
    }

    setWidth(width: number) {
      if (this.delegate) this.delegate.viewWidth = width
    }

    setHeight(height: number) {
      if (this.delegate) this.delegate.viewHeight = height
    }

    getWidth(): number {
      return this.delegate?.viewWidth ?? 0;
    }

    getHeight(): number {
      return this.delegate?.viewHeight ?? 0;
    }

    setVisibility(visibility: boolean): void {
      if (this.delegate) this.delegate.mDanmakuVisible = visibility
    }

    isShown(): boolean{
      return this.delegate?.isShown() ?? false;
    }

    // ------------- 播放控制 -------------------
    prepare(parser: BaseDanmakuParser, config: DanmakuContext): void{
      this.delegate?.prepare(parser, config);
    }

    seekTo(ms: number): void{
      this.delegate?.seekTo(ms);
    }

    start(position?: number): void{
      this.delegate?.start(position);
    }

    stop(): void{
      this.delegate?.stop();
    }

    pause(): void{
      this.delegate?.pause();
    }

    resume(): void{
      this.delegate?.resume();
    }

    release(): void{
      this.delegate?.release();
    }

    toggle(): void{
      this.delegate?.toggle();
    }

    show(): void{
      this.delegate?.show();
    }

    hide(): void{
      this.delegate?.hide();
    }

    /**
     * show the danmakuview again if you called hideAndPauseDrawTask()
     * @param position The position you want to resume
     * @see #hideAndPauseDrawTask
     */
    showAndResumeDrawTask(position: number | null): void{
      this.delegate?.showAndResumeDrawTask(position);
    }

    /**
     * hide the danmakuview and pause the drawtask
     * @return the paused position
     * @see #showAndResumeDrawTask
     */
    hideAndPauseDrawTask(): number{
      return this.delegate?.hideAndPauseDrawTask() ?? 0;
    }

    clearDanmakusOnScreen(): void{
      this.delegate?.clearDanmakusOnScreen();
    }

    // ------------- Click Listener -------------------

    setOnDanmakuClickListener(listener: OnDanmakuClickListener | null, xOff?: number, yOff?: number): void {
      this.delegate?.setOnDanmakuClickListener(listener, xOff, yOff);
    }

    getOnDanmakuClickListener(): OnDanmakuClickListener {
      return this.delegate?.getOnDanmakuClickListener() ?? new DefaultOnDanmakuClickListener();
    }

    getXOff(): number{
      return this.delegate?.getXOff() ?? 0;
    }

    getYOff(): number{
      return this.delegate?.getYOff() ?? 0;
    }

    forceRender(): void{
      this.delegate?.forceRender();
    }

    isViewReady(): boolean{
      return this.delegate?.isViewReady() ?? false;
    }

    getViewWidth(): number{
      return this.getWidth();
    };

    getViewHeight(): number{
      return this.getHeight();
    };

    drawDanmakus(): number{
      return this.delegate?.drawDanmakus() ?? -1;
    };

    clear(): void{
      this.delegate?.clear();
    };
  }
}

export default DanmakuViewV2
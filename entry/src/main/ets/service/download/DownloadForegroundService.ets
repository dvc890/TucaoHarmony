/**
 * 前台下载通知服务
 * - 长时任务：backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], wantAgent)
 *   （module.json5 abilities.backgroundModes 含 dataTransfer；起任务即发 0% 进度，满足首次更新 ≤10 分钟红线）
 * - 实况通知：以返回的 ContinuousTaskNotification.notificationId 为通知 id，publish
 *   SlotType.LIVE_VIEW + NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW(typeCode=8) + downloadTemplate
 *   {title, fileName, progressValue}；isSupportTemplate 预检不支持则跳过自定义发布（默认通知兜底）
 * - 动作回传：actionButtons（wantAgent SEND_COMMON_EVENT）→ commonEventManager 订阅
 *   me.sweetll.tucao.download.PAUSE_ALL / CANCEL_ACTIVE → 引擎接线的 onPauseAll/onCancelActive 钩子
 * - 点击通知：wantAgent(START_ABILITY) 回应用
 * - 进度节流：1s + 尾随定时器（taskProgress 高频调用不刷屏）
 * - 容错：startBackgroundRunning 失败 → running=false，前台下载继续不阻断；
 *   publish 失败（实况窗权限/模板受限）→ catch 静默，默认通知兜底
 * 依赖方向：DownloadEngine → 本服务（单向）；本服务不 import 引擎（钩子反转）
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { AppContextHolder } from '../../common/GlobalState';

/** 通知动作事件名（SEND_COMMON_EVENT 回传） */
export class DownloadNotifyEvents {
  static readonly PAUSE_ALL: string = 'me.sweetll.tucao.download.PAUSE_ALL';
  static readonly CANCEL_ACTIVE: string = 'me.sweetll.tucao.download.CANCEL_ACTIVE';
  /** downloadTemplate 模板名（系统当前唯一支持） */
  static readonly TEMPLATE_NAME: string = 'downloadTemplate';
}

/** 前台下载通知服务单例（哑管理器：状态由引擎驱动，动作经钩子回传） */
export class DownloadForegroundService {
  private static instance: DownloadForegroundService | undefined;

  static getInstance(): DownloadForegroundService {
    if (DownloadForegroundService.instance === undefined) {
      DownloadForegroundService.instance = new DownloadForegroundService();
    }
    return DownloadForegroundService.instance;
  }

  /** 通知「暂停」→ 引擎 pauseAll（DownloadEngine.ensureStarted 接线） */
  onPauseAll: (() => void) | null = null;
  /** 通知「取消」→ 引擎取消当前任务并继续队列（DownloadEngine.ensureStarted 接线） */
  onCancelActive: (() => void) | null = null;

  /** 长时任务运行中 */
  private running: boolean = false;
  /** 通知 id（startBackgroundRunning 返回值；-1 = 未持有） */
  private notificationId: number = -1;
  /** downloadTemplate 受支持（startTask 时预检） */
  private templateSupported: boolean = false;
  /** 动作事件已订阅 */
  private subscribed: boolean = false;
  /** 当前展示的合集标题 / 分集名 */
  private currentTitle: string = '';
  private currentFileName: string = '';
  /** 进度节流：上次发布时间戳与百分比 */
  private lastProgressAt: number = 0;
  private lastPercent: number = -1;
  /** 尾随定时器与待发百分比 */
  private progressTimer: number = -1;
  private pendingPercent: number = -1;
  /** wantAgent 缓存（Promise 接口，构建一次复用） */
  private launchAgent: WantAgent | null = null;
  private pauseAgent: WantAgent | null = null;
  private cancelAgent: WantAgent | null = null;

  private constructor() {
  }

  /** 任务开始（引擎 execute 首行调用）：订阅动作 + 起长时任务 + 发 0% */
  taskStarted(title: string, fileName: string, percent: number): void {
    this.currentTitle = title;
    this.currentFileName = fileName;
    this.lastPercent = percent;
    this.subscribeOnce();
    this.startTask();
  }

  /** 进度更新（引擎高频调用；1s 节流 + 尾随保证末值不丢） */
  taskProgress(percent: number): void {
    if (!this.running || (percent === this.pendingPercent && this.progressTimer >= 0)) {
      return;
    }
    if (percent === this.lastPercent && this.progressTimer < 0) {
      return;
    }
    this.pendingPercent = percent;
    const now: number = Date.now();
    const elapsed: number = now - this.lastProgressAt;
    if (elapsed >= 1000) {
      this.flushProgress();
      return;
    }
    if (this.progressTimer < 0) {
      this.progressTimer = setTimeout((): void => {
        this.progressTimer = -1;
        this.flushProgress();
      }, 1000 - elapsed);
    }
  }

  /** 队列空闲（引擎 pump 空队列时调用）：停长时任务 + 撤通知 */
  queueIdle(): void {
    this.clearProgressTimer();
    this.pendingPercent = -1;
    if (!this.running) {
      return;
    }
    this.running = false;
    const context = AppContextHolder.get();
    if (context !== null) {
      backgroundTaskManager.stopBackgroundRunning(context).catch((): void => {
        // 忽略停止失败（任务可能已结束）
      });
    }
    const id: number = this.notificationId;
    this.notificationId = -1;
    this.lastPercent = -1;
    if (id >= 0) {
      notificationManager.cancel(id).catch((): void => {
        // 忽略撤除失败
      });
    }
  }

  // ==================== 内部 ====================

  /** 进度落发 */
  private flushProgress(): void {
    if (this.progressTimer >= 0) {
      clearTimeout(this.progressTimer);
      this.progressTimer = -1;
    }
    const percent: number = this.pendingPercent;
    this.pendingPercent = -1;
    if (percent < 0 || percent === this.lastPercent) {
      return;
    }
    this.lastPercent = percent;
    this.lastProgressAt = Date.now();
    this.publish(percent);
  }

  private clearProgressTimer(): void {
    if (this.progressTimer >= 0) {
      clearTimeout(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  /** 起长时任务（幂等；失败不阻断前台下载） */
  private async startTask(): Promise<void> {
    if (this.running) {
      return;
    }
    const context = AppContextHolder.get();
    if (context === null) {
      return;
    }
    if (!await this.ensureAgents()) {
      return;
    }
    // 模板预检：不支持则仅持有长时任务默认通知，不做实况窗发布
    try {
      this.templateSupported = await notificationManager.isSupportTemplate(DownloadNotifyEvents.TEMPLATE_NAME);
    } catch (err) {
      this.templateSupported = false;
    }
    try {
      const result: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], this.launchAgent as WantAgent);
      this.notificationId = result.notificationId;
      this.running = true;
    } catch (err) {
      this.running = false;
      return;
    }
    this.publish(this.lastPercent >= 0 ? this.lastPercent : 0);
  }

  /** 构建并缓存三个 wantAgent（Promise 接口；任一失败返回 false） */
  private async ensureAgents(): Promise<boolean> {
    if (this.launchAgent !== null) {
      return true;
    }
    const launch: WantAgent | null = await this.buildLaunchAgent();
    const pause: WantAgent | null = await this.buildEventAgent(DownloadNotifyEvents.PAUSE_ALL);
    const cancel: WantAgent | null = await this.buildEventAgent(DownloadNotifyEvents.CANCEL_ACTIVE);
    if (launch === null) {
      return false;
    }
    this.launchAgent = launch;
    this.pauseAgent = pause;
    this.cancelAgent = cancel;
    return true;
  }

  /** 发布实况窗通知（同一 id 反复 publish 即更新；失败静默走默认通知兜底） */
  private publish(percent: number): void {
    if (!this.running || this.notificationId < 0 || !this.templateSupported || this.launchAgent === null) {
      return;
    }
    const buttons: Array<notificationManager.NotificationActionButton> = [];
    if (this.pauseAgent !== null) {
      const button: notificationManager.NotificationActionButton = {
        title: '暂停',
        wantAgent: this.pauseAgent
      };
      buttons.push(button);
    }
    if (this.cancelAgent !== null) {
      const button: notificationManager.NotificationActionButton = {
        title: '取消',
        wantAgent: this.cancelAgent
      };
      buttons.push(button);
    }
    const liveViewButton: notificationManager.NotificationButton = { names: ['暂停', '取消'] };
    const liveView: notificationManager.NotificationSystemLiveViewContent = {
      title: this.currentTitle,
      text: this.currentFileName,
      typeCode: 8,
      button: liveViewButton
    };
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
      systemLiveView: liveView
    };
    const templateData: Record<string, Object> = {
      'title': this.currentTitle,
      'fileName': this.currentFileName,
      'progressValue': percent
    };
    const template: notificationManager.NotificationTemplate = {
      name: DownloadNotifyEvents.TEMPLATE_NAME,
      data: templateData
    };
    const request: notificationManager.NotificationRequest = {
      id: this.notificationId,
      content: content,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template: template,
      actionButtons: buttons,
      wantAgent: this.launchAgent
    };
    notificationManager.publish(request).catch((): void => {
      // 实况窗发布失败（权限/模板受限）：默认通知兜底，不影响下载
    });
  }

  /** 订阅通知动作事件（一次即可，进程内常驻） */
  private subscribeOnce(): void {
    if (this.subscribed) {
      return;
    }
    this.subscribed = true;
    const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
      events: [DownloadNotifyEvents.PAUSE_ALL, DownloadNotifyEvents.CANCEL_ACTIVE]
    };
    commonEventManager.createSubscriber(subscribeInfo)
      .then((subscriber: commonEventManager.CommonEventSubscriber): void => {
        commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData): void => {
          if (err !== null && err !== undefined) {
            return;
          }
          const event: string = data.event;
          if (event === DownloadNotifyEvents.PAUSE_ALL && this.onPauseAll !== null) {
            this.onPauseAll();
          } else if (event === DownloadNotifyEvents.CANCEL_ACTIVE && this.onCancelActive !== null) {
            this.onCancelActive();
          }
        });
      })
      .catch((): void => {
        // 订阅失败：通知按钮不可用，页面内操作不受影响
        this.subscribed = false;
      });
  }

  /** 点击通知 → 回应用（START_ABILITY） */
  private async buildLaunchAgent(): Promise<WantAgent | null> {
    const want: Want = {
      bundleName: 'me.sweetll.tucao',
      abilityName: 'EntryAbility'
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0
    };
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      return agent;
    } catch (err) {
      return null;
    }
  }

  /** 通知按钮 → 公共事件（SEND_COMMON_EVENT，action = 事件名） */
  private async buildEventAgent(event: string): Promise<WantAgent | null> {
    const want: Want = {
      action: event,
      bundleName: 'me.sweetll.tucao'
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.SEND_COMMON_EVENT,
      requestCode: 0
    };
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      return agent;
    } catch (err) {
      return null;
    }
  }
}

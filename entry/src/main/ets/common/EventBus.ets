/**
 * 事件总线封装（基于 @ohos/liveeventbus）
 * - 类型安全：每个事件有独立 key + 载荷类，避免裸字符串散落
 * - 全部为进程内事件（autoCrossProcess=false），observeForever + 手动解订阅
 * - on* 方法返回取消订阅函数，调用方须在 aboutToDisappear 中执行，防止泄漏
 */
import { LiveEventBus, Observer } from '@ohos/liveeventbus';

/** 事件 key 常量 */
export class EventKeys {
  /** 登录态变化 */
  static readonly LOGIN_CHANGED: string = 'event_login_changed';
  /** 下载任务状态变化（hid 级） */
  static readonly DOWNLOAD_CHANGED: string = 'event_download_changed';
  /** 未读消息数变化 */
  static readonly UNREAD_CHANGED: string = 'event_unread_changed';
  /** 收藏变化（hid 级） */
  static readonly STAR_CHANGED: string = 'event_star_changed';
}

/** 登录态变化载荷 */
export class LoginChangedEvent {
  loggedIn: boolean = false;

  constructor(loggedIn: boolean) {
    this.loggedIn = loggedIn;
  }
}

/** 下载任务状态变化载荷 */
export class DownloadChangedEvent {
  hid: string = '';

  constructor(hid: string) {
    this.hid = hid;
  }
}

/** 未读消息数变化载荷 */
export class UnreadCountChangedEvent {
  count: number = 0;

  constructor(count: number) {
    this.count = count;
  }
}

/** 收藏变化载荷 */
export class StarChangedEvent {
  hid: string = '';

  constructor(hid: string) {
    this.hid = hid;
  }
}

export class EventBus {
  /** 通用订阅：返回取消订阅函数（调用方须在 aboutToDisappear 中调用） */
  static on<T>(key: string, callback: (event: T) => void): () => void {
    const observer: Observer<T> = {
      onChanged: (event: T): void => {
        callback(event);
      }
    };
    LiveEventBus.get<T>(key, false).observeForever(observer);
    return (): void => {
      LiveEventBus.get<T>(key, false).removeObserver(observer);
    };
  }

  /** 登录态变化：发送 */
  static postLoginChanged(loggedIn: boolean): void {
    LiveEventBus.get<LoginChangedEvent>(EventKeys.LOGIN_CHANGED, false)
      .post(new LoginChangedEvent(loggedIn));
  }

  /** 登录态变化：订阅 */
  static onLoginChanged(callback: (event: LoginChangedEvent) => void): () => void {
    return EventBus.on<LoginChangedEvent>(EventKeys.LOGIN_CHANGED, callback);
  }

  /** 下载态变化：发送 */
  static postDownloadChanged(hid: string): void {
    LiveEventBus.get<DownloadChangedEvent>(EventKeys.DOWNLOAD_CHANGED, false)
      .post(new DownloadChangedEvent(hid));
  }

  /** 下载态变化：订阅 */
  static onDownloadChanged(callback: (event: DownloadChangedEvent) => void): () => void {
    return EventBus.on<DownloadChangedEvent>(EventKeys.DOWNLOAD_CHANGED, callback);
  }

  /** 未读数变化：发送 */
  static postUnreadChanged(count: number): void {
    LiveEventBus.get<UnreadCountChangedEvent>(EventKeys.UNREAD_CHANGED, false)
      .post(new UnreadCountChangedEvent(count));
  }

  /** 未读数变化：订阅 */
  static onUnreadChanged(callback: (event: UnreadCountChangedEvent) => void): () => void {
    return EventBus.on<UnreadCountChangedEvent>(EventKeys.UNREAD_CHANGED, callback);
  }

  /** 收藏变化：发送 */
  static postStarChanged(hid: string): void {
    LiveEventBus.get<StarChangedEvent>(EventKeys.STAR_CHANGED, false)
      .post(new StarChangedEvent(hid));
  }

  /** 收藏变化：订阅 */
  static onStarChanged(callback: (event: StarChangedEvent) => void): () => void {
    return EventBus.on<StarChangedEvent>(EventKeys.STAR_CHANGED, callback);
  }
}

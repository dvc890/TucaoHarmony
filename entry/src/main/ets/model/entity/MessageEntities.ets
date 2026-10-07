/**
 * 私信实体
 * 字段对齐安卓版 MessageList.kt / MessageDetail.kt：
 * - MessageSummary：收件箱会话项（未读 = 站点 em.bgblue 存在）
 * - MessageDetailItem：会话明细气泡（左=对方 / 右=自己）
 */
import { JsonCoerce } from './BaseEntities';

/** 收件箱会话项 */
@ObservedV2
export class MessageSummary {
  /** 会话 id（messageid） */
  @Trace id: string = '';
  /** 对方用户名 */
  @Trace username: string = '';
  /** 对方头像 */
  @Trace avatar: string = '';
  /** 会话时间（已去「对话于 」前缀） */
  @Trace time: string = '';
  /** 最后一条消息预览 */
  @Trace message: string = '';
  /** 是否已读（站点 em.bgblue 存在 = 未读） */
  @Trace read: boolean = true;

  static fromRecord(obj: Record<string, Object>): MessageSummary {
    const m: MessageSummary = new MessageSummary();
    m.id = JsonCoerce.asString(obj['id']);
    m.username = JsonCoerce.asString(obj['username']);
    m.avatar = JsonCoerce.asString(obj['avatar']);
    m.time = JsonCoerce.asString(obj['time']);
    m.message = JsonCoerce.asString(obj['message']);
    m.read = JsonCoerce.asBoolean(obj['read'], true);
    return m;
  }

  toRecord(): Record<string, Object> {
    const record: Record<string, Object> = {
      'id': this.id,
      'username': this.username,
      'avatar': this.avatar,
      'time': this.time,
      'message': this.message,
      'read': this.read
    };
    return record;
  }
}

/** 会话明细气泡类型 */
export enum MessageBubbleType {
  /** 对方消息（左侧） */
  LEFT = 0,
  /** 自己消息（右侧） */
  RIGHT = 1
}

/** 会话明细气泡 */
@ObservedV2
export class MessageDetailItem {
  /** 发送者头像 */
  @Trace avatar: string = '';
  /** 消息文本 */
  @Trace message: string = '';
  /** 发送时间 */
  @Trace time: string = '';
  /** 气泡方向 */
  @Trace type: MessageBubbleType = MessageBubbleType.LEFT;
  /** 乐观发送标记（false = “发射中”占位） */
  @Trace hasSend: boolean = true;
}

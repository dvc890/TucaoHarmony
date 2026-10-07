/**
 * 私信会话 VM
 * 单例（MessageList.open → prepare → 路由跳转，对齐项目「经 VM 单例传递」惯例）
 * 对齐安卓版 MessageDetailViewModel：
 * - read HTML 解析 → 左右气泡明细
 * - 回复：乐观「发射中」气泡插入，成功后回抓会话，失败移除回滚（仅回复，不发新私信）
 */
import { MessageSummary, MessageDetailItem, MessageBubbleType } from '../model/entity/MessageEntities';
import { MessageRepository } from '../model/repository/MessageRepository';
import { SessionService } from '../service/session/SessionService';

@ObservedV2
export class MessageDetailVM {
  /** 单例（同一时间仅一个会话） */
  private static instance: MessageDetailVM | null = null;

  static shared(): MessageDetailVM {
    if (MessageDetailVM.instance === null) {
      MessageDetailVM.instance = new MessageDetailVM();
    }
    return MessageDetailVM.instance;
  }

  /** 对话对象（收件箱会话摘要） */
  @Trace peer: MessageSummary | null = null;
  /** 气泡明细 */
  @Trace items: MessageDetailItem[] = [];
  /** 加载中 */
  @Trace loading: boolean = false;
  /** 加载失败文案 */
  @Trace error: string = '';
  /** 回复草稿 */
  @Trace draft: string = '';
  /** 发送中 */
  @Trace sending: boolean = false;

  private readonly repo: MessageRepository = MessageRepository.shared();

  /** 上下文注入（路由跳转前调用） */
  prepare(summary: MessageSummary): void {
    this.peer = summary;
    this.items = [];
    this.error = '';
    this.draft = '';
  }

  /** 页面挂载：拉取会话明细 */
  init(): void {
    if (this.peer === null) {
      return;
    }
    this.load();
  }

  /** 拉取会话明细（对方头像/自己头像 → 左右气泡方向） */
  async load(): Promise<void> {
    const peer: MessageSummary | null = this.peer;
    if (peer === null || this.loading) {
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const selfAvatar: string = SessionService.shared().currentUser().avatar;
      this.items = await this.repo.fetchDetail(peer.id, peer.avatar, selfAvatar);
    } catch (err) {
      this.error = '会话加载失败，请重试';
    } finally {
      this.loading = false;
    }
  }

  /** 发送回复（乐观插入右侧「发射中」气泡，失败回滚） */
  async send(): Promise<string> {
    // 返回值：'' 成功 / 其他为错误文案
    const peer: MessageSummary | null = this.peer;
    if (peer === null || this.sending) {
      return '';
    }
    const content: string = this.draft.trim();
    if (content.length === 0) {
      return '先说点什么吧';
    }
    this.sending = true;
    // 乐观插入（右侧 + 发射中）
    const optimistic: MessageDetailItem = new MessageDetailItem();
    optimistic.avatar = SessionService.shared().currentUser().avatar;
    optimistic.message = content;
    optimistic.type = MessageBubbleType.RIGHT;
    optimistic.hasSend = false;
    this.items.push(optimistic);
    try {
      await this.repo.reply(peer.id, content, peer.username);
      this.draft = '';
      // 回抓会话拿到服务端时间
      await this.load();
      return '';
    } catch (err) {
      // 失败回滚：移除占位气泡
      const index: number = this.items.indexOf(optimistic);
      if (index >= 0) {
        this.items.splice(index, 1);
      }
      return '回复发送失败，请重试';
    } finally {
      this.sending = false;
    }
  }
}

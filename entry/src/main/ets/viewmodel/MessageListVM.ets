/**
 * 私信收件箱 VM
 * 对齐安卓版 MessageListViewModel + 未读角标联动：
 * - inbox HTML 解析 → 会话列表（头像/用户名/时间/预览/未读标记）
 * - 打开未读会话：本地置已读 + SessionService.markOneMessageRead（未读数-1 → EventBus 联动侧边栏角标）
 * - 所选会话经 MessageDetailVM 单例传递（Router 注释约定的项目惯例）
 */
import { Router } from '../common/Router';
import { GlobalState } from '../common/GlobalState';
import { MessageSummary } from '../model/entity/MessageEntities';
import { MessageRepository } from '../model/repository/MessageRepository';
import { MessageDetailVM } from './MessageDetailVM';
import { SessionService } from '../service/session/SessionService';

@ObservedV2
export class MessageListVM {
  /** 会话列表 */
  @Trace summaries: MessageSummary[] = [];
  /** 加载中 */
  @Trace loading: boolean = false;
  /** 加载失败文案 */
  @Trace error: string = '';

  private readonly repo: MessageRepository = MessageRepository.shared();

  /** 是否已登录 */
  isLoggedIn(): boolean {
    return GlobalState.sessionState().isLoggedIn;
  }

  /** 进入页面：拉取收件箱 */
  init(): void {
    this.load();
  }

  /** 拉取收件箱 */
  async load(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      this.summaries = await this.repo.fetchInbox();
    } catch (err) {
      this.error = '收件箱加载失败，请重试';
    } finally {
      this.loading = false;
    }
  }

  /** 打开会话（未读 → 本地置已读 + 角标联动；上下文注入 MessageDetailVM 后跳转） */
  open(summary: MessageSummary): void {
    if (!summary.read) {
      summary.read = true;
      SessionService.shared().markOneMessageRead();
    }
    MessageDetailVM.shared().prepare(summary);
    Router.goMessageDetail();
  }
}

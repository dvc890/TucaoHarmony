/**
 * 楼中楼 VM
 * 对齐安卓版 ReplyViewModel：
 * - 单例承载楼中楼上下文（CommentsVM.openReplyFloor 先 prepare 再路由跳转，
 *   对齐 Router 注释中「经 VM 单例传递」的项目惯例）
 * - ajax 楼中楼分页：page 从 0 起、num=10，按楼中楼 id 升序展示
 * - 发送回复：未登录跳登录；乐观「发射中」插入，失败回滚；成功后回抓第一页
 */
import { Router } from '../common/Router';
import { GlobalState } from '../common/GlobalState';
import { Comment, Reply } from '../model/entity/CommentEntities';
import { CommentRepository } from '../model/repository/CommentRepository';

@ObservedV2
export class ReplyVM {
  /** 单例（楼中楼同一时间仅一个会话） */
  private static instance: ReplyVM | null = null;

  static shared(): ReplyVM {
    if (ReplyVM.instance === null) {
      ReplyVM.instance = new ReplyVM();
    }
    return ReplyVM.instance;
  }

  /** 父评论（置顶展示） */
  @Trace parent: Comment | null = null;
  /** 本页楼中楼回复（id 升序） */
  @Trace replies: Reply[] = [];
  /** 当前页（0 起，站点 ajax 口径） */
  @Trace page: number = 0;
  /** 总回复数 */
  @Trace total: number = 0;
  /** 加载中 */
  @Trace loading: boolean = false;
  /** 加载失败文案 */
  @Trace error: string = '';
  /** 回复输入草稿 */
  @Trace draft: string = '';
  /** 发送中 */
  @Trace sending: boolean = false;
  /** 回复内容可用宽度（vp） */
  @Trace contentWidthVp: number = 320;

  /** 所属评论 commentid（content_10-xxx-1 形态） */
  private commentid: string = '';
  /** 父评论数字 id */
  private replyId: string = '';
  private readonly repo: CommentRepository = CommentRepository.shared();

  /** 最大页码（1 起，展示用） */
  get maxPage(): number {
    return Math.max(Math.ceil(this.total / 10), 1);
  }

  /** 上下文注入（路由跳转前调用） */
  prepare(commentid: string, parent: Comment): void {
    this.commentid = commentid;
    this.parent = parent;
    this.replyId = parent.id;
    this.replies = [];
    this.page = 0;
    this.total = parent.replyNum;
    this.error = '';
    this.draft = '';
  }

  /** 页面挂载：加载第一页 */
  init(): void {
    if (this.parent === null || this.commentid.length === 0) {
      return;
    }
    this.loadPage(0);
  }

  /** 是否已登录 */
  isLoggedIn(): boolean {
    return GlobalState.sessionState().isLoggedIn;
  }

  /** 加载指定页（0 起） */
  async loadPage(page: number): Promise<void> {
    if (this.loading || this.commentid.length === 0) {
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const result = await this.repo.fetchReplyFloor(this.commentid, this.replyId, page, 10);
      // 楼中楼 id 升序（楼层顺序）
      const sorted: Reply[] = result.replies.slice(0);
      sorted.sort((a: Reply, b: Reply): number => {
        const ai: number = Number(a.id);
        const bi: number = Number(b.id);
        return ai - bi;
      });
      this.replies = sorted;
      this.total = result.total;
      this.page = page;
    } catch (err) {
      this.error = '回复加载失败，请重试';
    } finally {
      this.loading = false;
    }
  }

  /** 上一页 */
  prevPage(): void {
    if (this.page > 0) {
      this.loadPage(this.page - 1);
    }
  }

  /** 下一页 */
  nextPage(): void {
    if (this.page + 1 < this.maxPage) {
      this.loadPage(this.page + 1);
    }
  }

  /** 发送回复（未登录跳登录；乐观插入，失败回滚） */
  async send(): Promise<string> {
    // 返回值：'' 成功 / 'needLogin' 需登录 / 其他为错误文案
    if (this.sending) {
      return '';
    }
    const content: string = this.draft.trim();
    if (content.length === 0) {
      return '先说点什么吧';
    }
    if (!this.isLoggedIn()) {
      Router.goLogin();
      return 'needLogin';
    }
    this.sending = true;
    // 乐观「发射中」占位（置于列表末尾）
    const optimistic: Reply = new Reply();
    optimistic.avatar = GlobalState.sessionState().userAvatar;
    optimistic.nickname = GlobalState.sessionState().userName;
    optimistic.content = content;
    optimistic.contentHtml = content;
    optimistic.hasSend = false;
    this.replies.push(optimistic);
    try {
      await this.repo.sendReply(this.commentid, this.replyId, content);
      this.draft = '';
      // 回抓第一页拿到服务端楼层
      await this.loadPage(0);
      return '';
    } catch (err) {
      // 失败回滚：移除占位项
      const index: number = this.replies.indexOf(optimistic);
      if (index >= 0) {
        this.replies.splice(index, 1);
      }
      return '回复发射失败，请重试';
    } finally {
      this.sending = false;
    }
  }
}

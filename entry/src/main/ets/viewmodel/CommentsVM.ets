/**
 * 视频「评论」Tab VM
 * 对齐安卓版 VideoCommentsFragment：
 * - 每页 20 条（comment init 接口 page 参数），支持上一页/下一页
 * - 点赞（support）乐观 +1，失败回滚
 * - 未登录发表 → 跳转登录页
 * - 发表评论：乐观插入「发射中」占位（hasSend=false），成功后回抓第一页，失败移除回滚
 * - 点击评论进入楼中楼：上下文经 ReplyVM 单例传递（对齐 MessageVM 单例模式）
 */
import { display } from '@kit.ArkUI';
import { Router } from '../common/Router';
import { GlobalState } from '../common/GlobalState';
import { Comment } from '../model/entity/CommentEntities';
import { CommentRepository } from '../model/repository/CommentRepository';
import { ReplyVM } from './ReplyVM';

@ObservedV2
export class CommentsVM {
  /** 本页评论 */
  @Trace comments: Comment[] = [];
  /** 当前页码（1 起） */
  @Trace page: number = 1;
  /** 最大页码 */
  @Trace maxPage: number = 1;
  /** 加载中 */
  @Trace loading: boolean = false;
  /** 加载失败文案（非空展示重试） */
  @Trace error: string = '';
  /** 评论输入框草稿 */
  @Trace draft: string = '';
  /** 发送中（防重复提交） */
  @Trace sending: boolean = false;
  /** 评论内容可用宽度（vp，供富文本图片排版） */
  @Trace contentWidthVp: number = 320;

  private typeid: number = 0;
  private hid: string = '';
  private commentid: string = '';
  private readonly repo: CommentRepository = CommentRepository.shared();

  /** 初始化（VideoDetail 评论 Tab 挂载 / 视频切换时调用） */
  init(typeid: number, hid: string): void {
    this.typeid = typeid;
    this.hid = hid;
    this.commentid = CommentRepository.commentIdOf(typeid, hid);
    this.comments = [];
    this.page = 1;
    this.maxPage = 1;
    this.error = '';
    // 富文本排版宽度：屏宽 - 页面两侧 16*2 - 头像 36 - 间距 12
    const disp: display.Display = display.getDefaultDisplaySync();
    const density: number = disp.densityPixels > 0 ? disp.densityPixels : 3;
    this.contentWidthVp = disp.width / density - 80;
    this.loadPage(1);
  }

  /** 是否已登录 */
  isLoggedIn(): boolean {
    return GlobalState.sessionState().isLoggedIn;
  }

  /** 加载指定页评论 */
  async loadPage(page: number): Promise<void> {
    if (this.loading || this.commentid.length === 0) {
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const result = await this.repo.fetchComments(this.commentid, page);
      this.comments = result.comments;
      this.maxPage = Math.max(result.maxPage, 1);
      this.page = Math.min(Math.max(page, 1), this.maxPage);
    } catch (err) {
      this.error = '评论加载失败，请重试';
    } finally {
      this.loading = false;
    }
  }

  /** 上一页 */
  prevPage(): void {
    if (this.page > 1) {
      this.loadPage(this.page - 1);
    }
  }

  /** 下一页 */
  nextPage(): void {
    if (this.page < this.maxPage) {
      this.loadPage(this.page + 1);
    }
  }

  /** 点赞（乐观 +1，失败回滚；对齐安卓版结果丢弃口径，本地仍回滚保证一致） */
  async toggleSupport(comment: Comment): Promise<boolean> {
    if (comment.support || comment.id.length === 0) {
      return false;
    }
    comment.support = true;
    comment.thumbUp = comment.thumbUp + 1;
    try {
      await this.repo.support(this.commentid, comment.id);
      return true;
    } catch (err) {
      // 回滚乐观计数
      comment.support = false;
      comment.thumbUp = Math.max(comment.thumbUp - 1, 0);
      return false;
    }
  }

  /** 发表评论（未登录跳登录；乐观「发射中」占位，失败回滚） */
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
    // 乐观插入「发射中」占位（hasSend=false），置于列表顶部（第一页为最新页）
    const optimistic: Comment = new Comment();
    optimistic.avatar = GlobalState.sessionState().userAvatar;
    optimistic.nickname = GlobalState.sessionState().userName;
    optimistic.info = content;
    optimistic.infoHtml = content;
    optimistic.lch = '';
    optimistic.time = '';
    optimistic.hasSend = false;
    optimistic.support = true;
    if (this.page === 1) {
      this.comments.unshift(optimistic);
    }
    try {
      await this.repo.sendComment(this.commentid, content);
      this.draft = '';
      // 回抓第一页拿到服务端楼层/时间
      await this.loadPage(1);
      return '';
    } catch (err) {
      // 失败回滚：移除占位项
      const index: number = this.comments.indexOf(optimistic);
      if (index >= 0) {
        this.comments.splice(index, 1);
      }
      return '评论发射失败，请重试';
    } finally {
      this.sending = false;
    }
  }

  /** 进入楼中楼（上下文经 ReplyVM 单例传递） */
  openReplyFloor(comment: Comment): void {
    ReplyVM.shared().prepare(this.commentid, comment);
    Router.goReplyFloor(this.typeid, Number(comment.id));
  }
}

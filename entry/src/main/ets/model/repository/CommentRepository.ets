/**
 * 评论数据仓库
 * 协议对齐安卓版 VideoCommentsFragment / ReplyViewModel / RawApiService，禁止改动后端约定：
 * - 列表：GET RawApi.COMMENT（commentid + page，HTML 分页）→ div.width.clist 解析；
 *   commentid 约定 content_{typeid==0?10:typeid}-{hid}-1
 * - 楼中楼：GET JsonApi.REPLY（commentid + id + page + num，page 0 基）→ JSON
 * - 发表：POST RawApi.SEND_COMMENT（query commentid + form content）→ 含「成功」判定
 * - 楼中楼回复：POST RawApi.SEND_REPLY（query commentid + id + form content，沿用 replyuid=undefined 后缀）
 * - 点赞：GET RawApi.SUPPORT（commentid + id）→ 结果忽略（对齐安卓版 fire-and-forget）
 * 解析口径：level 硬编码 "Lv?"、thumbUp 默认 0、楼层/时间取 div.ct 文本正则、
 * 评论 id 取 div.ct 首子元素 onclick 的 reply(this, id, 'cid') 正则。
 */
import { Element } from 'domhandler';
import { getInnerHTML } from 'domutils';
import { ApiParams, JsonApi, RawApi } from '../../common/Constants';
import { Comment, CommentPage, ReplyFloorPage } from '../entity/CommentEntities';
import { JsonCoerce } from '../entity/BaseEntities';
import { HtmlParseUtil } from '../../service/api/HtmlParseUtil';
import { TucaoApiClient } from '../../service/api/TucaoApiClient';
import { Document } from 'domhandler';

/** 评论数字 id 与 cid 的 onclick 正则提取结果 */
export class ReplyTarget {
  readonly numericId: string;
  readonly cid: string;

  constructor(numericId: string, cid: string) {
    this.numericId = numericId;
    this.cid = cid;
  }
}

export class CommentRepository {
  private static instance: CommentRepository | undefined;

  static shared(): CommentRepository {
    if (CommentRepository.instance === undefined) {
      CommentRepository.instance = new CommentRepository();
    }
    return CommentRepository.instance;
  }

  private readonly client: TucaoApiClient = TucaoApiClient.getInstance();

  /** 视频 typeid+hid → commentid（对齐安卓版 content_${...}-${hid}-1） */
  static commentIdOf(typeid: number, hid: string): string {
    const realTid: number = typeid === 0 ? 10 : typeid;
    return `content_${realTid}-${hid}-1`;
  }

  /** 评论列表（page 1 起，站点 HTML 分页） */
  async fetchComments(commentId: string, page: number): Promise<CommentPage> {
    const html: string = await this.client.getRawText(RawApi.COMMENT, {
      'commentid': commentId,
      'page': `${page}`
    });
    const doc: Document = HtmlParseUtil.parse(html);
    return new CommentPage(CommentRepository.parseComments(doc), CommentRepository.parseMaxPage(doc));
  }

  /**
   * 楼中楼分页（page 0 基，每页 num 条，对齐安卓版 JsonApiService.reply）
   * 注：REPLY 为绝对地址（不落 api_v2 前缀），走通用 GET；apikey/type=json 由安卓版
   * json OkHttp 拦截器对全部 JsonApiService 请求统一注入，此处显式补齐。
   */
  async fetchReplyFloor(commentId: string, replyId: string, page: number, num: number): Promise<ReplyFloorPage> {
    const text: string = await this.client.getXmlText(JsonApi.REPLY, {
      'commentid': commentId,
      'replyid': replyId,
      'page': `${page}`,
      'num': `${num}`,
      'apikey': ApiParams.API_KEY,
      'type': ApiParams.TYPE_JSON
    });
    const root: Record<string, Object> | undefined = JsonCoerce.parseRecord(text);
    if (root === undefined) {
      throw new Error('楼中楼响应不是合法 JSON');
    }
    return ReplyFloorPage.fromJson(root);
  }

  /** 发表评论（返回响应全文；含「成功」由 VM 判定展示） */
  async sendComment(commentId: string, content: string): Promise<void> {
    const path: string = `${RawApi.SEND_COMMENT}&commentid=${encodeURIComponent(commentId)}`;
    const responseText: string = await this.client.postFormText(path, { 'content': content }, true);
    if (!CommentRepository.bodyTextOf(responseText).includes('成功')) {
      throw new Error(CommentRepository.bodyTextOf(responseText));
    }
  }

  /** 楼中楼回复（对齐安卓版 sendReply：query commentid+id，form content） */
  async sendReply(commentId: string, replyId: string, content: string): Promise<void> {
    const path: string =
      `${RawApi.SEND_REPLY}&commentid=${encodeURIComponent(commentId)}&id=${encodeURIComponent(replyId)}`;
    const responseText: string = await this.client.postFormText(path, { 'content': content }, true);
    if (!CommentRepository.bodyTextOf(responseText).includes('成功')) {
      throw new Error(CommentRepository.bodyTextOf(responseText));
    }
  }

  /** 评论点赞（对齐安卓版：结果与失败均忽略） */
  async support(commentId: string, id: string): Promise<void> {
    try {
      await this.client.getRawText(RawApi.SUPPORT, {
        'commentid': commentId,
        'id': id
      });
    } catch (err) {
      // 点赞为乐观 UI，失败不回滚（对齐安卓版）
    }
  }

  /** div.width.clist → 评论列表（对齐安卓版 parseComments） */
  static parseComments(doc: Document): Comment[] {
    const comments: Comment[] = [];
    const listDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'div', 'clist');
    if (listDiv === undefined) {
      return comments;
    }
    // 注意：安卓版选择器为 div.width.clist（width + clint 双 class）；单 class 命中后校验 width
    if (!HtmlParseUtil.hasClass(listDiv, 'width')) {
      return comments;
    }
    const regexLctTime: RegExp = /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) · (-?\d+楼)/;
    const regexReplyFun: RegExp = /reply\(this,\s*(\d+),\s*'(.*)'\)/;
    const items: Element[] = HtmlParseUtil.childElements(listDiv);
    for (let i = 0; i < items.length; i++) {
      const item: Element = items[i];
      // 安卓版按 className == "item" 精确匹配
      if (HtmlParseUtil.attr(item, 'class').trim() !== 'item') {
        continue;
      }
      comments.push(CommentRepository.parseCommentItem(item, regexLctTime, regexReplyFun));
    }
    return comments;
  }

  /** 单条评论 item 解析 */
  private static parseCommentItem(item: Element, regexLctTime: RegExp, regexReplyFun: RegExp): Comment {
    const comment: Comment = new Comment();
    // 头像：div.left > 首子元素 src
    const leftDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'div', 'left');
    if (leftDiv !== undefined) {
      const avatarNodes: Element[] = HtmlParseUtil.childElements(leftDiv);
      if (avatarNodes.length > 0) {
        comment.avatar = avatarNodes[0].name === 'img' ? HtmlParseUtil.attr(avatarNodes[0], 'src') : '';
      }
    }
    // 昵称与空间：div.cu > 首子元素（a 标签）
    const cuDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'div', 'cu');
    if (cuDiv !== undefined) {
      const userNodes: Element[] = HtmlParseUtil.childElements(cuDiv);
      if (userNodes.length > 0) {
        comment.userUrl = HtmlParseUtil.attr(userNodes[0], 'href');
        comment.nickname = HtmlParseUtil.text(userNodes[0]).trim();
      }
    }
    // 内容：div.cc 文本（纯文本）+ 内层 HTML（富文本渲染用）
    const ccDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'div', 'cc');
    if (ccDiv !== undefined) {
      comment.info = HtmlParseUtil.text(ccDiv).trim();
      try {
        comment.infoHtml = getInnerHTML(ccDiv);
      } catch (err) {
        comment.infoHtml = '';
      }
    }
    // 时间与楼层：div.ct 文本正则；评论 id：div.ct 首子元素 onclick 正则
    const ctDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'div', 'ct');
    if (ctDiv !== undefined) {
      const ctText: string = HtmlParseUtil.text(ctDiv);
      const matchTime: RegExpExecArray | null = regexLctTime.exec(ctText);
      if (matchTime !== null) {
        comment.time = matchTime[1];
        comment.lch = matchTime[2];
      }
      const ctChildren: Element[] = HtmlParseUtil.childElements(ctDiv);
      if (ctChildren.length > 0) {
        const onclick: string = HtmlParseUtil.attr(ctChildren[0], 'onclick');
        const target: ReplyTarget | undefined = CommentRepository.parseReplyTarget(onclick, regexReplyFun);
        if (target !== undefined) {
          comment.id = target.numericId;
        }
      }
    }
    // 回复数：div.replys.cr_link 的 replys 属性
    const replysDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'div', 'replys');
    if (replysDiv !== undefined && HtmlParseUtil.hasClass(replysDiv, 'cr_link')) {
      const replysText: string = HtmlParseUtil.attr(replysDiv, 'replys');
      const parsed: number = Number.parseInt(replysText);
      comment.replyNum = Number.isNaN(parsed) ? 0 : parsed;
    }
    return comment;
  }

  /** onclick="reply(this, 12345, 'xxx')" → 数字 id（楼中楼/点赞用）；cid 沿用原版丢弃 */
  private static parseReplyTarget(onclick: string, regexReplyFun: RegExp): ReplyTarget | undefined {
    const match: RegExpExecArray | null = regexReplyFun.exec(onclick);
    if (match === null) {
      return undefined;
    }
    return new ReplyTarget(match[1], match[2]);
  }

  /** div.pages → 最大页码（对齐安卓版 children[size-3]；结构缺失返回 1） */
  static parseMaxPage(doc: Document): number {
    const pagesDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'div', 'pages');
    if (pagesDiv === undefined) {
      return 1;
    }
    const children: Element[] = HtmlParseUtil.childElements(pagesDiv);
    if (children.length < 3) {
      return 1;
    }
    const parsed: number = Number.parseInt(HtmlParseUtil.text(children[children.length - 3]).trim());
    return Number.isNaN(parsed) || parsed < 1 ? 1 : parsed;
  }

  /** HTML 响应 → 全文文本（对齐安卓版 Jsoup.body().text() 判定口径） */
  private static bodyTextOf(htmlText: string): string {
    return HtmlParseUtil.text(HtmlParseUtil.parse(htmlText));
  }
}

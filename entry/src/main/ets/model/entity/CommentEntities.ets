/**
 * 评论实体
 * 字段对齐安卓版 Comment.kt / Reply.kt / ReplyResponse.kt：
 * - Comment：评论列表项（level 硬编码 "Lv?"、thumbUp 默认 0，沿用原版口径）
 * - Reply：楼中楼回复（data 为 Map<String, Reply>，键为楼中楼 id）
 * - ReplyFloorPage：ajax 楼中楼分页结果（total/lastupdate 等字段宽松解析）
 */
import { JsonCoerce } from './BaseEntities';

/** 评论列表项（HTML 抓取解析产出） */
@ObservedV2
export class Comment {
  /** 评论者头像 */
  @Trace avatar: string = '';
  /** 评论者空间地址 */
  @Trace userUrl: string = '';
  /** 等级标签（站点已不输出，硬编码 "Lv?" 沿用原版） */
  @Trace level: string = 'Lv?';
  /** 评论者昵称 */
  @Trace nickname: string = '';
  /** 点赞数（站点已不输出，默认 0 沿用原版；乐观 +1 由 UI 维护） */
  @Trace thumbUp: number = 0;
  /** 楼层文案（如 "-3楼"/"24楼"） */
  @Trace lch: string = '';
  /** 发表时间（"yyyy-MM-dd HH:mm:ss"） */
  @Trace time: string = '';
  /** 评论纯文本（实体已解码；富文本见 infoHtml） */
  @Trace info: string = '';
  /** 评论原始 HTML（div.cc 内层 HTML，富文本渲染用；为空时回退 info） */
  @Trace infoHtml: string = '';
  /** 评论数字 id（楼中楼 replyid / 点赞 id） */
  @Trace id: string = '';
  /** 回复数 */
  @Trace replyNum: number = 0;
  /** 乐观发送标记（false = “发射中”占位） */
  @Trace hasSend: boolean = true;
  /** 本地已点赞标记（乐观 +1 后置位） */
  @Trace support: boolean = false;
}

/** 楼中楼回复项（ajax JSON） */
@ObservedV2
export class Reply {
  /** 楼中楼 id */
  @Trace id: string = '';
  /** 回复者头像 */
  @Trace avatar: string = '';
  /** 回复者昵称 */
  @Trace nickname: string = '';
  /** 发表时间（creat_at） */
  @Trace time: string = '';
  /** 回复纯文本 */
  @Trace content: string = '';
  /** 回复原始 HTML（富文本渲染用） */
  @Trace contentHtml: string = '';
  /** 回复者用户 id */
  @Trace userId: string = '';
  /** 回复者用户名 */
  @Trace userName: string = '';
  /** 乐观发送标记（false = “发射中”占位） */
  @Trace hasSend: boolean = true;
}

/** 楼中楼分页结果（index.php?m=comment&c=index&a=ajax） */
export class ReplyFloorPage {
  /** 所属评论 id（commentid） */
  readonly commentid: string = '';
  /** 会话总回复数 */
  readonly total: number = 0;
  /** 本页回复（按站点返回顺序） */
  readonly replies: Reply[] = [];

  constructor(commentid: string, total: number, replies: Reply[]) {
    this.commentid = commentid;
    this.total = total;
    this.replies = replies;
  }

  /** ajax JSON → ReplyFloorPage（data 为 Map<String, Reply>，宽松解析失败项跳过） */
  static fromJson(obj: Record<string, Object>): ReplyFloorPage {
    const commentid: string = JsonCoerce.asString(obj['commentid']);
    const total: number = JsonCoerce.asNumber(obj['total']);
    const dataObj: Record<string, Object> | undefined = JsonCoerce.asRecord(obj['data']);
    const replies: Reply[] = [];
    if (dataObj !== undefined) {
      const keys: string[] = Object.keys(dataObj);
      for (let i = 0; i < keys.length; i++) {
        const item: Record<string, Object> | undefined = JsonCoerce.asRecord(dataObj[keys[i]]);
        if (item !== undefined) {
          replies.push(ReplyFloorPage.parseReply(keys[i], item));
        }
      }
    }
    return new ReplyFloorPage(commentid, total, replies);
  }

  private static parseReply(id: string, obj: Record<string, Object>): Reply {
    const r: Reply = new Reply();
    r.id = id.length > 0 ? id : JsonCoerce.asString(obj['id']);
    r.avatar = JsonCoerce.asString(obj['avatar']);
    r.nickname = JsonCoerce.asString(obj['nickname']);
    r.time = JsonCoerce.asString(obj['creat_at']);
    r.content = JsonCoerce.asString(obj['content']);
    r.contentHtml = r.content;
    r.userId = JsonCoerce.asString(obj['userid']);
    r.userName = JsonCoerce.asString(obj['username']);
    return r;
  }
}

/** 评论列表分页结果（HTML 抓取 + maxPage） */
export class CommentPage {
  /** 本页评论（按站点顺序，1 楼在前） */
  readonly comments: Comment[];
  /** 最大页码（div.pages 解析，缺省 1） */
  readonly maxPage: number;

  constructor(comments: Comment[], maxPage: number) {
    this.comments = comments;
    this.maxPage = maxPage;
  }
}

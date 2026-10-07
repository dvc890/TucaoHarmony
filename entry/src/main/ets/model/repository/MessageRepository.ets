/**
 * 私信数据仓库
 * 协议对齐安卓版 MessageListViewModel / MessageDetailViewModel / RawApiService：
 * - 收件箱：GET RawApi.MESSAGE_INBOX → table.inbox 行解析（末行分页控件 dropLast）
 * - 会话明细：GET RawApi.MESSAGE_READ（messageid）→ td.tableright 第 4 子元素，3 个 div 一组
 * - 回复：POST RawApi.MESSAGE_REPLY（info[content] / info[replyid] / info[send_to_id] /
 *   info[subject]="" / dosubmit=提交）→ 含「成功」判定
 * send_to_id 沿用安卓版取当前用户名（原版行为，非对方 id），保持后端兼容。
 */
import { Document, Element } from 'domhandler';
import { RawApi } from '../../common/Constants';
import { MessageBubbleType, MessageDetailItem, MessageSummary } from '../entity/MessageEntities';
import { HtmlParseUtil } from '../../service/api/HtmlParseUtil';
import { TucaoApiClient } from '../../service/api/TucaoApiClient';

export class MessageRepository {
  private static instance: MessageRepository | undefined;

  static shared(): MessageRepository {
    if (MessageRepository.instance === undefined) {
      MessageRepository.instance = new MessageRepository();
    }
    return MessageRepository.instance;
  }

  private readonly client: TucaoApiClient = TucaoApiClient.getInstance();

  /** 收件箱会话列表 */
  async fetchInbox(): Promise<MessageSummary[]> {
    const html: string = await this.client.getRawText(RawApi.MESSAGE_INBOX);
    return MessageRepository.parseInbox(HtmlParseUtil.parse(html));
  }

  /**
   * 会话明细（对齐安卓版 parseMessageDetail）
   * @param messageId 会话 id
   * @param peerAvatar 对方头像（左侧气泡展示）
   * @param selfAvatar 自己头像（右侧气泡展示）
   */
  async fetchDetail(messageId: string, peerAvatar: string, selfAvatar: string): Promise<MessageDetailItem[]> {
    const html: string = await this.client.getRawText(RawApi.MESSAGE_READ, { 'messageid': messageId });
    return MessageRepository.parseDetail(HtmlParseUtil.parse(html), peerAvatar, selfAvatar);
  }

  /** 回复私信（info[send_to_id] 沿用安卓版传当前用户名） */
  async reply(messageId: string, content: string, sendToName: string): Promise<void> {
    const fields: Record<string, string> = {
      'info[content]': content,
      'info[replyid]': messageId,
      'info[send_to_id]': sendToName,
      'info[subject]': '',
      'dosubmit': '提交'
    };
    const responseText: string = await this.client.postFormText(RawApi.MESSAGE_REPLY, fields, true);
    if (!MessageRepository.bodyTextOf(responseText).includes('成功')) {
      throw new Error(MessageRepository.bodyTextOf(responseText));
    }
  }

  /** table.inbox → 会话列表（对齐安卓版 parseMessageList） */
  static parseInbox(doc: Document): MessageSummary[] {
    const result: MessageSummary[] = [];
    const inboxTable: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'table', 'inbox');
    if (inboxTable === undefined) {
      return result;
    }
    const tableBody: Element = MessageRepository.unwrapTbody(inboxTable);
    const rows: Element[] = HtmlParseUtil.childElements(tableBody);
    // 末行为分页控件，dropLast(1)
    const count: number = rows.length > 0 ? rows.length - 1 : 0;
    for (let i = 0; i < count; i++) {
      const summary: MessageSummary | undefined = MessageRepository.parseInboxRow(rows[i]);
      if (summary !== undefined) {
        result.push(summary);
      }
    }
    return result;
  }

  /** 单行会话解析 */
  private static parseInboxRow(row: Element): MessageSummary | undefined {
    const cells: Element[] = HtmlParseUtil.childElements(row);
    if (cells.length < 2) {
      return undefined;
    }
    const summary: MessageSummary = new MessageSummary();
    // 头像：首单元格内首个 img
    const avatarImg: Element | undefined = HtmlParseUtil.findOneByTag(cells[0], 'img');
    if (avatarImg !== undefined) {
      summary.avatar = avatarImg.attribs['src'] ?? '';
    }
    // 内容单元格：child(0)=链接区，child(1)=隐藏 input（value=会话 id）
    const contentCells: Element[] = HtmlParseUtil.childElements(cells[1]);
    if (contentCells.length < 2) {
      return undefined;
    }
    const inputEl: Element = contentCells[1];
    summary.id = inputEl.name === 'input' ? (inputEl.attribs['value'] ?? '') : '';
    const linkArea: Element = contentCells[0];
    // 用户名：em.red
    const redEm: Element | undefined = MessageRepository.findDescendantByClass(linkArea, 'em', 'red');
    if (redEm !== undefined) {
      summary.username = HtmlParseUtil.text(redEm).trim();
    }
    // 时间：em.time，去「对话于 」前缀
    const timeEm: Element | undefined = MessageRepository.findDescendantByClass(linkArea, 'em', 'time');
    if (timeEm !== undefined) {
      summary.time = HtmlParseUtil.text(timeEm).replace(/^对话于\s*/, '').trim();
    }
    // 预览：div.show
    const showDiv: Element | undefined = MessageRepository.findDescendantByClass(linkArea, 'div', 'show');
    if (showDiv !== undefined) {
      summary.message = HtmlParseUtil.text(showDiv).trim();
    }
    // 未读：em.bgblue 存在 = 未读
    const bgblueEm: Element | undefined = MessageRepository.findDescendantByClass(linkArea, 'em', 'bgblue');
    summary.read = bgblueEm === undefined;
    return summary;
  }

  /**
   * 会话明细解析（对齐安卓版 parseMessageDetail）
   * 结构：td.tableright > child(3) 的子元素按 3 个一组（div1=头像槽、div2=消息体、div3=间隔）
   */
  static parseDetail(doc: Document, peerAvatar: string, selfAvatar: string): MessageDetailItem[] {
    const result: MessageDetailItem[] = [];
    const tableRight: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'td', 'tableright');
    if (tableRight === undefined) {
      return result;
    }
    const cells: Element[] = HtmlParseUtil.childElements(tableRight);
    if (cells.length < 4) {
      return result;
    }
    const divs: Element[] = HtmlParseUtil.childElements(cells[3]);
    const groupCount: number = Math.floor(divs.length / 3);
    for (let index = 0; index < groupCount; index++) {
      const headDiv: Element = divs[3 * index];
      const messageDiv: Element = divs[3 * index + 1];
      const item: MessageDetailItem = new MessageDetailItem();
      // 方向：div1 class 含 userpicr = 右侧（自己）
      const className: string = HtmlParseUtil.attr(headDiv, 'class');
      const isRight: boolean = className.includes('userpicr');
      item.type = isRight ? MessageBubbleType.RIGHT : MessageBubbleType.LEFT;
      // 消息体：div2 直接文本（不含 div.time 子元素文本）
      item.message = MessageRepository.ownText(messageDiv).trim();
      // 时间：div2 内 div.time 文本
      const timeDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(messageDiv, 'div', 'time');
      if (timeDiv !== undefined) {
        item.time = HtmlParseUtil.text(timeDiv).trim();
      }
      // 头像：左侧用对方头像，右侧用自己头像
      item.avatar = isRight ? selfAvatar : peerAvatar;
      result.push(item);
    }
    return result;
  }

  /** 元素直接文本（对齐 Jsoup ownText：仅拼接直接文本节点，不含子元素文本） */
  private static ownText(el: Element): string {
    let result: string = '';
    const children: Object[] = el.children as Object[];
    for (let i = 0; i < children.length; i++) {
      const child: Record<string, Object> = children[i] as Record<string, Object>;
      if (child['type'] === 'text') {
        const data: Object | undefined = child['data'];
        if (typeof data === 'string') {
          result += data;
        }
      }
    }
    return result;
  }

  /** 后代元素按 tag+class 查找（一次遍历，复用 HtmlParseUtil.hasClass） */
  private static findDescendantByClass(root: Element, tagName: string, className: string): Element | undefined {
    return HtmlParseUtil.findOneByTagAndClass(root, tagName, className);
  }

  /** 表格首子元素为 tbody 时下钻（统一 Jsoup 隐式 tbody 口径） */
  private static unwrapTbody(table: Element): Element {
    const children: Element[] = HtmlParseUtil.childElements(table);
    if (children.length > 0 && children[0].name === 'tbody') {
      return children[0];
    }
    return table;
  }

  /** HTML 响应 → 全文文本（对齐安卓版 Jsoup.body().text() 判定口径） */
  private static bodyTextOf(htmlText: string): string {
    return HtmlParseUtil.text(HtmlParseUtil.parse(htmlText));
  }
}

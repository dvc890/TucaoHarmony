/**
 * HTML 解析工具（首个验证关口）
 * 基于 @ohos/htmlparser2 + domhandler + domutils 的类型安全封装：
 * - 解析入口：parse(html) → domhandler Document
 * - 查询/取值：findAllByTag / findAllByClass / findById / text / attr / childElements
 * - 类型收窄：asElement（按 node.type 字符串判定，禁用跨包 instanceof——
 *   @ohos/htmlparser2 内置的 domhandler 与顶层 domhandler 是两份物理拷贝，instanceof 会失效）
 * - 实体解码：parseDocument 默认 decodeEntities=true 已解码文本；
 *   decodeBasicEntities 提供安卓版 StringExtensions.decode 等价的兜底替换
 * 业务仓库层（VideoRepository/CommentRepository 等）只允许经由本封装访问 DOM，
 * 禁止直接把库节点类型以 ESObject 形式外溢。
 */
import { parseDocument } from '@ohos/htmlparser2';
import { ChildNode, Document, Element, AnyNode } from 'domhandler';
import { findAll, findOne, getElementById, getText } from 'domutils';

export class HtmlParseUtil {
  /** HTML 文本 → Document（容错解析，异常时返回空文档） */
  static parse(html: string): Document {
    try {
      return parseDocument(html);
    } catch (err) {
      return new Document([]);
    }
  }

  /** 节点 → 元素收窄（非元素返回 undefined） */
  static asElement(node: AnyNode | null | undefined): Element | undefined {
    if (node === null || node === undefined) {
      return undefined;
    }
    const nodeType: string = node.type;
    if (nodeType === 'tag' || nodeType === 'script' || nodeType === 'style') {
      return node as Element;
    }
    return undefined;
  }

  /** 后代元素：按标签名 */
  static findAllByTag(root: Document | Element, tagName: string): Element[] {
    return findAll((el: Element): boolean => el.name === tagName, root);
  }

  /** 后代元素：按标签名 + class */
  static findAllByTagAndClass(root: Document | Element, tagName: string, className: string): Element[] {
    return findAll((el: Element): boolean => el.name === tagName && HtmlParseUtil.hasClass(el, className), root);
  }

  /** 后代元素：按 class */
  static findAllByClass(root: Document | Element, className: string): Element[] {
    return findAll((el: Element): boolean => HtmlParseUtil.hasClass(el, className), root);
  }

  /** 第一个后代元素：按标签名 */
  static findOneByTag(root: Document | Element, tagName: string): Element | undefined {
    const found: Element | null = findOne((el: Element): boolean => el.name === tagName, root);
    return found ?? undefined;
  }

  /** 第一个后代元素：按标签名 + class */
  static findOneByTagAndClass(root: Document | Element, tagName: string, className: string): Element | undefined {
    const found: Element | null =
      findOne((el: Element): boolean => el.name === tagName && HtmlParseUtil.hasClass(el, className), root);
    return found ?? undefined;
  }

  /** 后代元素：按 id */
  static findById(root: Document | Element, id: string): Element | undefined {
    const found: Element | null = getElementById(id, root);
    return found ?? undefined;
  }

  /** 元素全文本（后代文本拼接，已解码实体）
   * 陷阱：domutils.getText 对 Document(root) 一律返回空串（root 非标签/非文本节点），
   * 整篇文档文本必须显式拼接子节点——否则全文判定（注册查重"1"、登录/发帖"成功"）恒失败 */
  static text(el: Element | Document): string {
    if (el.type === 'root') {
      const children: ChildNode[] = el.children;
      const parts: string[] = [];
      for (let i = 0; i < children.length; i++) {
        parts.push(getText(children[i]));
      }
      return parts.join('');
    }
    return getText(el);
  }

  /** 元素直接文本子节点拼接（不深入子元素——个人页 a.name 用户名与 <b>/<span> 徽标混排时取裸文本） */
  static directText(el: Element): string {
    const children: ChildNode[] = el.children;
    const parts: string[] = [];
    for (let i = 0; i < children.length; i++) {
      const child: ChildNode = children[i];
      if (child.type === 'text') {
        parts.push(getText(child));
      }
    }
    return parts.join('');
  }

  /** 元素属性读取（缺省返回空串） */
  static attr(el: Element, name: string): string {
    const value: string | undefined = el.attribs[name];
    return value ?? '';
  }

  /** class 名包含判定 */
  static hasClass(el: Element, className: string): boolean {
    const cls: string = HtmlParseUtil.attr(el, 'class');
    if (cls.length === 0) {
      return false;
    }
    const parts: string[] = cls.split(/\s+/);
    for (let i = 0; i < parts.length; i++) {
      if (parts[i] === className) {
        return true;
      }
    }
    return false;
  }

  /** 直接子元素（过滤文本/注释节点） */
  static childElements(el: Element | Document): Element[] {
    const result: Element[] = [];
    const children: ChildNode[] = el.children;
    for (let i = 0; i < children.length; i++) {
      const child: Element | undefined = HtmlParseUtil.asElement(children[i]);
      if (child !== undefined) {
        result.push(child);
      }
    }
    return result;
  }

  /** 基础 HTML 实体解码（对齐安卓 StringExtensions.decode 的四个替换） */
  static decodeBasicEntities(text: string): string {
    return text
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&gt;/g, '>')
      .replace(/&lt;/g, '<');
  }
}

/**
 * 会话服务（账号体系）
 * 协议对齐安卓版 Login/Register/ForgotPassword/Personal 各 ViewModel，禁止改动后端约定：
 * - 登录：GET RawApi.LOGIN 初始化会话 → GET RawApi.CHECKCODE 取验证码字节 →
 *   POST {username, password, code, cookietime, dosubmit} → 响应含「成功」判定 →
 *   GET RawApi.PERSONAL 抓取用户摘要
 * - 注册：账号/昵称/邮箱三项查重（响应 "1" 为可用）→ POST 注册表单 → 含「成功」判定
 * - 忘记密码：POST {email, code, dosubmit=重设} → 含「成功」判定
 * - 个人摘要解析（2026-09 站点改版对齐）：a.name 裸文本昵称 / 页头 a.n 头像 / a.message 未读数
 * - 头像上传：GET RawApi.MANAGE_AVATAR 提取 upurl → Base64 解码取 data 段 →
 *   八进制流 POST RawApi.UPLOAD_AVATAR → 重新抓取个人页刷新头像
 * - 登录态写入 SessionState（@ObservedV2 全局联动）+ EventBus.LOGIN_CHANGED 广播
 * - 修改资料/修改密码：POST account_manage_info / account_manage_password（改密成功后清空会话，对齐安卓版）
 */
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { rcp } from '@kit.RemoteCommunicationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Host, RawApi } from '../../common/Constants';
import { EventBus } from '../../common/EventBus';
import { GlobalState, SessionState } from '../../common/GlobalState';
import { PreferenceStore } from '../../data/PreferenceStore';
import { User } from '../../model/entity/BaseEntities';
import { HtmlParseUtil } from '../api/HtmlParseUtil';
import { TucaoApiClient } from '../api/TucaoApiClient';
import { Document, Element } from 'domhandler';

/** 个人页用户摘要（fetchPersonal 产出） */
export class PersonalSummary {
  readonly name: string;
  readonly avatar: string;
  readonly level: number;
  readonly signature: string;
  readonly messageCount: number;

  constructor(name: string, avatar: string, level: number, signature: string, messageCount: number) {
    this.name = name;
    this.avatar = avatar;
    this.level = level;
    this.signature = signature;
    this.messageCount = messageCount;
  }
}

export class SessionService {
  private static instance: SessionService | undefined;

  static shared(): SessionService {
    if (SessionService.instance === undefined) {
      SessionService.instance = new SessionService();
    }
    return SessionService.instance;
  }

  private readonly client: TucaoApiClient = TucaoApiClient.getInstance();

  /** 当前用户（PreferenceStore 持久化单例） */
  currentUser(): User {
    return PreferenceStore.user();
  }

  /** 会话状态单例（侧边栏等全局联动） */
  sessionState(): SessionState {
    return GlobalState.sessionState();
  }

  /**
   * 启动预热（开屏页调用，对齐安卓 SplashActivity "Just to fetch cookie"）
   * GET USER_INFO 仅为提前建立 PHP 会话 cookie，成功后不解析内容，失败静默忽略
   */
  async prefetchCookie(): Promise<void> {
    try {
      await this.client.getRawText(RawApi.USER_INFO);
    } catch (err) {
      // 静默：预热失败不影响启动流程
    }
  }

  /** 启动时同步持久化用户 → SessionState（Index 骨架调用） */
  syncSessionState(): void {
    const user: User = this.currentUser();
    const state: SessionState = this.sessionState();
    state.isLoggedIn = user.isValid();
    state.userName = user.name;
    state.userAvatar = user.avatar;
    state.unreadMessageCount = user.message;
  }

  /** User 变更落盘 + SessionState 同步 + 登录态广播 */
  private commitUserChange(loggedIn: boolean): void {
    PreferenceStore.saveUser();
    this.syncSessionState();
    EventBus.postLoginChanged(loggedIn);
  }

  /**
   * 查看一条未读私信
   * 本地未读数 -1（安卓版不回减，此处按任务口径联动角标）→ 落盘 + SessionState + 未读广播
   */
  markOneMessageRead(): void {
    const user: User = this.currentUser();
    if (!user.isValid() || user.message <= 0) {
      return;
    }
    user.message = user.message - 1;
    PreferenceStore.saveUser();
    this.syncSessionState();
    EventBus.postUnreadChanged(user.message);
  }

  /** 初始化登录会话并拉取验证码图片（登录页进入时调用，对齐安卓版 initSession + checkCode） */
  async initLoginSession(): Promise<image.PixelMap> {
    // 先 GET 登录页建立 PHP 会话
    await this.client.getRawText(RawApi.LOGIN);
    return await this.refreshCaptcha();
  }

  /** 刷新验证码图片（点击验证码图刷新，对齐安卓版 checkCode） */
  async refreshCaptcha(): Promise<image.PixelMap> {
    const bytes: Uint8Array = await this.client.getBytes(RawApi.CHECKCODE, true);
    if (bytes.byteLength === 0) {
      throw new Error('验证码获取失败');
    }
    const source: image.ImageSource = image.createImageSource(bytes.buffer);
    try {
      return await source.createPixelMap();
    } finally {
      source.release();
    }
  }

  /**
   * 登录（对齐安卓版 LoginViewModel.onClickSignIn）
   * 帐号登录：站点已不支持邮箱登录（2026-09 实测 username=邮箱 返回失败），
   * 登录标识改为帐号名；邮箱客户端不可知，个人页邮箱行留空
   * @returns 成功后无返回；失败抛 Error（携带站点提示文本）
   */
  async login(account: string, password: string, code: string): Promise<void> {
    const fields: Record<string, string> = {
      'username': account,
      'password': password,
      'code': code,
      'cookietime': '31536000',
      'dosubmit': '登录'
    };
    const responseText: string = await this.client.postFormText(RawApi.LOGIN, fields, true);
    if (!SessionService.bodyTextOf(responseText).includes('成功')) {
      throw new Error(SessionService.bodyTextOf(responseText));
    }
    // 登录成功 → 抓取个人页解析用户摘要
    const summary: PersonalSummary = await this.fetchPersonal();
    const user: User = this.currentUser();
    user.name = summary.name;
    user.avatar = summary.avatar;
    user.level = summary.level;
    user.signature = summary.signature;
    user.message = summary.messageCount;
    this.commitUserChange(true);
  }

  /**
   * 注册（对齐安卓版 RegisterViewModel.onClickCreate）
   * 三项查重（账号/昵称/邮箱，响应 "1" 为可用）→ POST 注册表单
   */
  async register(account: string, nickname: string, email: string, password: string,
    renewPassword: string, code: string): Promise<void> {
    await this.ensureCheckOk(RawApi.CHECK_USERNAME, 'username', account, '帐号已存在');
    await this.ensureCheckOk(RawApi.CHECK_NICKNAME, 'nickname', nickname, '昵称已存在');
    await this.ensureCheckOk(RawApi.CHECK_EMAIL, 'email', email, '邮箱已存在');
    const fields: Record<string, string> = {
      'username': account,
      'nickname': nickname,
      'email': email,
      'password': password,
      'pwdconfirm': renewPassword,
      'code': code,
      'dosubmit': '注册'
    };
    const responseText: string = await this.client.postFormText(RawApi.REGISTER, fields, true);
    if (!SessionService.bodyTextOf(responseText).includes('成功')) {
      throw new Error(SessionService.bodyTextOf(responseText));
    }
    // 注册成功 → 本地写入摘要（对齐安卓版：不回抓个人页）
    const user: User = this.currentUser();
    user.email = email;
    user.name = nickname;
    user.avatar = '';
    user.level = 1;
    user.signature = '';
    user.message = 0;
    this.commitUserChange(true);
  }

  /**
   * 忘记密码（对齐安卓版 ForgotPasswordViewModel.onClickSubmit）
   * @returns 成功后无返回；失败抛 Error
   */
  async forgotPassword(email: string, code: string): Promise<void> {
    const fields: Record<string, string> = {
      'email': email,
      'code': code,
      'dosubmit': '重设'
    };
    const responseText: string = await this.client.postFormText(RawApi.FORGOT_PASSWORD, fields, true);
    if (!SessionService.bodyTextOf(responseText).includes('成功')) {
      throw new Error(SessionService.bodyTextOf(responseText));
    }
  }

  /**
   * 退出登录（对齐安卓版 PersonalViewModel.onClickLogout）
   * 本地会话立即清空（不等登出请求返回），登出请求失败仅忽略
   */
  async logout(): Promise<void> {
    this.currentUser().invalidate();
    this.commitUserChange(false);
    try {
      await this.client.getRawText(RawApi.LOGOUT);
    } catch (err) {
      // 登出请求失败不影响本地清理
    }
  }

  /**
   * 抓取个人页用户摘要（对齐安卓版 LoginViewModel.parsePersonal）
   * 解析失败抛 Error（通常是会话失效，站点返回登录页）
   */
  async fetchPersonal(): Promise<PersonalSummary> {
    const html: string = await this.client.getRawText(RawApi.PERSONAL);
    const summary: PersonalSummary | undefined = SessionService.parsePersonal(HtmlParseUtil.parse(html));
    if (summary === undefined) {
      // 失败取证：区分「会话失效返回登录页」与「站点再度改版」
      const titleStart: number = html.indexOf('<title>');
      let title: string = '无title';
      if (titleStart >= 0) {
        const titleEnd: number = html.indexOf('</title>', titleStart);
        const cut: number = titleEnd > 0 ? Math.min(titleEnd, titleStart + 87) : titleStart + 87;
        title = html.substring(titleStart + 7, cut);
      }
      hilog.error(0x0000, 'SessionService',
        `parsePersonal 失败 len=${html.length} name锚点=${html.includes('class="name"')} title=${title}`);
      throw new Error('会话已失效，请重新登录');
    }
    return summary;
  }

  /**
   * 修改资料（对齐安卓版 ChangeInformationViewModel.save）
   * 成功后更新本地昵称/签名并广播
   */
  async changeInfo(nickname: string, signature: string): Promise<void> {
    const fields: Record<string, string> = {
      'nickname': nickname,
      'info[qianming]': signature,
      'dosubmit': '提交'
    };
    const responseText: string = await this.client.postFormText(RawApi.CHANGE_INFO, fields, true);
    if (!SessionService.bodyTextOf(responseText).includes('成功')) {
      throw new Error(SessionService.bodyTextOf(responseText));
    }
    const user: User = this.currentUser();
    user.name = nickname;
    user.signature = signature;
    this.commitUserChange(true);
  }

  /**
   * 修改密码（对齐安卓版 ChangePasswordViewModel.save）
   * 成功后清空会话强制重新登录（对齐安卓版 user.invalidate()）
   */
  async changePassword(oldPassword: string, newPassword: string, renewPassword: string): Promise<void> {
    const fields: Record<string, string> = {
      'info[password]': oldPassword,
      'info[newpassword]': newPassword,
      'info[renewpassword]': renewPassword,
      'dosubmit': '提交'
    };
    const responseText: string = await this.client.postFormText(RawApi.CHANGE_PASSWORD, fields, true);
    if (!SessionService.bodyTextOf(responseText).includes('成功')) {
      throw new Error(SessionService.bodyTextOf(responseText));
    }
    this.currentUser().invalidate();
    this.commitUserChange(false);
  }

  /**
   * 上传头像（对齐安卓版 PersonalViewModel.uploadAvatar ）
   * 流程：manageAvatar 页提取 upurl → Base64 解码取 &data 段 → 八进制流上传 → 回抓个人页刷新
   * @param avatarPixels 已按 1:1 裁剪好的头像位图
   */
  async uploadAvatar(avatarPixels: image.PixelMap): Promise<void> {
    // 1. 提取 phpsso 上传凭证
    const manageHtml: string = await this.client.getRawText(RawApi.MANAGE_AVATAR);
    const dataParam: string | undefined = SessionService.extractAvatarDataParam(manageHtml);
    if (dataParam === undefined) {
      throw new Error('请重新登录');
    }
    // 2. 位图编码为 JPEG 字节流
    const packer: image.ImagePacker = image.createImagePacker();
    let packed: ArrayBuffer;
    try {
      packed = await packer.packToData(avatarPixels, { format: 'image/jpeg', quality: 90 });
    } finally {
      packer.release();
    }
    // 3. 八进制流上传（同安卓版 application/octet-stream）
    const uploadUrl: string =
      `${Host.BASE_RAW_API_URL}${RawApi.UPLOAD_AVATAR}&data=${encodeURIComponent(dataParam)}`;
    const headers: rcp.RequestHeaders = {
      'content-type': 'application/octet-stream'
    };
    const request: rcp.Request = new rcp.Request(uploadUrl, 'POST', headers, packed);
    const response: rcp.Response = await this.client.getSession().fetch(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw new Error(`头像上传失败（HTTP ${response.statusCode}）`);
    }
    // 4. 回抓个人页刷新本地头像
    const summary: PersonalSummary = await this.fetchPersonal();
    const user: User = this.currentUser();
    user.avatar = summary.avatar;
    this.commitUserChange(true);
  }

  /** 注册查重：响应文本为 "1" 视为可用，否则抛 Error */
  private async ensureCheckOk(path: string, queryKey: string, value: string, failMessage: string): Promise<void> {
    const params: Record<string, string> = {};
    params[queryKey] = value;
    const responseText: string = await this.client.getRawText(path, params);
    if (SessionService.bodyTextOf(responseText).trim() !== '1') {
      throw new Error(failMessage);
    }
  }

  /** HTML 响应 → 全文文本（对齐安卓版 Jsoup.body().text() 判定口径） */
  private static bodyTextOf(htmlText: string): string {
    return HtmlParseUtil.text(HtmlParseUtil.parse(htmlText));
  }

  /**
   * manageAvatar 页 → upurl Base64 → data 参数
   * 对齐安卓版正则 `'upurl':"(.+)&callback=return_avatar&"`；
   * 追加单引号包裹变体兜底，两类引号均未命中返回 undefined
   */
  private static extractAvatarDataParam(manageHtml: string): string | undefined {
    const doubleQuoted: RegExp = /'upurl':"(.+?)&callback=return_avatar&"/;
    const singleQuoted: RegExp = /'upurl':'(.+?)&callback=return_avatar&'/;
    let encoded: string | undefined = undefined;
    const matchDouble: RegExpExecArray | null = doubleQuoted.exec(manageHtml);
    if (matchDouble !== null) {
      encoded = matchDouble[1];
    } else {
      const matchSingle: RegExpExecArray | null = singleQuoted.exec(manageHtml);
      if (matchSingle !== null) {
        encoded = matchSingle[1];
      }
    }
    if (encoded === undefined) {
      return undefined;
    }
    // Base64 解码 → 取 &data 之后的内容（对齐安卓版 indexOf("&data") + 6）
    let decoded: string;
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const bytes: Uint8Array = helper.decodeSync(encoded);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      decoded = decoder.decodeToString(bytes);
    } catch (err) {
      return undefined;
    }
    const dataOffset: number = decoded.indexOf('&data');
    if (dataOffset < 0) {
      return undefined;
    }
    return decoded.substring(dataOffset + 6);
  }

  /**
   * 个人页 HTML → 用户摘要（结构不符返回 undefined）
   * 2026-09 站点改版对齐：旧锚点 a.lv/div.index/table.index_table 已随改版消失，
   * 新结构 div.mindex>div.uinfo：a.avatar>img 头像（src 空时回退 onerror 占位图）、
   * a.name 裸文本昵称（与 <b>居住/守护/积分</b>、<span>充值</span> 徽标混排）、
   * 侧栏 a.message>span 未读私信数；等级/签名新版页面已无，取默认值
   */
  private static parsePersonal(doc: Document): PersonalSummary | undefined {
    // 昵称锚点即登录态判定：会话失效时站点返回登录表单页，无 a.name
    const nameAnchor: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'a', 'name');
    if (nameAnchor === undefined) {
      return undefined;
    }
    const name: string = HtmlParseUtil.directText(nameAnchor).trim();
    if (name.length === 0) {
      return undefined;
    }
    // 头像：a.avatar > img；src 为空时回退 onerror 占位图（对齐浏览器 nophoto 行为）
    let avatar: string = '';
    const avatarAnchor: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'a', 'avatar');
    if (avatarAnchor !== undefined) {
      const avatarImg: Element | undefined = HtmlParseUtil.findOneByTag(avatarAnchor, 'img');
      if (avatarImg !== undefined) {
        avatar = HtmlParseUtil.attr(avatarImg, 'src').trim();
        if (avatar.length === 0) {
          const onError: string = HtmlParseUtil.attr(avatarImg, 'onerror');
          const placeholder: RegExpExecArray | null = /this\.src='([^']+)';?/.exec(onError);
          if (placeholder !== null && placeholder.length > 1) {
            avatar = placeholder[1];
          }
        }
      }
    }
    // 未读私信：a.message > span（无 span 视为 0）
    let messageCount: number = 0;
    const messageAnchor: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'a', 'message');
    if (messageAnchor !== undefined) {
      const messageSpan: Element | undefined = HtmlParseUtil.findOneByTag(messageAnchor, 'span');
      if (messageSpan !== undefined) {
        messageCount = SessionService.parseIntSafe(HtmlParseUtil.text(messageSpan).trim());
      }
    }
    return new PersonalSummary(name, SessionService.normalizeImageUrl(avatar), 1, '', messageCount);
  }

  /** 头像地址归一化：协议相对/根相对 → 绝对地址 */
  static normalizeImageUrl(url: string): string {
    const trimmed: string = url.trim();
    if (trimmed.length === 0) {
      return '';
    }
    if (trimmed.startsWith('//')) {
      return `https:${trimmed}`;
    }
    if (trimmed.startsWith('/')) {
      return `${Host.BASE_RAW_API_URL}${trimmed.substring(1)}`;
    }
    return trimmed;
  }

  /** 文本 → 整数（容错，失败返回 0） */
  private static parseIntSafe(text: string): number {
    const parsed: number = Number.parseInt(text);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
}

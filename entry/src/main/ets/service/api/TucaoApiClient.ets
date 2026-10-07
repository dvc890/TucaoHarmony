/**
 * 吐槽 API 客户端
 * 协议对齐安卓版 ApiConfig/RawApiService/JsonApiService，禁止改动后端约定：
 * - 单例 rcp.Session + rcp.CookieRepository（PHP 会话自动持久化）
 * - api_v2 JSON：自动注入 apikey=25tids8f1ew1821ed&type=json
 * - XML：playurl / 弹幕
 * - HTML 抓取：Cookie 合并（tucao_verify=ok 兜底 + 会话 Cookie）
 * - 表单 POST / 二进制 GET（验证码）/ clicli 桌面 UA
 * 仓库层（model/repository/*）负责把业务参数拼成具体 URL，本类保持通用。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { util, url } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiParams, Host, HttpConst } from '../../common/Constants';

/** API 错误（携带 HTTP 状态码） */
export class TucaoApiError extends Error {
  readonly statusCode: number;

  constructor(message: string, statusCode: number) {
    super(message);
    this.name = 'TucaoApiError';
    this.statusCode = statusCode;
  }
}

export class TucaoApiClient {
  private static instance: TucaoApiClient | undefined = undefined;

  private readonly session: rcp.Session;
  private readonly cookieRepository: rcp.CookieRepository;

  static getInstance(): TucaoApiClient {
    if (TucaoApiClient.instance === undefined) {
      TucaoApiClient.instance = new TucaoApiClient();
    }
    return TucaoApiClient.instance;
  }

  private constructor() {
    // 会话级 Cookie 仓库：登录 PHPSESSID 等自动落盘复用
    this.cookieRepository = rcp.CookieRepository.create('tucao_session');
    const config: rcp.SessionConfiguration = {
      baseAddress: Host.BASE_RAW_API_URL,
      cookieRepository: this.cookieRepository,
      // 连接/传输超时兜底：弱网或不可达时按预期落错误态（可重试），避免无限转圈
      requestConfiguration: {
        transfer: {
          timeout: {
            connectMs: 15000,
            transferMs: 60000
          }
        }
      }
    };
    this.session = rcp.createSession(config);
  }

  /** 暴露会话（下载器分段请求/头像上传等高级场景使用） */
  getSession(): rcp.Session {
    return this.session;
  }

  /** 暴露 Cookie 仓库（登录态探测/登出清理使用） */
  getCookieRepository(): rcp.CookieRepository {
    return this.cookieRepository;
  }

  /** api_v2 JSON GET（注入 apikey/type=json），返回解析后的根对象 */
  async getApiV2(file: string, params?: Record<string, string>): Promise<Record<string, Object>> {
    const query: Record<string, string> = {
      'apikey': ApiParams.API_KEY,
      'type': ApiParams.TYPE_JSON
    };
    TucaoApiClient.mergeParams(query, params);
    const fullUrl: string = `${Host.BASE_JSON_API_URL}${file}${TucaoApiClient.toQueryString(query, file)}`;
    const text: string = await this.getPlainText(fullUrl, undefined);
    const record: Record<string, Object> | undefined = TucaoApiClient.parseJsonObject(text);
    if (record === undefined) {
      throw new TucaoApiError('api_v2 响应不是合法 JSON 对象', -1);
    }
    return record;
  }

  /** XML GET（playurl / 弹幕拉取），返回原始文本 */
  async getXmlText(absoluteUrl: string, params?: Record<string, string>): Promise<string> {
    const query: Record<string, string> = {};
    TucaoApiClient.mergeParams(query, params);
    const fullUrl: string = `${absoluteUrl}${TucaoApiClient.toQueryString(query, absoluteUrl)}`;
    return await this.getPlainText(fullUrl, undefined);
  }

  /** HTML 抓取 GET（tucao_verify 兜底 + 会话 Cookie 合并） */
  async getRawText(path: string, params?: Record<string, string>): Promise<string> {
    const query: Record<string, string> = {};
    TucaoApiClient.mergeParams(query, params);
    const absolute: string = TucaoApiClient.toAbsoluteUrl(path);
    const fullUrl: string = `${absolute}${TucaoApiClient.toQueryString(query, absolute)}`;
    const cookie: string = await this.buildCookieHeader(fullUrl);
    const headers: rcp.RequestHeaders = {
      'cookie': cookie
    };
    return await this.getPlainText(fullUrl, headers);
  }

  /** 指定 UA 的 GET（clicli 解析用桌面 Chrome UA 等） */
  async getTextWithUA(absoluteUrl: string, ua: string): Promise<string> {
    const headers: rcp.RequestHeaders = {
      'user-agent': ua
    };
    return await this.getPlainText(absoluteUrl, headers);
  }

  /**
   * 解析播放直链（HEAD 探测）：站点 2026-09-19 起播放地址前置 301/302 跳转层，
   * AVPlayer 不跟随跳转导致 5400106，需先解析出最终直链；失败时回退原地址保持旧行为。
   */
  async resolveEffectiveUrl(target: string): Promise<string> {
    try {
      const request: rcp.Request = new rcp.Request(target, 'HEAD');
      const response: rcp.Response = await this.fetchWithLog(request);
      const href: string | undefined = response.effectiveUrl?.href;
      if (href !== undefined && href.length > 0 && response.statusCode >= 200 && response.statusCode < 400) {
        hilog.info(0x0000, 'TucaoApiClient', `[resolve] ${target} -> ${href}`);
        return href;
      }
      hilog.info(0x0000, 'TucaoApiClient', `[resolve] ${target} 保持原址（HTTP ${response.statusCode}）`);
      return target;
    } catch (err) {
      const detail: string = err instanceof Error ? `${(err as Error).name}: ${(err as Error).message}` : `${err}`;
      hilog.info(0x0000, 'TucaoApiClient', `[resolve] ${target} 解析失败，回退原址：${detail}`);
      return target;
    }
  }

  /** 表单 POST，返回响应文本（登录/发评论/发弹幕等） */
  async postFormText(path: string, fields: Record<string, string>, withVerifyCookie: boolean): Promise<string> {
    const absolute: string = TucaoApiClient.toAbsoluteUrl(path);
    const headers: rcp.RequestHeaders = {};
    if (withVerifyCookie) {
      const cookie: string = await this.buildCookieHeader(absolute);
      headers['cookie'] = cookie;
    }
    headers['content-type'] = 'application/x-www-form-urlencoded';
    const formFields: rcp.FormFields = {};
    TucaoApiClient.mergeFormFields(formFields, fields);
    const content: rcp.Form = new rcp.Form(formFields);
    const request: rcp.Request = new rcp.Request(absolute, 'POST', headers, content);
    const response: rcp.Response = await this.fetchWithLog(request);
    this.assertOk(response);
    return this.decodeBody(response);
  }

  /** 二进制 GET（验证码图片等），返回字节流 */
  async getBytes(path: string, withVerifyCookie: boolean): Promise<Uint8Array> {
    const absolute: string = TucaoApiClient.toAbsoluteUrl(path);
    const headers: rcp.RequestHeaders = {};
    if (withVerifyCookie) {
      const cookie: string = await this.buildCookieHeader(absolute);
      headers['cookie'] = cookie;
    }
    const request: rcp.Request = new rcp.Request(absolute, 'GET', headers);
    const response: rcp.Response = await this.fetchWithLog(request);
    this.assertOk(response);
    const body: ArrayBuffer | undefined = response.body;
    if (body === undefined) {
      return new Uint8Array(0);
    }
    return new Uint8Array(body);
  }

  /** 统一请求出口：附带耗时/状态/异常诊断日志（定位弱网与不可达问题） */
  private async fetchWithLog(request: rcp.Request): Promise<rcp.Response> {
    const requestUrl: string = request.url.toString();
    const start: number = Date.now();
    hilog.info(0x0000, 'TucaoApiClient', `[fetch] ${request.method} ${requestUrl} 开始`);
    try {
      const response: rcp.Response = await this.session.fetch(request);
      hilog.info(0x0000, 'TucaoApiClient',
        `[fetch] ${requestUrl} -> HTTP ${response.statusCode}，耗时 ${Date.now() - start}ms`);
      return response;
    } catch (err) {
      const detail: string = err instanceof Error ? `${(err as Error).name}: ${(err as Error).message}` : `${err}`;
      hilog.error(0x0000, 'TucaoApiClient',
        `[fetch] ${requestUrl} 失败，耗时 ${Date.now() - start}ms，异常 ${detail}`);
      throw err as Error;
    }
  }

  /** 通用 GET 文本 */
  private async getPlainText(fullUrl: string, headers?: rcp.RequestHeaders): Promise<string> {
    const request: rcp.Request = new rcp.Request(fullUrl, 'GET', headers);
    const response: rcp.Response = await this.fetchWithLog(request);
    this.assertOk(response);
    return this.decodeBody(response);
  }

  /** 构造抓取请求的 Cookie 头：tucao_verify=ok 兜底 + 会话 Cookie 合并 */
  private async buildCookieHeader(fullUrl: string): Promise<string> {
    let cookie: string = HttpConst.TUCAO_VERIFY_COOKIE;
    try {
      const urlObj: url.URL = url.URL.parseURL(fullUrl);
      const sessionCookies: rcp.ResponseCookie[] = await this.cookieRepository.getCookiesByUrl(urlObj);
      for (let i = 0; i < sessionCookies.length; i++) {
        const c: rcp.ResponseCookie = sessionCookies[i];
        const value: string = c.value ?? '';
        cookie = `${cookie}; ${c.name}=${value}`;
      }
    } catch (err) {
      // 会话 Cookie 查询失败时仅用兜底值
    }
    return cookie;
  }

  /** 非 2xx 抛 TucaoApiError */
  private assertOk(response: rcp.Response): void {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw new TucaoApiError(`HTTP ${response.statusCode}`, response.statusCode);
    }
  }

  /** 响应体 → UTF-8 文本 */
  private decodeBody(response: rcp.Response): string {
    const body: ArrayBuffer | undefined = response.body;
    if (body === undefined) {
      const fallback: string | null = response.toString();
      return fallback ?? '';
    }
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(body));
  }

  /** 相对路径 → 绝对地址（绝对地址原样返回） */
  private static toAbsoluteUrl(path: string): string {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    return `${Host.BASE_RAW_API_URL}${path}`;
  }

  /** params 合入 target（params 覆盖同名键） */
  private static mergeParams(target: Record<string, string>, params?: Record<string, string>): void {
    if (params === undefined) {
      return;
    }
    const keys: string[] = Object.keys(params);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      target[key] = params[key];
    }
  }

  /** 表单字段合并（Record<string,string> → rcp.FormFields） */
  private static mergeFormFields(target: rcp.FormFields, fields: Record<string, string>): void {
    const keys: string[] = Object.keys(fields);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      target[key] = fields[key];
    }
  }

  /** 参数 → 查询串（已含 ? 时以 & 续接；空参数返回空串） */
  private static toQueryString(params: Record<string, string>, baseUrl?: string): string {
    const keys: string[] = Object.keys(params);
    if (keys.length === 0) {
      return '';
    }
    const parts: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`);
    }
    if (baseUrl !== undefined && baseUrl.includes('?')) {
      return `&${parts.join('&')}`;
    }
    return `?${parts.join('&')}`;
  }

  /** 文本 → JSON 根对象（仅对象根；数组根返回 undefined） */
  private static parseJsonObject(text: string): Record<string, Object> | undefined {
    try {
      const obj: Object | null = JSON.parse(text);
      if (obj !== null && typeof obj === 'object' && !Array.isArray(obj)) {
        return obj as Record<string, Object>;
      }
      return undefined;
    } catch (err) {
      return undefined;
    }
  }
}

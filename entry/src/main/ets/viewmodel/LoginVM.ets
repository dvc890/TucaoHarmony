/**
 * 登录页 VM
 * 对齐安卓版 LoginViewModel：
 * - 进入页面：初始化会话（GET 登录页）+ 拉取验证码图片
 * - 点击验证码图：刷新
 * - 登录：帐号/密码/验证码非空校验 → SessionService.login → 成功返回上一页
 * - 错误提示：站点返回文本（含「成功」之外的整页文本）toast 展示
 * - 帐号登录：站点已不支持邮箱登录（2026-09 实测），登录标识改为帐号名
 */
import { image } from '@kit.ImageKit';
import { Router } from '../common/Router';
import { SessionService } from '../service/session/SessionService';

@ObservedV2
export class LoginVM {
  @Trace account: string = '';
  @Trace password: string = '';
  @Trace code: string = '';
  /** 验证码位图（null = 加载中） */
  @Trace captchaPixels: image.PixelMap | null = null;
  /** 会话初始化中（验证码图加载前禁止提交） */
  @Trace initializing: boolean = true;
  /** 登录请求中 */
  @Trace loggingIn: boolean = false;
  /** 错误提示（非空时展示） */
  @Trace error: string = '';

  private readonly session: SessionService = SessionService.shared();

  /** 进入页面：初始化会话 + 验证码 */
  async init(): Promise<void> {
    await this.refreshCaptcha(true);
  }

  /** 刷新验证码（needInit=true 时先 GET 登录页建立会话） */
  async refreshCaptcha(needInit: boolean = false): Promise<void> {
    try {
      this.captchaPixels = needInit
        ? await this.session.initLoginSession()
        : await this.session.refreshCaptcha();
      this.initializing = false;
      this.error = '';
    } catch (err) {
      this.initializing = false;
      this.error = '验证码获取失败，请点击重试';
    }
  }

  /** 提交登录（返回是否成功；成功由页面 toast + 返回） */
  async submit(): Promise<boolean> {
    if (this.loggingIn) {
      return false;
    }
    if (this.account.trim().length === 0) {
      this.error = '帐号不能为空';
      return false;
    }
    if (this.password.length === 0) {
      this.error = '密码不能为空';
      return false;
    }
    if (this.code.trim().length === 0) {
      this.error = '验证码不能为空';
      return false;
    }
    this.loggingIn = true;
    this.error = '';
    try {
      await this.session.login(this.account.trim(), this.password, this.code.trim());
      return true;
    } catch (err) {
      const message: string = err instanceof Error && err.message.length > 0 ? err.message : '登录失败';
      this.error = message;
      // 登录失败后验证码已失效，自动刷新
      await this.refreshCaptcha();
      return false;
    } finally {
      this.loggingIn = false;
    }
  }

  /** 跳转注册 */
  goRegister(): void {
    Router.goRegister();
  }

  /** 跳转忘记密码 */
  goForgotPassword(): void {
    Router.goForgotPassword();
  }
}

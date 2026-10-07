/**
 * 注册页 VM
 * 对齐安卓版 RegisterViewModel：
 * - 客户端校验：帐号/昵称 2-20 位、邮箱格式、两次密码一致且 6-20 位、验证码非空
 * - 服务端三项查重（帐号/昵称/邮箱）由 SessionService.register 顺序执行，
 *   命中时抛对应文案（帐号已存在/昵称已存在/邮箱已存在）
 * - 成功后本地写入用户摘要并广播登录态
 */
import { image } from '@kit.ImageKit';
import { SessionService } from '../service/session/SessionService';

@ObservedV2
export class RegisterVM {
  @Trace account: string = '';
  @Trace nickname: string = '';
  @Trace email: string = '';
  @Trace newPassword: string = '';
  @Trace renewPassword: string = '';
  @Trace code: string = '';
  /** 字段级错误文案 */
  @Trace accountError: string = '';
  @Trace nicknameError: string = '';
  @Trace emailError: string = '';
  @Trace newPasswordError: string = '';
  @Trace renewPasswordError: string = '';
  @Trace codeError: string = '';
  /** 服务端错误（查重/注册失败，非空时顶部展示） */
  @Trace serverError: string = '';
  /** 验证码位图 */
  @Trace captchaPixels: image.PixelMap | null = null;
  /** 提交中 */
  @Trace submitting: boolean = false;

  private static readonly EMAIL_PATTERN: RegExp = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;

  private readonly session: SessionService = SessionService.shared();

  /** 进入页面：拉取验证码 */
  async init(): Promise<void> {
    await this.refreshCaptcha();
  }

  /** 刷新验证码 */
  async refreshCaptcha(): Promise<void> {
    try {
      this.captchaPixels = await this.session.refreshCaptcha();
    } catch (err) {
      this.serverError = '验证码获取失败，请点击重试';
    }
  }

  /** 客户端字段校验（对齐安卓版 onClickCreate 前置校验） */
  private validateFields(): boolean {
    this.accountError = '';
    this.nicknameError = '';
    this.emailError = '';
    this.newPasswordError = '';
    this.renewPasswordError = '';
    this.codeError = '';
    this.serverError = '';
    let hasError: boolean = false;
    if (this.account.length < 2 || this.account.length > 20) {
      this.accountError = '帐号应在2-20位之间';
      hasError = true;
    }
    if (this.nickname.length < 2 || this.nickname.length > 20) {
      this.nicknameError = '昵称应在2-20位之间';
      hasError = true;
    }
    if (!RegisterVM.EMAIL_PATTERN.test(this.email)) {
      this.emailError = '这不是一个合法的邮箱';
      hasError = true;
    }
    if (this.newPassword !== this.renewPassword) {
      this.newPasswordError = '两次输入的密码不一致';
      this.renewPasswordError = '两次输入的密码不一致';
      hasError = true;
    }
    if (this.newPassword.length < 6 || this.newPassword.length > 20) {
      this.newPasswordError = '密码应在6-20位之间';
      hasError = true;
    }
    if (this.renewPassword.length < 6 || this.renewPassword.length > 20) {
      this.renewPasswordError = '密码应在6-20位之间';
      hasError = true;
    }
    if (this.code.length === 0) {
      this.codeError = '验证码不能为空';
      hasError = true;
    }
    return !hasError;
  }

  /** 提交注册（返回是否成功；成功由页面 toast + 返回） */
  async submit(): Promise<boolean> {
    if (this.submitting) {
      return false;
    }
    if (!this.validateFields()) {
      return false;
    }
    this.submitting = true;
    try {
      await this.session.register(this.account, this.nickname, this.email, this.newPassword,
        this.renewPassword, this.code);
      return true;
    } catch (err) {
      const message: string = err instanceof Error && err.message.length > 0 ? err.message : '注册失败';
      // 查重失败文案定向到对应字段
      if (message === '帐号已存在') {
        this.accountError = message;
      } else if (message === '昵称已存在') {
        this.nicknameError = message;
      } else if (message === '邮箱已存在') {
        this.emailError = message;
      } else {
        this.serverError = message;
      }
      await this.refreshCaptcha();
      return false;
    } finally {
      this.submitting = false;
    }
  }
}

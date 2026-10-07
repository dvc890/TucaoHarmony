/**
 * 忘记密码页 VM
 * 对齐安卓版 ForgotPasswordViewModel：
 * - 邮箱 + 验证码非空校验
 * - POST {email, code, dosubmit=重设} → 含「成功」判定
 * - 成功提示「请前往邮箱查看新密码」
 */
import { image } from '@kit.ImageKit';
import { SessionService } from '../service/session/SessionService';

@ObservedV2
export class ForgotPasswordVM {
  @Trace email: string = '';
  @Trace code: string = '';
  /** 验证码位图 */
  @Trace captchaPixels: image.PixelMap | null = null;
  /** 提交中 */
  @Trace submitting: boolean = false;
  /** 错误提示 */
  @Trace error: string = '';

  private readonly session: SessionService = SessionService.shared();

  /** 进入页面：拉取验证码 */
  async init(): Promise<void> {
    await this.refreshCaptcha();
  }

  /** 刷新验证码 */
  async refreshCaptcha(): Promise<void> {
    try {
      this.captchaPixels = await this.session.refreshCaptcha();
      this.error = '';
    } catch (err) {
      this.error = '验证码获取失败，请点击重试';
    }
  }

  /** 提交重设密码（返回是否成功；成功由页面 toast + 返回） */
  async submit(): Promise<boolean> {
    if (this.submitting) {
      return false;
    }
    if (this.email.trim().length === 0) {
      this.error = '邮箱不能为空';
      return false;
    }
    if (this.code.trim().length === 0) {
      this.error = '验证码不能为空';
      return false;
    }
    this.submitting = true;
    this.error = '';
    try {
      await this.session.forgotPassword(this.email.trim(), this.code.trim());
      return true;
    } catch (err) {
      const message: string = err instanceof Error && err.message.length > 0 ? err.message : '重设密码失败';
      this.error = message;
      await this.refreshCaptcha();
      return false;
    } finally {
      this.submitting = false;
    }
  }
}

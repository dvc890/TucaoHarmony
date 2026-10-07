/**
 * 登录页（大屏 UX 适配）
 * 邮箱 + 密码 + 验证码（点击图片刷新）/ 错误提示 / 注册与忘记密码入口
 * ：LG/XL 表单限宽 600 居中（SM/MD 全宽，零退化）
 * 路由：router_map.json → LoginBuilder（注册）
 */
import { LoginVM } from '../viewmodel/LoginVM';
import { Router } from '../common/Router';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function LoginBuilder(name: string, param: Object) {
  Login({ routeParam: param })
}

@ComponentV2
struct Login {
  /** 路由参数（登录页无参数） */
  @Param routeParam: Object = new Object();
  @Local vm: LoginVM = new LoginVM();

  aboutToAppear(): void {
    this.vm.init();
  }

  /** 提交登录：成功 toast + 返回 */
  private async doSubmit(): Promise<void> {
    const ok: boolean = await this.vm.submit();
    if (ok) {
      this.getUIContext().getPromptAction().showToast({ message: '登录成功' });
      Router.back();
    } else if (this.vm.error.length > 0) {
      // 站点错误页文本可能很长，toast 截断展示
      this.getUIContext().getPromptAction().showToast({ message: this.vm.error.substring(0, 60) });
    }
  }

  build() {
    NavDestination() {
      // LG/XL 表单限宽 600 居中（SM/MD 全宽，零退化）
      CenteredShell({ maxWidth: 600 }) {
        Column({ space: $r('app.float.space_lg') }) {
          // 帐号（站点已不支持邮箱登录，2026-09 实测）
          Column({ space: $r('app.float.space_xs') }) {
            Text('帐号')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_secondary'))
            TextInput({ placeholder: '请输入帐号', text: this.vm.account })
              .fontSize($r('app.float.font_size_body'))
              .height(44)
              .backgroundColor($r('app.color.card_background'))
              .borderRadius($r('app.float.radius_card'))
              .onChange((value: string): void => {
                this.vm.account = value;
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 密码
          Column({ space: $r('app.float.space_xs') }) {
            Text('密码')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_secondary'))
            TextInput({ placeholder: '请输入密码', text: this.vm.password })
              .type(InputType.Password)
              .fontSize($r('app.float.font_size_body'))
              .height(44)
              .backgroundColor($r('app.color.card_background'))
              .borderRadius($r('app.float.radius_card'))
              .onChange((value: string): void => {
                this.vm.password = value;
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 验证码
          Column({ space: $r('app.float.space_xs') }) {
            Text('验证码')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_secondary'))
            Row({ space: $r('app.float.space_md') }) {
              TextInput({ placeholder: '请输入验证码', text: this.vm.code })
                .fontSize($r('app.float.font_size_body'))
                .height(44)
                .layoutWeight(1)
                .backgroundColor($r('app.color.card_background'))
                .borderRadius($r('app.float.radius_card'))
                .onChange((value: string): void => {
                  this.vm.code = value;
                })
              // 验证码图片（点击刷新）
              Row() {
                if (this.vm.captchaPixels !== null) {
                  Image(this.vm.captchaPixels)
                    .height('100%')
                    .objectFit(ImageFit.Contain)
                } else {
                  LoadingProgress()
                    .width(24)
                    .height(24)
                    .color($r('app.color.text_tertiary'))
                }
              }
              .height(44)
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
              .backgroundColor($r('app.color.card_background'))
              .borderRadius($r('app.float.radius_card'))
              .onClick((): void => {
                this.vm.refreshCaptcha();
              })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 错误提示
          if (this.vm.error.length > 0) {
            Text(this.vm.error)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.error'))
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          // 登录按钮
          Button(this.vm.loggingIn ? '登录中…' : '登录')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_on_brand'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius($r('app.float.radius_button'))
            .width('100%')
            .height(44)
            .enabled(!this.vm.loggingIn && !this.vm.initializing)
            .onClick((): void => {
              this.doSubmit();
            })

          // 注册 / 忘记密码
          Row({ space: $r('app.float.space_xl') }) {
            Text('注册账号')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.brand'))
              .onClick((): void => {
                this.vm.goRegister();
              })
            Text('忘记密码？')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .onClick((): void => {
                this.vm.goForgotPassword();
              })
          }
          .padding({ top: $r('app.float.space_sm') })
        }
        .width('100%')
        .padding({
          left: $r('app.float.space_lg'),
          right: $r('app.float.space_lg'),
          top: $r('app.float.space_xl')
        })
        .alignItems(HorizontalAlign.Center)
      }
    }
    .title('登录')
    .backgroundColor($r('app.color.page_background'))
  }
}

/**
 * 忘记密码页（大屏 UX 适配）
 * 邮箱 + 验证码 → 重设密码邮件；成功提示「请前往邮箱查看新密码」
 * ：LG/XL 表单限宽 600 居中（SM/MD 全宽，零退化）
 * 路由：router_map.json → ForgotPasswordBuilder（注册）
 */
import { ForgotPasswordVM } from '../viewmodel/ForgotPasswordVM';
import { Router } from '../common/Router';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function ForgotPasswordBuilder(name: string, param: Object) {
  ForgotPassword({ routeParam: param })
}

@ComponentV2
struct ForgotPassword {
  /** 路由参数（忘记密码页无参数） */
  @Param routeParam: Object = new Object();
  @Local vm: ForgotPasswordVM = new ForgotPasswordVM();

  aboutToAppear(): void {
    this.vm.init();
  }

  /** 提交重设：成功 toast + 返回 */
  private async doSubmit(): Promise<void> {
    const ok: boolean = await this.vm.submit();
    if (ok) {
      this.getUIContext().getPromptAction().showToast({ message: '请前往邮箱查看新密码' });
      Router.back();
    } else if (this.vm.error.length > 0) {
      this.getUIContext().getPromptAction().showToast({ message: this.vm.error.substring(0, 60) });
    }
  }

  build() {
    NavDestination() {
      // LG/XL 表单限宽 600 居中（SM/MD 全宽，零退化）
      CenteredShell({ maxWidth: 600 }) {
        Column({ space: $r('app.float.space_lg') }) {
          Text('输入注册邮箱，系统将发送新密码至邮箱')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')

          // 邮箱
          Column({ space: $r('app.float.space_xs') }) {
            Text('邮箱')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_secondary'))
            TextInput({ placeholder: '请输入注册邮箱地址', text: this.vm.email })
              .fontSize($r('app.float.font_size_body'))
              .height(44)
              .width('100%')
              .backgroundColor($r('app.color.card_background'))
              .borderRadius($r('app.float.radius_card'))
              .onChange((value: string): void => {
                this.vm.email = value;
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

          // 提交按钮
          Button(this.vm.submitting ? '提交中…' : '重设密码')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_on_brand'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius($r('app.float.radius_button'))
            .width('100%')
            .height(44)
            .enabled(!this.vm.submitting)
            .onClick((): void => {
              this.doSubmit();
            })
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
    .title('忘记密码')
    .backgroundColor($r('app.color.page_background'))
  }
}

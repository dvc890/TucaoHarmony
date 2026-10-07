/**
 * 注册页（大屏 UX 适配）
 * 帐号/昵称/邮箱/密码/确认密码/验证码 + 字段级错误提示 + 服务端查重文案定向
 * ：LG/XL 表单限宽 600 居中（SM/MD 全宽，零退化）
 * 路由：router_map.json → RegisterBuilder（注册）
 */
import { RegisterVM } from '../viewmodel/RegisterVM';
import { Router } from '../common/Router';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function RegisterBuilder(name: string, param: Object) {
  Register({ routeParam: param })
}

/** 带标签与错误提示的输入行（注册表单复用） */
@ComponentV2
struct RegisterField {
  @Param label: string = '';
  @Param placeholder: string = '';
  @Param text: string = '';
  @Param errorText: string = '';
  @Param secret: boolean = false;
  @Event onTextChanged: (value: string) => void = (_value: string): void => {};

  build() {
    Column({ space: $r('app.float.space_xs') }) {
      Text(this.label)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_secondary'))
      if (this.secret) {
        TextInput({ placeholder: this.placeholder, text: this.text })
          .type(InputType.Password)
          .fontSize($r('app.float.font_size_body'))
          .height(44)
          .width('100%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.radius_card'))
          .onChange((value: string): void => {
            this.onTextChanged(value);
          })
      } else {
        TextInput({ placeholder: this.placeholder, text: this.text })
          .fontSize($r('app.float.font_size_body'))
          .height(44)
          .width('100%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.radius_card'))
          .onChange((value: string): void => {
            this.onTextChanged(value);
          })
      }
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.error'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
struct Register {
  /** 路由参数（注册页无参数） */
  @Param routeParam: Object = new Object();
  @Local vm: RegisterVM = new RegisterVM();

  aboutToAppear(): void {
    this.vm.init();
  }

  /** 提交注册：成功 toast + 返回 */
  private async doSubmit(): Promise<void> {
    const ok: boolean = await this.vm.submit();
    if (ok) {
      this.getUIContext().getPromptAction().showToast({ message: '注册成功' });
      Router.back();
    } else if (this.vm.serverError.length > 0) {
      this.getUIContext().getPromptAction().showToast({ message: this.vm.serverError.substring(0, 60) });
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        // LG/XL 表单限宽 600 居中（SM/MD 全宽，零退化）
        CenteredShell({ maxWidth: 600 }) {
          Column({ space: $r('app.float.space_lg') }) {
            // 服务端错误提示（查重/注册接口失败）
            if (this.vm.serverError.length > 0) {
              Text(this.vm.serverError)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.error'))
                .width('100%')
            }

            RegisterField({
              label: '帐号',
              placeholder: '2-20 位字符',
              text: this.vm.account,
              errorText: this.vm.accountError,
              onTextChanged: (value: string): void => {
                this.vm.account = value;
              }
            })
            RegisterField({
              label: '昵称',
              placeholder: '2-20 位字符',
              text: this.vm.nickname,
              errorText: this.vm.nicknameError,
              onTextChanged: (value: string): void => {
                this.vm.nickname = value;
              }
            })
            RegisterField({
              label: '邮箱',
              placeholder: '请输入邮箱地址',
              text: this.vm.email,
              errorText: this.vm.emailError,
              onTextChanged: (value: string): void => {
                this.vm.email = value;
              }
            })
            RegisterField({
              label: '密码',
              placeholder: '6-20 位字符',
              text: this.vm.newPassword,
              errorText: this.vm.newPasswordError,
              secret: true,
              onTextChanged: (value: string): void => {
                this.vm.newPassword = value;
              }
            })
            RegisterField({
              label: '确认密码',
              placeholder: '再次输入密码',
              text: this.vm.renewPassword,
              errorText: this.vm.renewPasswordError,
              secret: true,
              onTextChanged: (value: string): void => {
                this.vm.renewPassword = value;
              }
            })

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
              if (this.vm.codeError.length > 0) {
                Text(this.vm.codeError)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.error'))
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 注册按钮
            Button(this.vm.submitting ? '注册中…' : '注册')
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
            top: $r('app.float.space_lg'),
            bottom: $r('app.float.space_xl')
          })
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .title('注册')
    .backgroundColor($r('app.color.page_background'))
  }
}

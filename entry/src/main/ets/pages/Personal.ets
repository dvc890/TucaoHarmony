/**
 * 个人中心页（大屏 UX 适配）
 * 头像（相册/拍照 → 自绘 1:1 裁剪 → 上传）、昵称/签名编辑、修改密码、短消息入口、退出登录
 * ：LG/XL 表单限宽 600 居中（SM/MD 全宽，零退化；仅登录态内容分支）
 * 路由：router_map.json → PersonalBuilder（注册）
 */
import { PersonalVM } from '../viewmodel/PersonalVM';
import { Router } from '../common/Router';
import { EmptyView } from '../components/EmptyView';
import { NetworkImage } from '../components/NetworkImage';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function PersonalBuilder(name: string, param: Object) {
  Personal({ routeParam: param })
}

/** 信息行（图标 + 文案 + 值 + 可选徽标） */
@ComponentV2
struct ProfileRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param badge: number = 0;
  @Param clickable: boolean = false;
  @Param danger: boolean = false;
  @Event onClickRow: () => void = (): void => {};

  build() {
    Row({ space: $r('app.float.space_md') }) {
      Text(this.label)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_secondary'))
        .width(64)
      Blank()
      if (this.badge > 0) {
        Text(this.badge > 99 ? '99+' : this.badge.toString())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(8)
          .constraintSize({ minWidth: 16 })
          .height(16)
          .padding({ left: 4, right: 4 })
          .textAlign(TextAlign.Center)
      }
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize($r('app.float.font_size_body'))
          .fontColor(this.danger ? $r('app.color.error') : $r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '60%' })
      }
      if (this.clickable) {
        Text('›')
          .fontSize(20)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: $r('app.float.space_md'), right: $r('app.float.space_md') })
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.card_background'))
    .onClick((): void => {
      this.onClickRow();
    })
  }
}

@ComponentV2
struct Personal {
  /** 路由参数（个人中心无参数） */
  @Param routeParam: Object = new Object();
  @Local vm: PersonalVM = new PersonalVM();

  /** 编辑态 */
  @Local editingProfile: boolean = false;
  @Local editingPassword: boolean = false;
  @Local draftNickname: string = '';
  @Local draftSignature: string = '';
  @Local oldPassword: string = '';
  @Local newPassword: string = '';
  @Local renewPassword: string = '';
  @Local profileError: string = '';
  @Local passwordError: string = '';
  /** 裁剪窗拖动手势起点（图内坐标） */
  @Local dragStartX: number = 0;
  @Local dragStartY: number = 0;

  aboutToAppear(): void {
    this.vm.init();
  }

  /** 更换头像菜单（拍照 / 从相册选择） */
  private showAvatarMenu(): void {
    this.getUIContext().showAlertDialog({
      title: '更换头像',
      message: '选择头像来源',
      primaryButton: {
        value: '从相册选择',
        action: (): void => {
          this.vm.pickFromGallery();
        }
      },
      secondaryButton: {
        value: '拍照',
        fontColor: $r('app.color.brand'),
        action: (): void => {
          this.vm.takePhoto();
        }
      },
      cancel: (): void => {
      }
    });
  }

  /** 应用裁剪并上传 */
  private async doApplyCrop(): Promise<void> {
    const ok: boolean = await this.vm.applyCrop();
    this.getUIContext().getPromptAction().showToast({ message: ok ? '头像更新成功' : '头像上传失败，请重试' });
  }

  /** 进入资料编辑 */
  private startEditProfile(): void {
    this.draftNickname = this.vm.nickname;
    this.draftSignature = this.vm.signature;
    this.profileError = '';
    this.editingProfile = true;
  }

  /** 保存资料 */
  private async doSaveProfile(): Promise<void> {
    if (this.draftNickname.trim().length < 2 || this.draftNickname.trim().length > 20) {
      this.profileError = '昵称应在2-20位之间';
      return;
    }
    const ok: boolean = await this.vm.saveProfile(this.draftNickname, this.draftSignature);
    if (ok) {
      this.editingProfile = false;
      this.getUIContext().getPromptAction().showToast({ message: '资料已更新' });
    } else {
      this.profileError = '保存失败，请稍后重试';
    }
  }

  /** 进入密码编辑 */
  private startEditPassword(): void {
    this.oldPassword = '';
    this.newPassword = '';
    this.renewPassword = '';
    this.passwordError = '';
    this.editingPassword = true;
  }

  /** 保存新密码（成功后会话失效，返回上一页重新登录） */
  private async doSavePassword(): Promise<void> {
    if (this.oldPassword.length === 0) {
      this.passwordError = '请输入原密码';
      return;
    }
    if (this.newPassword.length < 6 || this.newPassword.length > 20) {
      this.passwordError = '新密码应在6-20位之间';
      return;
    }
    if (this.newPassword !== this.renewPassword) {
      this.passwordError = '两次输入的密码不一致';
      return;
    }
    const ok: boolean = await this.vm.changePassword(this.oldPassword, this.newPassword, this.renewPassword);
    if (ok) {
      this.editingPassword = false;
      this.getUIContext().getPromptAction().showToast({ message: '密码修改成功，请重新登录' });
      Router.back();
    } else {
      this.passwordError = '修改失败，请检查原密码';
    }
  }

  /** 退出登录确认（对齐安卓版「真的要退出吗QAQ」） */
  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: '退出登录',
      message: '真的要退出吗QAQ',
      primaryButton: {
        value: '假的',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '真的',
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.doLogout();
        }
      },
      cancel: (): void => {
      }
    });
  }

  private async doLogout(): Promise<void> {
    await this.vm.logout();
    this.getUIContext().getPromptAction().showToast({ message: '已退出登录' });
    Router.back();
  }

  /** 裁剪浮层（全屏模态） */
  @Builder
  cropCover() {
    Stack({ alignContent: Alignment.Center }) {
      // 全屏遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.mask'))
        .onClick((): void => {
          this.vm.cancelCrop();
        })

      // 裁剪舞台：图片 + 四周暗化 + 可拖动正方形窗
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.vm.cropPixels !== null) {
          Image(this.vm.cropPixels)
            .width(this.vm.cropDispW)
            .height(this.vm.cropDispH)
            .objectFit(ImageFit.Fill)
        }
        // 上/下/左/右 四块暗化区域
        Column()
          .width(this.vm.cropDispW)
          .height(Math.max(this.vm.cropWinY, 0))
          .position({ x: 0, y: 0 })
          .backgroundColor($r('app.color.mask'))
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width(this.vm.cropDispW)
          .height(Math.max(this.vm.cropDispH - this.vm.cropWinY - this.vm.cropSide, 0))
          .position({ x: 0, y: this.vm.cropWinY + this.vm.cropSide })
          .backgroundColor($r('app.color.mask'))
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width(Math.max(this.vm.cropWinX, 0))
          .height(this.vm.cropSide)
          .position({ x: 0, y: this.vm.cropWinY })
          .backgroundColor($r('app.color.mask'))
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width(Math.max(this.vm.cropDispW - this.vm.cropWinX - this.vm.cropSide, 0))
          .height(this.vm.cropSide)
          .position({ x: this.vm.cropWinX + this.vm.cropSide, y: this.vm.cropWinY })
          .backgroundColor($r('app.color.mask'))
          .hitTestBehavior(HitTestMode.None)
        // 裁剪窗（白框，可拖动）
        Column()
          .width(this.vm.cropSide)
          .height(this.vm.cropSide)
          .position({ x: this.vm.cropWinX, y: this.vm.cropWinY })
          .border({ width: 1, color: Color.White })
          .gesture(
            PanGesture({ fingers: 1 })
              .onActionStart((event: GestureEvent): void => {
                this.dragStartX = this.vm.cropWinX;
                this.dragStartY = this.vm.cropWinY;
              })
              .onActionUpdate((event: GestureEvent): void => {
                this.vm.moveWindowTo(this.dragStartX + event.offsetX, this.dragStartY + event.offsetY);
              })
          )
      }
      .width(this.vm.cropDispW)
      .height(this.vm.cropDispH)

      // 底部操作条
      Row({ space: $r('app.float.space_lg') }) {
        Button('取消')
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.radius_button'))
          .height(40)
          .padding({ left: $r('app.float.space_xl'), right: $r('app.float.space_xl') })
          .enabled(!this.vm.uploading)
          .onClick((): void => {
            this.vm.cancelCrop();
          })
        Button(this.vm.uploading ? '上传中…' : '使用照片')
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius($r('app.float.radius_button'))
          .height(40)
          .padding({ left: $r('app.float.space_xl'), right: $r('app.float.space_xl') })
          .enabled(!this.vm.uploading)
          .onClick((): void => {
            this.doApplyCrop();
          })
      }
      .position({ x: 0, y: '78%' })
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（中性底） =====
        Row({ space: $r('app.float.space_sm') }) {
          Text('‹')
            .fontSize(28)
            .fontColor($r('app.color.text_primary'))
            .padding({
              left: $r('app.float.space_sm'),
              right: $r('app.float.space_sm')
            })
            .onClick((): void => {
              Router.back();
            })
          Text('个人中心')
            .fontSize($r('app.float.font_size_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_md'),
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })
        // 全局沉浸：topbar 底色仅扩展绘制延伸到状态栏下（不改布局，内容绝对位置不变）
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

        if (!this.vm.loggedIn) {
        // 未登录：引导登录
        Column({ space: $r('app.float.space_lg') }) {
          EmptyView({ message: '请先登录' })
          Button('登录')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_on_brand'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius($r('app.float.radius_button'))
            .height(40)
            .padding({ left: $r('app.float.space_xl'), right: $r('app.float.space_xl') })
            .onClick((): void => {
              Router.goLogin();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          // LG/XL 表单限宽 600 居中（SM/MD 全宽，零退化）
          CenteredShell({ maxWidth: 600 }) {
            Column({ space: $r('app.float.space_md') }) {
              // 头像卡（点击更换）
              Row({ space: $r('app.float.space_lg') }) {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  NetworkImage({
                    url: this.vm.avatar,
                    imageWidth: 72,
                    imageHeight: 72,
                    radius: 36
                  })
                  Text('📷')
                    .fontSize(12)
                    .width(22)
                    .height(22)
                    .textAlign(TextAlign.Center)
                    .backgroundColor($r('app.color.brand'))
                    .fontColor($r('app.color.text_on_brand'))
                    .borderRadius(11)
                }
                Column({ space: $r('app.float.space_xs') }) {
                  Text(this.vm.nickname)
                    .fontSize($r('app.float.font_size_title_lg'))
                    .fontColor($r('app.color.text_primary'))
                    .fontWeight(FontWeight.Medium)
                  Text(`Lv${this.vm.level}`)
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.brand'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding($r('app.float.space_md'))
              .borderRadius($r('app.float.radius_card'))
              .backgroundColor($r('app.color.card_background'))
              .onClick((): void => {
                this.showAvatarMenu();
              })

              // 资料编辑区（点「昵称/签名」行展开）
              if (this.editingProfile) {
                Column({ space: $r('app.float.space_md') }) {
                  Text('编辑资料')
                    .fontSize($r('app.float.font_size_body'))
                    .fontColor($r('app.color.text_primary'))
                    .fontWeight(FontWeight.Medium)
                  TextInput({ text: this.draftNickname, placeholder: '昵称（2-20位）' })
                    .fontSize($r('app.float.font_size_body'))
                    .height(44)
                    .backgroundColor($r('app.color.page_background'))
                    .borderRadius($r('app.float.radius_card'))
                    .onChange((value: string): void => {
                      this.draftNickname = value;
                    })
                  TextInput({ text: this.draftSignature, placeholder: '签名' })
                    .fontSize($r('app.float.font_size_body'))
                    .height(44)
                    .backgroundColor($r('app.color.page_background'))
                    .borderRadius($r('app.float.radius_card'))
                    .onChange((value: string): void => {
                      this.draftSignature = value;
                    })
                  if (this.profileError.length > 0) {
                    Text(this.profileError)
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor($r('app.color.error'))
                  }
                  Row({ space: $r('app.float.space_md') }) {
                    Button('取消')
                      .fontSize($r('app.float.font_size_body'))
                      .fontColor($r('app.color.text_primary'))
                      .backgroundColor($r('app.color.page_background'))
                      .borderRadius($r('app.float.radius_button'))
                      .layoutWeight(1)
                      .height(40)
                      .onClick((): void => {
                        this.editingProfile = false;
                      })
                    Button(this.vm.busy ? '保存中…' : '保存')
                      .fontSize($r('app.float.font_size_body'))
                      .fontColor($r('app.color.text_on_brand'))
                      .backgroundColor($r('app.color.brand'))
                      .borderRadius($r('app.float.radius_button'))
                      .layoutWeight(1)
                      .height(40)
                      .enabled(!this.vm.busy)
                      .onClick((): void => {
                        this.doSaveProfile();
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                .padding($r('app.float.space_md'))
                .borderRadius($r('app.float.radius_card'))
                .backgroundColor($r('app.color.card_background'))
                .alignItems(HorizontalAlign.Start)
              }

              ProfileRow({
                label: '昵称',
                value: this.vm.nickname,
                clickable: true,
                onClickRow: (): void => {
                  this.startEditProfile();
                }
              })
              ProfileRow({
                label: '签名',
                value: this.vm.signature,
                clickable: true,
                onClickRow: (): void => {
                  this.startEditProfile();
                }
              })
              ProfileRow({ label: '邮箱', value: this.vm.email })
              ProfileRow({ label: '等级', value: `Lv${this.vm.level}` })
              ProfileRow({
                label: '短消息',
                value: '',
                badge: this.vm.unreadMessage,
                clickable: true,
                onClickRow: (): void => {
                  Router.goMessageList();
                }
              })

              // 密码编辑区（点「修改密码」行展开）
              if (this.editingPassword) {
                Column({ space: $r('app.float.space_md') }) {
                  Text('修改密码')
                    .fontSize($r('app.float.font_size_body'))
                    .fontColor($r('app.color.text_primary'))
                    .fontWeight(FontWeight.Medium)
                  TextInput({ text: this.oldPassword, placeholder: '原密码' })
                    .type(InputType.Password)
                    .fontSize($r('app.float.font_size_body'))
                    .height(44)
                    .backgroundColor($r('app.color.page_background'))
                    .borderRadius($r('app.float.radius_card'))
                    .onChange((value: string): void => {
                      this.oldPassword = value;
                    })
                  TextInput({ text: this.newPassword, placeholder: '新密码（6-20位）' })
                    .type(InputType.Password)
                    .fontSize($r('app.float.font_size_body'))
                    .height(44)
                    .backgroundColor($r('app.color.page_background'))
                    .borderRadius($r('app.float.radius_card'))
                    .onChange((value: string): void => {
                      this.newPassword = value;
                    })
                  TextInput({ text: this.renewPassword, placeholder: '确认新密码' })
                    .type(InputType.Password)
                    .fontSize($r('app.float.font_size_body'))
                    .height(44)
                    .backgroundColor($r('app.color.page_background'))
                    .borderRadius($r('app.float.radius_card'))
                    .onChange((value: string): void => {
                      this.renewPassword = value;
                    })
                  if (this.passwordError.length > 0) {
                    Text(this.passwordError)
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor($r('app.color.error'))
                  }
                  Row({ space: $r('app.float.space_md') }) {
                    Button('取消')
                      .fontSize($r('app.float.font_size_body'))
                      .fontColor($r('app.color.text_primary'))
                      .backgroundColor($r('app.color.page_background'))
                      .borderRadius($r('app.float.radius_button'))
                      .layoutWeight(1)
                      .height(40)
                      .onClick((): void => {
                        this.editingPassword = false;
                      })
                    Button(this.vm.busy ? '提交中…' : '确认修改')
                      .fontSize($r('app.float.font_size_body'))
                      .fontColor($r('app.color.text_on_brand'))
                      .backgroundColor($r('app.color.brand'))
                      .borderRadius($r('app.float.radius_button'))
                      .layoutWeight(1)
                      .height(40)
                      .enabled(!this.vm.busy)
                      .onClick((): void => {
                        this.doSavePassword();
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                .padding($r('app.float.space_md'))
                .borderRadius($r('app.float.radius_card'))
                .backgroundColor($r('app.color.card_background'))
                .alignItems(HorizontalAlign.Start)
              }

              ProfileRow({
                label: '修改密码',
                value: '',
                clickable: true,
                onClickRow: (): void => {
                  this.startEditPassword();
                }
              })

              // 退出登录
              Button('退出登录')
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.error'))
                .backgroundColor($r('app.color.card_background'))
                .borderRadius($r('app.float.radius_button'))
                .width('100%')
                .height(44)
                .onClick((): void => {
                  this.confirmLogout();
                })
            }
            .width('100%')
            .padding({
              left: $r('app.float.space_md'),
              right: $r('app.float.space_md'),
              top: $r('app.float.space_md'),
              bottom: $r('app.float.space_xl')
            })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      }
      .width('100%')
      .height('100%')
    }
    .backgroundColor($r('app.color.page_background'))
    .hideTitleBar(true)
    .bindContentCover(this.vm.cropActive, this.cropCover(), {
      modalTransition: ModalTransition.NONE,
      backgroundColor: Color.Transparent,
      onDisappear: (): void => {
        this.vm.cancelCrop();
      }
    })
  }
}

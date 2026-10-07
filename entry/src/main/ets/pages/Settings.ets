/**
 * 设置页（我的页「设置」行升级为真设置页）
 * - 分组卡片式布局：
 *   通用（缓存设置 → DownloadSettings / 检查更新 → 复用我的页 doCheckUpdate 真实逻辑）
 *   关于（→ About 页）、账号（退出登录，仅登录态显示）
 * - 退出登录确认弹窗对齐个人中心「真的要退出吗QAQ」，登出走 SessionService
 * - 底部版本号小字（bundleManager 动态读取，对齐 About 页）
 * - 平板两列布局：SM 手机保持单列全宽分组卡片（零变化）；
 *   MD+ 通用|关于 两列分组卡片并排，账号组（登录态）独占通栏，
 *   内容区限宽 840 居中（CenteredShell，SM/MD 全宽零退化）
 * - 行样式对齐我的页 MineEntry / 个人中心 ProfileRow 惯例（48 高 + 右箭头）
 * - 路由：router_map.json → SettingsBuilder（无参数；Router.goSettings()）
 */
import { bundleManager } from '@kit.AbilityKit';
import { Router } from '../common/Router';
import { GlobalState, SessionState, WindowSizeInfo } from '../common/GlobalState';
import { CenteredShell } from '../components/CenteredShell';
import { SessionService } from '../service/session/SessionService';
import { doCheckUpdate } from '../views/mine/MineCenterView';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function SettingsBuilder(name: string, param: Object) {
  Settings()
}

/** 设置行（分组卡片内行样式，对齐 MineEntry/ProfileRow） */
@ComponentV2
struct SettingsRow {
  @Param label: string = '';
  /** 右侧值文案（空 = 不显示） */
  @Param value: string = '';
  /** 是否显示右箭头（可进入/可操作行） */
  @Param showChevron: boolean = true;
  /** 危险操作（退出登录，红色文案） */
  @Param danger: boolean = false;
  @Event onTap: () => void = (): void => {};

  build() {
    Row({ space: $r('app.float.space_md') }) {
      Text(this.label)
        .fontSize($r('app.float.font_size_body'))
        .fontColor(this.danger ? $r('app.color.error') : $r('app.color.text_primary'))
        .layoutWeight(1)
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.showChevron) {
        Text('›')
          .fontSize(20)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(48)
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md')
    })
    .onClick(() => {
      this.onTap();
    })
  }
}

@ComponentV2
struct Settings {
  /** 登录态（@ObservedV2 单例，退出登录后「账号」分组自动隐藏） */
  session: SessionState = GlobalState.sessionState();
  /** 窗口断点（SM 单列 / MD+ 两列） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();
  /** 版本名（读取失败回退「1.0.0」，对齐 About 页） */
  @Local versionName: string = '1.0.0';
  @Local versionCode: number = 1;

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        this.versionName = info.versionName;
      }
      this.versionCode = info.versionCode;
    } catch (err) {
      // 版本读取失败按默认值展示
    }
  }

  /** 退出登录确认（对齐个人中心「真的要退出吗QAQ」） */
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
    await SessionService.shared().logout();
    this.getUIContext().getPromptAction().showToast({ message: '已退出登录' });
  }

  // ==================== 分组 Builder（SM 单列 / MD+ 两列共用） ====================

  /** 通用组：缓存设置 + 检查更新 */
  @Builder
  private generalGroup() {
    Column({ space: $r('app.float.space_md') }) {
      Text('通用')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: $r('app.float.space_md') })

      Column() {
        SettingsRow({
          label: '缓存设置',
          onTap: (): void => Router.goDownloadSettings()
        })
        Divider()
          .color($r('app.color.divider'))
          .width('100%')
        SettingsRow({
          label: '检查更新',
          onTap: (): void => doCheckUpdate(this.getUIContext(), false)
        })
      }
      .width('100%')
      .borderRadius($r('app.float.radius_card'))
      .backgroundColor($r('app.color.card_background'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 关于组：关于入口 */
  @Builder
  private aboutGroup() {
    Column({ space: $r('app.float.space_md') }) {
      Text('关于')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: $r('app.float.space_md') })

      Column() {
        SettingsRow({
          label: '关于',
          onTap: (): void => Router.goAbout()
        })
      }
      .width('100%')
      .borderRadius($r('app.float.radius_card'))
      .backgroundColor($r('app.color.card_background'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 账号组：退出登录（是否显示由调用方按登录态控制） */
  @Builder
  private accountGroup() {
    Column({ space: $r('app.float.space_md') }) {
      Text('账号')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: $r('app.float.space_md') })

      Column() {
        SettingsRow({
          label: '退出登录',
          showChevron: false,
          danger: true,
          onTap: (): void => {
            this.confirmLogout();
          }
        })
      }
      .width('100%')
      .borderRadius($r('app.float.radius_card'))
      .backgroundColor($r('app.color.card_background'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 版本号脚注（贴内容区底部居中） */
  @Builder
  private versionFooter() {
    Column({ space: 2 }) {
      Text(`版本 ${this.versionName}(${this.versionCode})`)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
      Text('© 2026 dvc890')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: $r('app.float.space_md') })
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（中性底，对齐 DownloadSettings） =====
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
          Text('设置')
            .fontSize($r('app.float.font_size_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_sm'),
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })
        // 全局沉浸：topbar 底色仅扩展绘制延伸到状态栏下（不改布局，内容绝对位置不变）
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

        Scroll() {
          // LG/XL 内容限宽 840 居中（SM/MD 全宽，零退化）
          CenteredShell({ maxWidth: 840 }) {
            if (this.windowSize.isCompact()) {
              // ===== SM：单列全宽分组卡片（保持现状） =====
              Column({ space: $r('app.float.space_md') }) {
                this.generalGroup()
                this.aboutGroup()
                if (this.session.isLoggedIn) {
                  this.accountGroup()
                }
                this.versionFooter()
              }
              .width('100%')
              .padding({
                left: $r('app.float.space_md'),
                right: $r('app.float.space_md'),
                top: $r('app.float.space_sm'),
                bottom: $r('app.float.space_lg')
              })
              .alignItems(HorizontalAlign.Start)
            } else {
              // ===== MD+：两列分组卡片（通用 | 关于），提高平板屏幕利用率 =====
              Column({ space: $r('app.float.space_md') }) {
                Row({ space: $r('app.float.space_md') }) {
                  Column() {
                    this.generalGroup()
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Column() {
                    this.aboutGroup()
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)

                // 账号组独占通栏（仅登录态，保持视觉平衡）
                if (this.session.isLoggedIn) {
                  Column() {
                    this.accountGroup()
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }

                this.versionFooter()
              }
              .width('100%')
              .padding({
                left: $r('app.float.space_md'),
                right: $r('app.float.space_md'),
                top: $r('app.float.space_sm'),
                bottom: $r('app.float.space_lg')
              })
              .alignItems(HorizontalAlign.Start)
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_background'))
  }
}

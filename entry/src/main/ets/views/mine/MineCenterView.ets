/**
 * 我的中心视图（多设备"侧边栏功能"收口）
 * - 单份功能清单，三形态复用：大屏 SideNavView / 中屏 Mine 页 / 手机"我的"Tab
 * - 功能对齐安卓 Drawer 菜单（menu_drawer.xml，7 项）：
 *   我的收藏 / 历史记录 / 离线缓存 / 短消息(未读角标) / 检查更新 / 设置 / 关于
 * - 用户信息区：未登录点击登录 / 已登录展示头像昵称、点击进个人中心
 * - 检查更新：UpdateService 拉应用更新服务器（对齐安卓 checkUpdate）
 * - 设置：跳转设置页（Settings 分组卡片：缓存设置/检查更新/关于/退出登录）
 * - 监听登录态/未读数事件同步 SessionState
 * - 大屏布局分支（D 组我的页专项）：
 *   SM（isCompact）现状零变化（平铺行结构不动）；
 *   MD+ 撤窄壳改限宽 840 居中：头像卡通栏 + 功能菜单两列网格
 *   （GridRow/GridCol，分组卡片风格对齐 Settings），功能与导航行为零变化
 */
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { GlobalState, SessionState, WindowSizeInfo } from '../../common/GlobalState';
import { EventBus } from '../../common/EventBus';
import { Router } from '../../common/Router';
import { NetworkImage } from '../../components/NetworkImage';
import { CenteredShell } from '../../components/CenteredShell';
import { SessionService } from '../../service/session/SessionService';
import { UpdateService, VersionInfo } from '../../service/update/UpdateService';

/** 侧边功能入口行（角标 >99 显示 99+） */
@ComponentV2
struct MineEntry {
  @Param label: string = '';
  /** 角标数（>0 显示） */
  @Param badgeCount: number = 0;
  @Param onTap: () => void = (): void => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (this.badgeCount > 0) {
        Text(this.badgeCount > 99 ? '99+' : `${this.badgeCount}`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius($r('app.float.radius_button'))
          .padding({
            left: $r('app.float.space_sm'),
            right: $r('app.float.space_sm'),
            top: $r('app.float.space_xs'),
            bottom: $r('app.float.space_xs')
          })
          .constraintSize({ minWidth: 20 })
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height(48)
    .borderRadius($r('app.float.radius_card'))
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 检查更新（对齐安卓 MainActivity.checkUpdate(false)：有新版弹窗，无更新 toast）
 *  导出供大屏侧栏悬浮"我的"菜单复用 */
export function doCheckUpdate(uiContext: UIContext, quiet: boolean): void {
  let currentVersionCode: number = 1;
  try {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    currentVersionCode = info.versionCode;
  } catch (err) {
    // 版本读取失败按 1 处理（服务端 versionCode 必大于 1）
  }
  UpdateService.shared().checkForUpdate(currentVersionCode).then((version: VersionInfo | null) => {
    if (version === null) {
      if (!quiet) {
        uiContext.getPromptAction().showToast({ message: '你已经是最新版了' });
      }
      return;
    }
    const sizeText: string = UpdateService.formatSize(version.apkSize);
    uiContext.showAlertDialog({
      title: `发现新版本 v${version.versionName}${sizeText.length > 0 ? ` (${sizeText})` : ''}`,
      message: version.description,
      primaryButton: {
        value: '去更新',
        action: (): void => {
          if (version.apkUrl.length > 0) {
            Router.goBrowser(version.apkUrl);
          }
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      autoCancel: true
    });
  }).catch((err: BusinessError) => {
    if (!quiet) {
      uiContext.getPromptAction().showToast({ message: '服务器异常，请手动检查更新' });
    }
  });
}

@ComponentV2
export struct MineCenterView {
  session: SessionState = GlobalState.sessionState();
  /** 窗口尺寸断点（SM/MD+ 布局分支门控） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();
  /** EventBus 订阅退订函数 */
  private offLoginChanged: (() => void) | null = null;
  private offUnreadChanged: (() => void) | null = null;

  aboutToAppear(): void {
    // 登录态/未读数变化时同步 SessionState（头像、昵称、角标自动联动）
    this.offLoginChanged = EventBus.onLoginChanged((_event): void => {
      SessionService.shared().syncSessionState();
    });
    this.offUnreadChanged = EventBus.onUnreadChanged((_event): void => {
      SessionService.shared().syncSessionState();
    });
  }

  aboutToDisappear(): void {
    if (this.offLoginChanged !== null) {
      this.offLoginChanged();
      this.offLoginChanged = null;
    }
    if (this.offUnreadChanged !== null) {
      this.offUnreadChanged();
      this.offUnreadChanged = null;
    }
  }

  /** 用户信息区点击：已登录进个人中心，未登录进登录页 */
  private goUserCenter(): void {
    if (this.session.isLoggedIn) {
      Router.goPersonal();
    } else {
      Router.goLogin();
    }
  }

  /** 头像徽章（登录态网络头像 / 未登录占位圆 + 首字，两分支复用） */
  @Builder
  AvatarBadge() {
    Stack() {
      if (this.session.isLoggedIn && this.session.userAvatar.length > 0) {
        NetworkImage({
          url: this.session.userAvatar,
          imageWidth: 44,
          imageHeight: 44,
          radius: 22
        })
      } else {
        Circle()
          .width(44)
          .height(44)
          .fill($r('app.color.brand_surface'))
        Text(this.session.isLoggedIn && this.session.userName.length > 0
          ? this.session.userName.substring(0, 1)
          : '客')
          .fontSize($r('app.float.font_size_title'))
          .fontColor($r('app.color.brand'))
      }
    }
  }

  /** 昵称与提示文案（layoutWeight 撑满剩余宽度，两分支复用） */
  @Builder
  UserInfoTexts() {
    Column({ space: $r('app.float.space_xs') }) {
      Text(this.session.isLoggedIn ? this.session.userName : '未登录，点击登录')
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.session.isLoggedIn ? '查看个人中心' : '登录吐槽')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  /** SM 形态：现状结构零变化（平铺行 + 分隔线，CenteredShell 全宽） */
  @Builder
  CompactContent() {
    Column() {
      // 用户信息区：未登录点击登录，已登录点击进入个人中心
      Row({ space: $r('app.float.space_md') }) {
        this.AvatarBadge()
        this.UserInfoTexts()
      }
      .width('100%')
      .padding({
        top: $r('app.float.space_lg'),
        bottom: $r('app.float.space_lg')
      })
      .onClick(() => {
        this.goUserCenter();
      })

      Divider()
        .color($r('app.color.divider'))
        .margin({
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })

      MineEntry({ label: '我的收藏', onTap: (): void => Router.goStar() })
      MineEntry({ label: '历史记录', onTap: (): void => Router.goPlayHistory() })
      MineEntry({ label: '离线缓存', onTap: (): void => Router.goDownload() })
      MineEntry({
        label: '短消息',
        badgeCount: this.session.unreadMessageCount,
        onTap: (): void => Router.goMessageList()
      })
      MineEntry({
        label: '检查更新',
        onTap: (): void => doCheckUpdate(this.getUIContext(), false)
      })
      MineEntry({
        label: '设置',
        onTap: (): void => Router.goSettings()
      })
      MineEntry({ label: '关于', onTap: (): void => Router.goAbout() })
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md')
    })
    .alignItems(HorizontalAlign.Start)
  }

  /** MD+ 形态：头像卡通栏 + 功能菜单两列网格（分组卡片风格对齐 Settings） */
  @Builder
  ExpandedContent() {
    Column({ space: $r('app.float.space_md') }) {
      // 头像卡（通栏）：未登录点击登录，已登录点击进入个人中心
      Row({ space: $r('app.float.space_md') }) {
        this.AvatarBadge()
        this.UserInfoTexts()
        Text('›')
          .fontSize(20)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_md'),
        right: $r('app.float.space_md'),
        top: $r('app.float.space_lg'),
        bottom: $r('app.float.space_lg')
      })
      .borderRadius($r('app.float.radius_card'))
      .backgroundColor($r('app.color.card_background'))
      .onClick(() => {
        this.goUserCenter();
      })

      // 功能菜单卡：两列网格（行样式沿用 MineEntry，横向组间分隔线对齐 Settings）
      GridRow({ columns: 2 }) {
        GridCol({ span: 1 }) {
          MineEntry({ label: '我的收藏', onTap: (): void => Router.goStar() })
        }
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md')
        })
        GridCol({ span: 1 }) {
          MineEntry({ label: '历史记录', onTap: (): void => Router.goPlayHistory() })
        }
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md')
        })
        GridCol({ span: 2 }) {
          Divider()
            .color($r('app.color.divider'))
            .width('100%')
        }
        GridCol({ span: 1 }) {
          MineEntry({ label: '离线缓存', onTap: (): void => Router.goDownload() })
        }
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md')
        })
        GridCol({ span: 1 }) {
          MineEntry({
            label: '短消息',
            badgeCount: this.session.unreadMessageCount,
            onTap: (): void => Router.goMessageList()
          })
        }
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md')
        })
        GridCol({ span: 2 }) {
          Divider()
            .color($r('app.color.divider'))
            .width('100%')
        }
        GridCol({ span: 1 }) {
          MineEntry({
            label: '检查更新',
            onTap: (): void => doCheckUpdate(this.getUIContext(), false)
          })
        }
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md')
        })
        GridCol({ span: 1 }) {
          MineEntry({
            label: '设置',
            onTap: (): void => Router.goSettings()
          })
        }
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md')
        })
        GridCol({ span: 2 }) {
          Divider()
            .color($r('app.color.divider'))
            .width('100%')
        }
        GridCol({ span: 1 }) {
          MineEntry({ label: '关于', onTap: (): void => Router.goAbout() })
        }
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md')
        })
      }
      .width('100%')
      .borderRadius($r('app.float.radius_card'))
      .backgroundColor($r('app.color.card_background'))
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

  build() {
    if (this.windowSize.isCompact()) {
      // SM：手机形态保持现状（CenteredShell 在 SM 全宽，结构零变化）
      CenteredShell({ maxWidth: 600 }) {
        this.CompactContent()
      }
    } else {
      // MD+：撤窄壳，内容限宽 840 居中（MD 屏宽不足 840 时自然全宽）
      CenteredShell({ maxWidth: 840 }) {
        this.ExpandedContent()
      }
    }
  }
}

/**
 * 侧边导航视图（改版  → 沉浸光感 ）
 * - 大屏形态常驻侧栏（SideBarContainer 内容）
 * - 沉浸光感：侧栏半透明毛玻璃渐变 + 光感描边；账号入口为悬浮材质卡
 * - 频道导航 rail：logo 字标 + 账号悬浮卡 + 六频道（"我的"自常驻频道移除）
 * - “我的”改为底部独立悬浮按钮：点击展开沉浸光感选项面板（收藏/历史/缓存/短信/更新/设置/关于）
 * - 二级页面侧栏收起逻辑在 Index（showSideBar）
 */
import { GlobalState, SessionState } from '../common/GlobalState';
import { HomeTab } from '../common/Constants';
import { HomeVM } from '../viewmodel/HomeVM';
import { Router } from '../common/Router';
import { NetworkImage } from '../components/NetworkImage';
import { doCheckUpdate } from './mine/MineCenterView';
import uiMaterial from '@ohos.arkui.uiMaterial';

/** 大屏 rail 频道项（沉浸光感：选中 brand 天然+光晕，读共享 VM 选中态） */
@ComponentV2
struct SideNavRailItem {
  @Param index: number = 0;
  private vm: HomeVM = HomeVM.shared();

  build() {
    Text(HomeTab.TITLES[this.index])
      .fontSize($r('app.float.font_size_body'))
      .fontWeight(this.vm.currentChannel === this.index ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.vm.currentChannel === this.index
        ? $r('app.color.text_on_brand')
        : $r('app.color.text_primary'))
      .width('100%')
      .height(44)
      .textAlign(TextAlign.Start)
      .padding({ left: $r('app.float.space_md') })
      .borderRadius(14)
      .backgroundColor(this.vm.currentChannel === this.index
        ? $r('app.color.brand')
        : Color.Transparent)
      .shadow(this.vm.currentChannel === this.index
        ? { radius: 14, color: '#26000000', offsetX: 0, offsetY: 4 }
        : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
      .margin({
        left: $r('app.float.space_sm'),
        right: $r('app.float.space_sm'),
        top: 3,
        bottom: 3
      })
      .onClick(() => {
        this.vm.currentChannel = this.index;
        const tid: number | undefined = HomeTab.LIST_TIDS[`${this.index}`];
        if (tid !== undefined) {
          this.vm.loadChannel(tid);
        }
      })
  }
}

/** 侧栏悬浮“我的”面板菜单行 */
@ComponentV2
struct MineFloatRow {
  @Param label: string = '';
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
    .height(42)
    .borderRadius(12)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 底部悬浮“我的”按钮 + 展开的沉浸光感选项面板（与手机/MineCenterView 功能清单同源） */
@ComponentV2
struct MineFloatButton {
  @Local expanded: boolean = false;
  session: SessionState = GlobalState.sessionState();

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 展开面板（THICK 沉浸光感材质，悬浮于按钮上方）
      if (this.expanded) {
        Column({ space: 2 }) {
          MineFloatRow({ label: '我的收藏', onTap: (): void => { Router.goStar(); this.expanded = false; } })
          MineFloatRow({ label: '历史记录', onTap: (): void => { Router.goPlayHistory(); this.expanded = false; } })
          MineFloatRow({ label: '离线缓存', onTap: (): void => { Router.goDownload(); this.expanded = false; } })
          MineFloatRow({
            label: '短消息',
            badgeCount: this.session.unreadMessageCount,
            onTap: (): void => { Router.goMessageList(); this.expanded = false; }
          })
          MineFloatRow({
            label: '检查更新',
            onTap: (): void => { doCheckUpdate(this.getUIContext(), false); }
          })
          MineFloatRow({
            label: '设置',
            onTap: (): void => {
              this.getUIContext().getPromptAction().showToast({ message: '没什么好设置的啦( ﾟ∀ﾟ)' });
            }
          })
          MineFloatRow({ label: '关于', onTap: (): void => { Router.goAbout(); this.expanded = false; } })
        }
        .width('100%')
        .padding($r('app.float.space_sm'))
        .borderRadius(18)
        .shadow({ radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 })
        .systemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK }))
        .margin({ bottom: 56 })
      }

      // 悬浮按钮本体（brand 胶囊 + 光晕；未读数红标）
      Row({ space: $r('app.float.space_xs') }) {
        Text('我的')
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_on_brand'))
        if (this.session.unreadMessageCount > 0) {
          Text(this.session.unreadMessageCount > 99 ? '99+' : `${this.session.unreadMessageCount}`)
            .fontSize(10)
            .fontColor(Color.White)
            .backgroundColor(Color.Red)
            .borderRadius(9)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        }
        Text(this.expanded ? '▴' : '▾')
          .fontSize(11)
          .fontColor($r('app.color.text_on_brand'))
      }
      .width('100%')
      .height(44)
      .justifyContent(FlexAlign.Center)
      .borderRadius(22)
      .onClick(() => {
        this.expanded = !this.expanded;
      })
    }
    .width('100%')
  }
}

@ComponentV2
export struct SideNavView {
  private vm: HomeVM = HomeVM.shared();
  session: SessionState = GlobalState.sessionState();

  build() {
    Column() {
      // Logo 字标
      Image($r('app.media.logo'))
        .width(132)
        .height(34)
        .objectFit(ImageFit.Contain)
        .margin({ top: $r('app.float.space_md'), bottom: $r('app.float.space_sm') })

      // 账号悬浮卡（沉浸光感 THIN 材质：未登录点击登录 / 已登录进入个人中心）
      Row({ space: $r('app.float.space_md') }) {
        Stack() {
          if (this.session.isLoggedIn && this.session.userAvatar.length > 0) {
            NetworkImage({
              url: this.session.userAvatar,
              imageWidth: 40,
              imageHeight: 40,
              radius: 20
            })
          } else {
            Circle()
              .width(40)
              .height(40)
              .fill($r('app.color.brand_surface'))
            Text(this.session.isLoggedIn && this.session.userName.length > 0
              ? this.session.userName.substring(0, 1)
              : '客')
              .fontSize($r('app.float.font_size_title'))
              .fontColor($r('app.color.brand'))
          }
        }
        Column({ space: $r('app.float.space_xs') }) {
          Text(this.session.isLoggedIn ? this.session.userName : '未登录，点击登录')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.session.isLoggedIn ? '查看个人中心' : '登录吐槽')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_md'),
        right: $r('app.float.space_md'),
        top: $r('app.float.space_md'),
        bottom: $r('app.float.space_md')
      })
      .borderRadius(20)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN }))
      .shadow({ radius: 12, color: '#16000000', offsetX: 0, offsetY: 4 })
      .margin({
        left: $r('app.float.space_sm'),
        right: $r('app.float.space_sm')
      })
      .onClick(() => {
        if (this.session.isLoggedIn) {
          Router.goPersonal();
        } else {
          Router.goLogin();
        }
      })

      // 六频道导航（"我的"已移入底部悬浮按钮）
      ForEach(HomeTab.TITLES.filter((title: string, index: number): boolean => index !== HomeTab.MINE),
        (title: string, index: number) => {
          SideNavRailItem({ index: index })
        }, (title: string, index: number) => `${index}`)

      Blank()

      MineFloatButton()
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_sm'),
          bottom: $r('app.float.space_md')
        })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    // 官方沉浸光感：侧栏系统材质 ULTRA_THIN（上层悬浮卡用 THIN / 弹出面板用 THICK）+ 右侧光感描边
    .systemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THIN }))
    .border({
      width: { right: 1 },
      color: '#59FFFFFF'
    })
  }
}
/**
 * 私信会话页（大屏 UX 适配）
 * 左（对方）/右（自己）聊天气泡 + 回复发射框（乐观插入，失败回滚；仅回复不发新私信）
 * 上下文经 MessageDetailVM 单例传递（MessageList.open → Router.goMessageDetail）
 * ：LG/XL 会话限宽 600 居中 + 撑满内容区（SM/MD 全宽，零退化）
 * 路由：router_map.json → MessageDetailBuilder（注册）
 */
import { MessageDetailVM } from '../viewmodel/MessageDetailVM';
import { MessageDetailItem, MessageBubbleType } from '../model/entity/MessageEntities';
import { Router } from '../common/Router';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { NetworkImage } from '../components/NetworkImage';
import { EmptyView } from '../components/EmptyView';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function MessageDetailBuilder(name: string, param: Object) {
  MessageDetail({ routeParam: param })
}

@ComponentV2
struct MessageDetail {
  /** 路由参数（实际上下文经 MessageDetailVM 单例传递） */
  @Param routeParam: Object = new Object();
  @Local vm: MessageDetailVM = MessageDetailVM.shared();
  /** 窗口避让（吸底发射框让位小白条） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  aboutToAppear(): void {
    // 无上下文（异常直进）时退回
    if (this.vm.peer === null) {
      Router.back();
      return;
    }
    this.vm.init();
  }

  /** 发送回复 */
  private async doSend(): Promise<void> {
    const result: string = await this.vm.send();
    if (result.length > 0) {
      this.getUIContext().getPromptAction().showToast({ message: result });
    }
  }

  /** 单条气泡（左=对方 / 右=自己） */
  @Builder
  bubbleItem(item: MessageDetailItem) {
    Row({ space: $r('app.float.space_sm') }) {
      if (item.type === MessageBubbleType.LEFT) {
        NetworkImage({
          url: item.avatar,
          imageWidth: 32,
          imageHeight: 32,
          radius: 16
        })
      }
      Column({ space: $r('app.float.space_xs') }) {
        Text(item.hasSend ? item.time : '发射中')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
        Text(item.message)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(item.type === MessageBubbleType.RIGHT
            ? $r('app.color.brand_surface') : $r('app.color.card_background'))
          .borderRadius($r('app.float.radius_card'))
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            top: $r('app.float.space_sm'),
            bottom: $r('app.float.space_sm')
          })
          .constraintSize({ maxWidth: '72%' })
      }
      .alignItems(item.type === MessageBubbleType.RIGHT ? HorizontalAlign.End : HorizontalAlign.Start)
      .layoutWeight(1)
      if (item.type === MessageBubbleType.RIGHT) {
        NetworkImage({
          url: item.avatar,
          imageWidth: 32,
          imageHeight: 32,
          radius: 16
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md'),
      top: $r('app.float.space_sm'),
      bottom: $r('app.float.space_sm')
    })
    .justifyContent(item.type === MessageBubbleType.RIGHT ? FlexAlign.End : FlexAlign.Start)
  }

  build() {
    NavDestination() {
      if (this.vm.peer === null) {
        EmptyView({ message: '会话不存在' })
      } else {
        Column() {
          // LG/XL 会话限宽 600 居中 + 撑满内容区（SM/MD 全宽，零退化）
          CenteredShell({ maxWidth: 600, fillHeight: true }) {
            if (this.vm.loading && this.vm.items.length === 0) {
              LoadingState({ message: '会话加载中…' })
            } else if (this.vm.error.length > 0 && this.vm.items.length === 0) {
              ErrorRetry({
                message: this.vm.error,
                onRetry: (): void => {
                  this.vm.load();
                }
              })
            } else if (this.vm.items.length === 0) {
              EmptyView({ message: '还没有消息，回复一句吧' })
            } else {
              List({ space: 0 }) {
                ForEach(this.vm.items, (item: MessageDetailItem) => {
                  ListItem() {
                    this.bubbleItem(item)
                  }
                }, (item: MessageDetailItem, index: number): string => `${index}-${item.time}-${item.message}`)
              }
              .width('100%')
              .layoutWeight(1)
              .scrollBar(BarState.Off)
            }

            // 回复发射框（吸底，仅回复）
            Row({ space: $r('app.float.space_md') }) {
              TextInput({ text: this.vm.draft, placeholder: '回复私信…' })
                .fontSize($r('app.float.font_size_body'))
                .height(40)
                .layoutWeight(1)
                .backgroundColor($r('app.color.card_background'))
                .borderRadius($r('app.float.radius_card'))
                .onChange((value: string): void => {
                  this.vm.draft = value;
                })
              Button(this.vm.sending ? '发送中' : '发送')
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.text_on_brand'))
                .backgroundColor($r('app.color.brand'))
                .borderRadius($r('app.float.radius_button'))
                .height(40)
                .padding({ left: $r('app.float.space_md'), right: $r('app.float.space_md') })
                .enabled(!this.vm.sending)
                .onClick((): void => {
                  this.doSend();
                })
            }
            .width('100%')
            .padding($r('app.float.space_md'))
            // 吸底发射框让位小白条：壳层底部不垫后内容穿行指示条之下，
            // 手指可达性与胶囊可见性均需发射框整体抬升（margin 方案同 Tab 栏）
            .margin({ bottom: this.windowSize.navBarHeightVp })
          }
        }
        .width('100%')
        .height('100%')
      }
    }
    .title(this.vm.peer === null ? '私信' : `与 ${this.vm.peer.username} 的私信`)
    .backgroundColor($r('app.color.page_background'))
  }
}

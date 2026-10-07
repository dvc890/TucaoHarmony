/**
 * 楼中楼页（大屏 UX 适配）
 * 父评论置顶 + 楼中楼分页（每页 10 条，页码 0 起）+ 回复发射（乐观插入）
 * 上下文经 ReplyVM 单例传递（CommentsVM.openReplyFloor → Router.goReplyFloor）
 * ：LG/XL 内容限宽 600 居中 + 撑满内容区（SM/MD 全宽，零退化）；富文本按限宽排版
 * 路由：router_map.json → ReplyFloorBuilder（注册）
 */
import { ReplyVM } from '../viewmodel/ReplyVM';
import { Comment, Reply } from '../model/entity/CommentEntities';
import { Router } from '../common/Router';
import { display } from '@kit.ArkUI';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { NetworkImage } from '../components/NetworkImage';
import { EmptyView } from '../components/EmptyView';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { RelativeTime } from '../components/RelativeTimeText';
import { RichTextView } from '../components/RichTextView';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function ReplyFloorBuilder(name: string, param: Object) {
  ReplyFloor({ routeParam: param })
}

@ComponentV2
struct ReplyFloor {
  /** 路由参数（ReplyFloorParam：tid/rid，实际上下文经 ReplyVM 单例传递） */
  @Param routeParam: Object = new Object();
  @Local vm: ReplyVM = ReplyVM.shared();
  /** 窗口避让（吸底发射框让位小白条） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  aboutToAppear(): void {
    // 无上下文（异常直进）时退回
    if (this.vm.parent === null) {
      Router.back();
      return;
    }
    // 富文本排版宽度：内容宽 - 两侧 16*2 - 头像 36 - 间距 12
    // LG/XL 内容限宽 600（CenteredShell），按 600 排版；SM/MD 按屏宽（零退化）
    const disp: display.Display = display.getDefaultDisplaySync();
    const density: number = disp.densityPixels > 0 ? disp.densityPixels : 3;
    const screenVp: number = disp.width / density;
    const contentVp: number = GlobalState.windowSizeInfo().isExpanded()
      ? Math.min(screenVp, 600)
      : screenVp;
    this.vm.contentWidthVp = contentVp - 80;
    this.vm.init();
  }

  /** 发射回复 */
  private async doSend(): Promise<void> {
    const result: string = await this.vm.send();
    if (result === 'needLogin') {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录' });
    } else if (result.length > 0) {
      this.getUIContext().getPromptAction().showToast({ message: result });
    }
  }

  /** 父评论（置顶卡片） */
  @Builder
  parentCard(comment: Comment) {
    Column({ space: $r('app.float.space_xs') }) {
      Row({ space: $r('app.float.space_sm') }) {
        NetworkImage({
          url: comment.avatar,
          imageWidth: 36,
          imageHeight: 36,
          radius: 18
        })
        Text(comment.nickname)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text(comment.level)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.brand'))
      }
      .width('100%')
      if (comment.lch.length > 0) {
        Text(`${comment.lch} · ${RelativeTime.format(comment.time)}`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      RichTextView({
        html: comment.infoHtml,
        fallbackText: comment.info,
        baseFontSize: 15,
        contentWidthVp: this.vm.contentWidthVp
      })
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.card_background'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 单条楼中楼回复 */
  @Builder
  replyItem(reply: Reply) {
    Row({ space: $r('app.float.space_md') }) {
      NetworkImage({
        url: reply.avatar,
        imageWidth: 28,
        imageHeight: 28,
        radius: 14
      })
      Column({ space: $r('app.float.space_xs') }) {
        Row({ space: $r('app.float.space_sm') }) {
          Text(reply.nickname)
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          if (reply.hasSend) {
            Text(RelativeTime.format(reply.time))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
          } else {
            Text('发射中')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        RichTextView({
          html: reply.contentHtml,
          fallbackText: reply.content,
          baseFontSize: 15,
          contentWidthVp: this.vm.contentWidthVp
        })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({
      top: $r('app.float.space_md'),
      bottom: $r('app.float.space_md')
    })
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
          Text('楼中楼')
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

        if (this.vm.parent === null) {
          Column() {
            EmptyView({ message: '评论不存在' })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
        Column() {
          // LG/XL 内容限宽 600 居中 + 撑满内容区（SM/MD 全宽，零退化）
          CenteredShell({ maxWidth: 600, fillHeight: true }) {
            List({ space: 0 }) {
              // 父评论置顶
              ListItem() {
                this.parentCard(this.vm.parent as Comment)
              }
              // 分隔说明
              ListItem() {
                Text(`全部回复（${this.vm.total}）`)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .padding({ top: $r('app.float.space_md'), left: $r('app.float.space_md') })
              }

              if (this.vm.loading && this.vm.replies.length === 0) {
                ListItem() {
                  LoadingState({ message: '回复加载中…' })
                }
              } else if (this.vm.error.length > 0 && this.vm.replies.length === 0) {
                ListItem() {
                  ErrorRetry({
                    message: this.vm.error,
                    onRetry: (): void => {
                      this.vm.loadPage(0);
                    }
                  })
                }
              } else if (this.vm.replies.length === 0) {
                ListItem() {
                  EmptyView({ message: '还没有回复，快来抢楼' })
                }
              } else {
                ForEach(this.vm.replies, (reply: Reply) => {
                  ListItem() {
                    this.replyItem(reply)
                  }
                }, (reply: Reply, index: number): string => `${index}-${reply.id}-${reply.nickname}`)
              }

              // 分页条（页码 0 起，展示 +1）
              if (this.vm.maxPage > 1) {
                ListItem() {
                  Row({ space: $r('app.float.space_md') }) {
                    Button('‹ 上一页')
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor(this.vm.page > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                      .backgroundColor($r('app.color.card_background'))
                      .borderRadius($r('app.float.radius_button'))
                      .height(32)
                      .enabled(this.vm.page > 0 && !this.vm.loading)
                      .onClick((): void => {
                        this.vm.prevPage();
                      })
                    Text(`${this.vm.page + 1}/${this.vm.maxPage}`)
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor($r('app.color.text_secondary'))
                    Button('下一页 ›')
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor(this.vm.page + 1 < this.vm.maxPage
                        ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                      .backgroundColor($r('app.color.card_background'))
                      .borderRadius($r('app.float.radius_button'))
                      .height(32)
                      .enabled(this.vm.page + 1 < this.vm.maxPage && !this.vm.loading)
                      .onClick((): void => {
                        this.vm.nextPage();
                      })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                  .padding({ top: $r('app.float.space_sm') })
                }
              }
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .divider({
              strokeWidth: 1,
              color: $r('app.color.divider'),
              startMargin: $r('app.float.space_md'),
              endMargin: $r('app.float.space_md')
            })

            // 回复发射框（吸底）
            Row({ space: $r('app.float.space_md') }) {
              TextInput({ text: this.vm.draft, placeholder: '回复他/她…' })
                .fontSize($r('app.float.font_size_body'))
                .height(40)
                .layoutWeight(1)
                .backgroundColor($r('app.color.card_background'))
                .borderRadius($r('app.float.radius_card'))
                .onChange((value: string): void => {
                  this.vm.draft = value;
                })
              Button(this.vm.sending ? '发射中' : '回复')
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
        .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
    }
    .backgroundColor($r('app.color.page_background'))
    .hideTitleBar(true)
  }
}

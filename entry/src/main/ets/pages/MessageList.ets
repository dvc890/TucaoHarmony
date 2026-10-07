/**
 * 私信收件箱页（大屏 UX 适配）
 * 头像/用户名/时间/预览/未读标记；打开未读会话 → 本地已读 + 未读角标经 EventBus 联动侧边栏
 * ：LG/XL 列表限宽 600 居中 + 撑满内容区（SM/MD 全宽，零退化）
 * 路由：router_map.json → MessageListBuilder（注册）
 */
import { MessageListVM } from '../viewmodel/MessageListVM';
import { MessageSummary } from '../model/entity/MessageEntities';
import { Router } from '../common/Router';
import { NetworkImage } from '../components/NetworkImage';
import { EmptyView } from '../components/EmptyView';
import { ErrorRetry } from '../components/ErrorRetry';
import { LoadingState } from '../components/LoadingState';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function MessageListBuilder(name: string, param: Object) {
  MessageList({ routeParam: param })
}

@ComponentV2
struct MessageList {
  /** 路由参数（收件箱无参数） */
  @Param routeParam: Object = new Object();
  @Local vm: MessageListVM = new MessageListVM();

  aboutToAppear(): void {
    this.vm.init();
  }

  /** 单个会话行 */
  @Builder
  summaryRow(summary: MessageSummary) {
    Row({ space: $r('app.float.space_md') }) {
      NetworkImage({
        url: summary.avatar,
        imageWidth: 40,
        imageHeight: 40,
        radius: 20
      })
      Column({ space: $r('app.float.space_xs') }) {
        Row({ space: $r('app.float.space_sm') }) {
          Text(summary.username)
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .layoutWeight(1)
          if (!summary.read) {
            // 未读蓝点
            Circle()
              .width(8)
              .height(8)
              .fill($r('app.color.brand'))
          }
          Text(summary.time)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
        }
        .width('100%')
        Text(summary.message)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding($r('app.float.space_md'))
    .onClick((): void => {
      this.vm.open(summary);
    })
  }

  build() {
    NavDestination() {
      // LG/XL 列表限宽 600 居中 + 撑满内容区（SM/MD 全宽，零退化）
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
          Text('短消息')
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
        CenteredShell({ maxWidth: 600, fillHeight: true }) {
          if (!this.vm.isLoggedIn()) {
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
            .height('100%')
            .justifyContent(FlexAlign.Center)
          } else if (this.vm.loading && this.vm.summaries.length === 0) {
            LoadingState({ message: '收件箱加载中…' })
          } else if (this.vm.error.length > 0 && this.vm.summaries.length === 0) {
            ErrorRetry({
              message: this.vm.error,
              onRetry: (): void => {
                this.vm.load();
              }
            })
          } else if (this.vm.summaries.length === 0) {
            EmptyView({ message: '暂无私信' })
          } else {
            List() {
              ForEach(this.vm.summaries, (summary: MessageSummary) => {
                ListItem() {
                  this.summaryRow(summary)
                }
              }, (summary: MessageSummary): string => summary.id)
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            .divider({
              strokeWidth: 1,
              color: $r('app.color.divider'),
              startMargin: $r('app.float.space_md'),
              endMargin: $r('app.float.space_md')
            })
          }
        }
      }
      .width('100%')
      .height('100%')
    }
    .backgroundColor($r('app.color.page_background'))
    .hideTitleBar(true)
  }
}

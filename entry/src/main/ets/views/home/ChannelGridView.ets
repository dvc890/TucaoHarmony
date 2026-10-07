/**
 * 频道宫格视图
 * - 「频道」Tab 内容：六父频道入口（动画/音乐/游戏/三次元/影剧/新番）
 * - 点击跳频道详情页（ChannelDetail，路由仅传轻量 tid）
 */
import { Channel, ChannelTable } from '../../common/Constants';
import { Router } from '../../common/Router';

@ComponentV2
export struct ChannelGridView {
  build() {
    Column() {
      GridRow({ columns: { xs: 2, sm: 2, md: 3, lg: 3, xl: 6 }, gutter: 12 }) {
        ForEach(ChannelTable.findAllParentChannels(), (channel: Channel) => {
          GridCol({ span: 1 }) {
            Column({ space: $r('app.float.space_sm') }) {
              Text(channel.name.substring(0, 1))
                .fontSize($r('app.float.page_text_font_size'))
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.brand'))
              Text(channel.name)
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
            .padding({
              top: $r('app.float.space_lg'),
              bottom: $r('app.float.space_lg')
            })
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius($r('app.float.radius_card'))
            .onClick(() => {
              Router.goChannelDetail(channel.id);
            })
          }
        }, (channel: Channel) => `${channel.id}`)
      }
      .width('100%')
      .margin({ top: $r('app.float.space_md') })
    }
    .width('100%')
    .height('100%')
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md')
    })
    .alignItems(HorizontalAlign.Start)
  }
}

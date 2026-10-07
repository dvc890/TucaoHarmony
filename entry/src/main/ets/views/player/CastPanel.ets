/**
 * 投屏面板：半模态 sheet 内容（在 Player 挂载，detents 建议 [0.6]）
 * - 系统投播入口：AVCastPickerHelper 系统设备选择器（Cast+ Stream / DLNA，连接最稳）
 * - DLNA 自研发现列表：SSDP 扫描 / 重扫 / 点击投放（无系统投播能力时兜底）
 * - 投播中：当前设备卡片 + 一键退出
 * - 面板错误 / 扫描中 / 连接中状态就地呈现
 */
import { CastChannel, CastDevice } from '../../service/cast/CastController';
import { CastVM } from '../../viewmodel/CastVM';

@ComponentV2
export struct CastPanel {
  /** 共享投屏 VM */
  @Require @Param vm: CastVM;
  /** 面板关闭通知（父级收起 sheet；VM 状态由 vm.closePanel() 内部清理） */
  @Param onClose: () => void = (): void => {
  };

  build() {
    Column() {
      // 标题行
      Row() {
        Text('投屏')
          .fontSize($r('app.float.font_size_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('✕')
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_secondary'))
          .padding($r('app.float.space_xs'))
          .onClick((): void => {
            this.vm.closePanel();
            this.onClose();
          })
      }
      .width('100%')
      .padding({ top: $r('app.float.space_md'), bottom: $r('app.float.space_sm') })

      Scroll() {
        Column({ space: $r('app.float.space_md') }) {
          if (this.vm.casting) {
            this.CurrentDeviceCard()
          }
          if (!this.vm.casting) {
            this.SystemPickerCard()
          }
          this.DlnaSection()
        }
        .width('100%')
        .padding({ bottom: $r('app.float.space_lg') })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md')
    })
    .backgroundColor($r('app.color.float_background'))
  }

  /** 当前投播设备卡片（投播中置顶展示） */
  @Builder
  CurrentDeviceCard() {
    Column() {
      Row() {
        Column() {
          Text(this.vm.deviceName)
            .fontSize($r('app.float.font_size_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.vm.channel === CastChannel.SYSTEM_CAST ? '系统投播 · 连接中稳定' : 'DLNA · 局域网直连')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: $r('app.float.space_xs') })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
        if (this.vm.connecting) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color($r('app.color.text_secondary'))
            .margin({ right: $r('app.float.space_sm') })
        }
      }
      .width('100%')

      Button('退出投屏')
        .type(ButtonType.Normal)
        .borderRadius($r('app.float.radius_button'))
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .fontSize($r('app.float.font_size_body'))
        .width('100%')
        .height(40)
        .margin({ top: $r('app.float.space_md') })
        .onClick((): void => {
          this.vm.exitCast();
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.card_background'))
  }

  /** 系统投播入口（推荐路径） */
  @Builder
  SystemPickerCard() {
    Row() {
      Column() {
        Text('系统投播（推荐）')
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('Cast+ / DLNA，由系统选择器发现并连接电视')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: $r('app.float.space_xs') })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.vm.connecting) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color($r('app.color.brand'))
      } else {
        Text('›')
          .fontSize($r('app.float.font_size_title_lg'))
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.card_background'))
    .onClick((): void => {
      if (this.vm.connecting) {
        return;
      }
      this.vm.openSystemPicker();
    })
  }

  /** DLNA 自研发现区 */
  @Builder
  DlnaSection() {
    Column() {
      Row() {
        Text('附近的 DLNA 设备')
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.vm.discovering) {
          Row() {
            LoadingProgress()
              .width(14)
              .height(14)
              .color($r('app.color.text_secondary'))
            Text('搜索中…')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: $r('app.float.space_xs') })
          }
        } else {
          Text('重新扫描')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.brand'))
            .padding($r('app.float.space_xs'))
            .onClick((): void => {
              this.vm.refreshDlna();
            })
        }
      }
      .width('100%')
      .margin({ bottom: $r('app.float.space_sm') })

      if (this.vm.dlnaDevices.length > 0) {
        ForEach(this.vm.dlnaDevices, (device: CastDevice) => {
          this.DeviceRow(device)
        }, (device: CastDevice): string => device.deviceId)
      } else if (!this.vm.discovering) {
        Column() {
          Text(this.vm.panelError.length > 0 ? this.vm.panelError : '未发现设备')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
          if (this.vm.panelError.length > 0) {
            Text('重试')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.brand'))
              .padding({
                top: $r('app.float.space_sm'),
                bottom: $r('app.float.space_xs')
              })
              .onClick((): void => {
                this.vm.refreshDlna();
              })
          }
        }
        .width('100%')
        .padding($r('app.float.space_md'))
        .borderRadius($r('app.float.radius_card'))
        .backgroundColor($r('app.color.card_background'))
        .alignItems(HorizontalAlign.Center)
      } else {
        Text('正在搜索附近设备，请稍候…')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding($r('app.float.space_md'))
          .borderRadius($r('app.float.radius_card'))
          .backgroundColor($r('app.color.card_background'))
          .textAlign(TextAlign.Center)
      }

      // 面板级错误（地址解析失败/会话创建失败等，非设备列表空态）
      if (this.vm.panelError.length > 0 && this.vm.dlnaDevices.length > 0) {
        Text(this.vm.panelError)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.error'))
          .width('100%')
          .margin({ top: $r('app.float.space_sm') })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** DLNA 设备行 */
  @Builder
  DeviceRow(device: CastDevice) {
    Row() {
      Column() {
        Text(device.deviceName)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('DLNA · 局域网直连')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: $r('app.float.space_xs') })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.vm.connecting) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color($r('app.color.brand'))
      } else {
        Text('投屏')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.brand'))
      }
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.card_background'))
    .margin({ bottom: $r('app.float.space_xs') })
    .onClick((): void => {
      if (this.vm.connecting) {
        return;
      }
      this.vm.castToDevice(device);
    })
  }
}

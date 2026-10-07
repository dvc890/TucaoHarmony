/**
 * 投播控制条：投播中替代本机控制的远端迷你控制条
 * - 设备行：投屏目标设备名 + 错误提示 + 一键退出（退出后恢复本地播放）
 * - 进度：远端镜像进度滑杆（拖动期间仅本地预览，松手一次性 seek 远端）
 * - 控制：播放/暂停 + 时间；设备支持音量时展示 −/＋ 步进（0.1）
 * - onInteraction：交互通知（父级重置控制层自动隐藏计时器）
 */
import { CastVM } from '../../viewmodel/CastVM';
import { VideoDetailVM } from '../../viewmodel/VideoDetailVM';
import { MediaSlider } from '../../components/MediaSlider';

@ComponentV2
export struct CastControlBar {
  /** 共享投屏 VM */
  @Require @Param vm: CastVM;
  /** 交互通知（父级重置控制层自动隐藏计时器） */
  @Param onInteraction: () => void = (): void => {
  };

  build() {
    Column() {
      // 设备行
      Row() {
        Text(`投屏中 · ${this.vm.deviceName}`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.vm.castError.length > 0) {
          Text(this.vm.castError)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.error'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.End)
            .margin({ left: $r('app.float.space_sm') })
        }
        Text('退出')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.brand'))
          .padding({
            left: $r('app.float.space_sm'),
            top: $r('app.float.space_xs'),
            bottom: $r('app.float.space_xs')
          })
          .onClick((): void => {
            this.onInteraction();
            this.vm.exitCast();
          })
      }
      .width('100%')

      // 进度滑杆（远端镜像）
      MediaSlider({
        value: this.vm.remote.positionMs,
        maxValue: this.vm.remote.durationMs,
        onSeek: (ms: number): void => {
          this.vm.seekTo(ms);
        },
        onInteraction: (): void => {
          this.onInteraction();
        }
      })
        .margin({ top: $r('app.float.space_sm') })

      // 控制行：播放/暂停 + 时间 + 音量步进
      Row() {
        Text(this.vm.remote.playing ? '❚❚' : '▶')
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .padding($r('app.float.space_xs'))
          .onClick((): void => {
            this.onInteraction();
            this.vm.togglePlay();
          })
        Text(`${VideoDetailVM.formatClock(this.vm.remote.positionMs)} / ${VideoDetailVM.formatClock(this.vm.remote.durationMs)}`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: $r('app.float.space_sm') })
        Blank()
        if (this.vm.remote.volumeSupported) {
          Row() {
            Text('−')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_secondary'))
              .padding({
                left: $r('app.float.space_sm'),
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .onClick((): void => {
                this.onInteraction();
                this.vm.setVolume(this.vm.remote.volume - 0.1);
              })
            Text(`${Math.round(this.vm.remote.volume * 100)}%`)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_secondary'))
            Text('+')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_secondary'))
              .padding({
                left: $r('app.float.space_sm'),
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .onClick((): void => {
                this.onInteraction();
                this.vm.setVolume(this.vm.remote.volume + 0.1);
              })
          }
        }
      }
      .width('100%')
      .margin({ top: $r('app.float.space_sm') })
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.card_background'))
    .onClick((): void => {
      this.onInteraction();
    })
  }
}

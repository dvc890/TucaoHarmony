/**
 * 统一设置面板（右侧滑入，对齐安卓 setting_layout 280dp，收窄宽度）
 * - 双 Tab：「播放」= 倍速 / 画面缩放 / 画面复位 / 画质 / 自动连播 / 自动续播 / 小窗播放；
 *          「弹幕」= 显示弹幕 / 不透明度 / 字号倍率 / 滚动速度 / 关键词屏蔽（原抽屉内容整合）
 * - 小窗播放：PiP 系统悬浮窗（PiPWindow VIDEO_PLAY 模板，启动后应用退后台）
 * - 画面复位：双指自由变换（捏合缩放+拖移）回 1x 居中
 * - 点击面板外部关闭
 */
import { VideoDetailVM } from '../../viewmodel/VideoDetailVM';
import { DanmakuVM } from '../../viewmodel/DanmakuVM';
import { PreferenceStore } from '../../data/PreferenceStore';
import { QualityOption, QualityTable, ScaleTable, ScaleModeOption } from '../../common/Constants';
import { VideoZoomState } from './VideoZoomState';

@ComponentV2
export struct PlayerSettingsPanel {
  @Param vm: VideoDetailVM = VideoDetailVM.shared();
  /** 双指自由变换状态（读取当前倍率展示；复位经 onResetVideoFrame 由宿主页执行） */
  @Param zoomState: VideoZoomState = new VideoZoomState();
  @Param visible: boolean = false;
  @Param onDismiss: () => void = (): void => {};
  /** 小窗播放（PiP）：由宿主页实现（创建悬浮窗 + 退后台） */
  @Param onOpenPiP: () => void = (): void => {};
  /** 画面复位：双指自由变换回 1x 居中（宿主页直接操作其 zoomState） */
  @Param onResetVideoFrame: () => void = (): void => {};
  @Local activeTab: number = 0;
  @Local newWord: string = '';
  private danmakuVm: DanmakuVM = DanmakuVM.shared();

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.End }) {
        // 点击外部区域关闭
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.01)')
          .onClick((): void => {
            this.onDismiss();
          })

        // 右侧设置面板（收窄：内容为竖排列表，无需全屏宽度）
        Column() {
          // 标题栏
          Row() {
            Text('设置')
              .fontSize($r('app.float.font_size_title'))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bold)
            Blank()
            Text('✕')
              .fontSize(18)
              .fontColor(Color.White)
              .padding($r('app.float.space_sm'))
              .onClick((): void => {
                this.onDismiss();
              })
          }
          .width('100%')
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            top: $r('app.float.space_md'),
            bottom: $r('app.float.space_xs')
          })

          // Tab 切换（播放 / 弹幕）
          Row({ space: $r('app.float.space_md') }) {
            Text('播放')
              .fontSize($r('app.float.font_size_body'))
              .fontColor(this.activeTab === 0 ? $r('app.color.brand') : 'rgba(255,255,255,0.60)')
              .fontWeight(this.activeTab === 0 ? FontWeight.Bold : FontWeight.Normal)
              .padding({
                left: $r('app.float.space_xs'),
                right: $r('app.float.space_xs'),
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .border({
                width: { bottom: 2 },
                color: { bottom: this.activeTab === 0 ? $r('app.color.brand') : Color.Transparent }
              })
              .onClick((): void => {
                this.activeTab = 0;
              })
            Text('弹幕')
              .fontSize($r('app.float.font_size_body'))
              .fontColor(this.activeTab === 1 ? $r('app.color.brand') : 'rgba(255,255,255,0.60)')
              .fontWeight(this.activeTab === 1 ? FontWeight.Bold : FontWeight.Normal)
              .padding({
                left: $r('app.float.space_xs'),
                right: $r('app.float.space_xs'),
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .border({
                width: { bottom: 2 },
                color: { bottom: this.activeTab === 1 ? $r('app.color.brand') : Color.Transparent }
              })
              .onClick((): void => {
                this.activeTab = 1;
              })
          }
          .width('100%')
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            bottom: $r('app.float.space_xs')
          })

          Scroll() {
            Column({ space: $r('app.float.space_lg') }) {
              if (this.activeTab === 0) {
                this.PlaySettings()
              } else {
                this.DanmakuSettings()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Auto)
          // 内容不足视口时贴顶（Scroll 默认居中导致排版下沉）
          .align(Alignment.Top)
        }
        .width(340)
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.85)')
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => {
          // 阻止点击冒泡到外层关闭
        })
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 「播放」Tab：倍速 / 画面缩放 / 画面复位 / 画质 / 自动连播 / 自动续播 / 小窗播放 */
  @Builder
  private PlaySettings() {
    // 播放速度
    Column({ space: $r('app.float.space_xs') }) {
      Row() {
        Text('播放速度')
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
        Blank()
        Text(`${this.vm.speed.toFixed(2)}x`)
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
      }
      .width('100%')

      Row({ space: $r('app.float.space_sm') }) {
        Text('0.5')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor('rgba(255,255,255,0.60)')
        Slider({
          value: this.vm.speed,
          min: 0.5,
          max: 3.0,
          step: 0.05,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .selectedColor($r('app.color.brand'))
          .blockColor(Color.White)
          .trackColor('rgba(255,255,255,0.30)')
          .onChange((value: number, _mode: SliderChangeMode): void => {
            this.vm.setSpeed(value);
          })
        Text('3.0')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor('rgba(255,255,255,0.60)')
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 画面缩放（原比例/16:9/4:3/撑满）
    Column({ space: $r('app.float.space_sm') }) {
      Text('画面缩放')
        .fontSize($r('app.float.font_size_body'))
        .fontColor(Color.White)
      Row({ space: $r('app.float.space_sm') }) {
        ForEach(ScaleTable.ALL, (option: ScaleModeOption) => {
          Text(option.label)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(this.vm.scaleMode === option.mode ? $r('app.color.brand') : Color.White)
            .padding({
              left: $r('app.float.space_md'),
              right: $r('app.float.space_md'),
              top: $r('app.float.space_xs'),
              bottom: $r('app.float.space_xs')
            })
            .borderRadius($r('app.float.radius_button'))
            .backgroundColor(this.vm.scaleMode === option.mode ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.06)')
            .onClick((): void => {
              this.vm.setScaleMode(option.mode);
            })
        }, (option: ScaleModeOption): string => `setting-scale-${option.mode}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 画面复位（双指自由变换回 1x 居中；已是 1x 时置灰提示）
    Row() {
      Text('画面复位')
        .fontSize($r('app.float.font_size_body'))
        .fontColor(Color.White)
      Blank()
      Text(`${this.zoomState.scale.toFixed(1)}x`)
        .fontSize($r('app.float.font_size_body'))
        .fontColor(Color.White)
        .opacity(this.zoomState.scale === 1 ? 0.45 : 1)
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md'),
          top: $r('app.float.space_xs'),
          bottom: $r('app.float.space_xs')
        })
        .borderRadius($r('app.float.radius_button'))
        .backgroundColor('rgba(255,255,255,0.06)')
        .onClick((): void => {
          this.onResetVideoFrame();
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 画质（仅 PLAYURL 分集显示）
    if (this.vm.qualities.length > 0) {
      Column({ space: $r('app.float.space_sm') }) {
        Text('画质')
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
        Row({ space: $r('app.float.space_sm') }) {
          Text('默认')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(this.vm.currentQualitySrc.length === 0 ? $r('app.color.brand') : Color.White)
            .padding({
              left: $r('app.float.space_md'),
              right: $r('app.float.space_md'),
              top: $r('app.float.space_xs'),
              bottom: $r('app.float.space_xs')
            })
            .borderRadius($r('app.float.radius_button'))
            .backgroundColor(this.vm.currentQualitySrc.length === 0 ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.06)')
            .onClick((): void => {
              this.vm.setQuality('');
            })
          ForEach(this.vm.qualities, (option: QualityOption) => {
            Text(option.label)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor(this.vm.currentQualitySrc === option.src ? $r('app.color.brand') : Color.White)
              .padding({
                left: $r('app.float.space_md'),
                right: $r('app.float.space_md'),
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .borderRadius($r('app.float.radius_button'))
              .backgroundColor(this.vm.currentQualitySrc === option.src ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.06)')
              .onClick((): void => {
                this.vm.setQuality(option.src);
              })
          }, (option: QualityOption): string => `setting-quality-${option.src}`)
        }
        .width('100%')
      }
      .width('100%')
      .padding($r('app.float.space_md'))
    }

    // 自动连播
    Row() {
      Text('自动连播')
        .fontSize($r('app.float.font_size_body'))
        .fontColor(Color.White)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: PreferenceStore.playerConfig().autoNext })
        .selectedColor($r('app.color.brand'))
        .onChange((isOn: boolean): void => {
          PreferenceStore.playerConfig().autoNext = isOn;
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 自动续播
    Row() {
      Text('自动续播')
        .fontSize($r('app.float.font_size_body'))
        .fontColor(Color.White)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: PreferenceStore.playerConfig().autoResume })
        .selectedColor($r('app.color.brand'))
        .onChange((isOn: boolean): void => {
          PreferenceStore.playerConfig().autoResume = isOn;
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 小窗播放（PiP 系统悬浮窗）
    Row() {
      Text('小窗播放')
        .fontSize($r('app.float.font_size_body'))
        .fontColor(Color.White)
      Blank()
      Text('›')
        .fontSize(18)
        .fontColor(Color.White)
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .backgroundColor('rgba(255,255,255,0.04)')
    .borderRadius($r('app.float.radius_card'))
    .onClick((): void => {
      this.onDismiss();
      this.onOpenPiP();
    })
  }

  /** 「弹幕」Tab：开关 / 不透明度 / 字号倍率 / 滚动速度 / 关键词屏蔽（原弹幕设置抽屉内容） */
  @Builder
  private DanmakuSettings() {
    // 显示弹幕总开关
    Row() {
      Text('显示弹幕')
        .fontSize($r('app.float.font_size_body'))
        .fontColor(Color.White)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.danmakuVm.danmakuOn })
        .selectedColor($r('app.color.brand'))
        .onChange((isOn: boolean): void => {
          this.danmakuVm.danmakuOn = isOn;
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 池状态提示
    if (this.danmakuVm.poolError.length > 0) {
      Text(this.danmakuVm.poolError)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor('rgba(255,255,255,0.50)')
        .padding({ left: $r('app.float.space_md'), right: $r('app.float.space_md') })
    } else if (this.danmakuVm.poolEmpty) {
      Text('暂无弹幕，发送一条开启气氛吧')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor('rgba(255,255,255,0.50)')
        .padding({ left: $r('app.float.space_md'), right: $r('app.float.space_md') })
    }

    // 不透明度
    Column({ space: $r('app.float.space_xs') }) {
      Row() {
        Text('不透明度')
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
        Blank()
        Text(`${Math.round(this.danmakuVm.danmakuOpacity * 100)}%`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor('rgba(255,255,255,0.70)')
      }
      .width('100%')
      Slider({
        value: this.danmakuVm.danmakuOpacity,
        min: 0.2,
        max: 1.0,
        step: 0.05,
        style: SliderStyle.OutSet
      })
        .selectedColor($r('app.color.brand'))
        .blockColor(Color.White)
        .trackColor('rgba(255,255,255,0.30)')
        .width('100%')
        .onChange((value: number, _mode: SliderChangeMode): void => {
          this.danmakuVm.danmakuOpacity = value;
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 字号倍率
    Column({ space: $r('app.float.space_xs') }) {
      Row() {
        Text('字号倍率')
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
        Blank()
        Text(`${this.danmakuVm.danmakuScale.toFixed(2)}x`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor('rgba(255,255,255,0.70)')
      }
      .width('100%')
      Slider({
        value: this.danmakuVm.danmakuScale,
        min: 0.5,
        max: 2.0,
        step: 0.05,
        style: SliderStyle.OutSet
      })
        .selectedColor($r('app.color.brand'))
        .blockColor(Color.White)
        .trackColor('rgba(255,255,255,0.30)')
        .width('100%')
        .onChange((value: number, _mode: SliderChangeMode): void => {
          this.danmakuVm.danmakuScale = value;
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 滚动速度
    Column({ space: $r('app.float.space_xs') }) {
      Row() {
        Text('滚动速度')
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
        Blank()
        Text(`${this.danmakuVm.danmakuSpeed.toFixed(2)}x`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor('rgba(255,255,255,0.70)')
      }
      .width('100%')
      Slider({
        value: this.danmakuVm.danmakuSpeed,
        min: 0.3,
        max: 2.0,
        step: 0.05,
        style: SliderStyle.OutSet
      })
        .selectedColor($r('app.color.brand'))
        .blockColor(Color.White)
        .trackColor('rgba(255,255,255,0.30)')
        .width('100%')
        .onChange((value: number, _mode: SliderChangeMode): void => {
          this.danmakuVm.danmakuSpeed = value;
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 关键词屏蔽总开关
    Row() {
      Text('关键词屏蔽')
        .fontSize($r('app.float.font_size_body'))
        .fontColor(Color.White)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.danmakuVm.blockEnable })
        .selectedColor($r('app.color.brand'))
        .onChange((isOn: boolean): void => {
          this.danmakuVm.blockEnable = isOn;
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 屏蔽词添加
    Row({ space: $r('app.float.space_sm') }) {
      TextInput({ placeholder: '输入屏蔽词', text: this.newWord })
        .layoutWeight(1)
        .onChange((value: string): void => {
          this.newWord = value;
        })
      Button('添加')
        .fontSize($r('app.float.font_size_caption'))
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md')
        })
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .onClick((): void => {
          this.danmakuVm.addBlockWord(this.newWord);
          this.newWord = '';
        })
    }
    .width('100%')
    .padding($r('app.float.space_md'))

    // 屏蔽词列表
    if (this.danmakuVm.blockWords.length === 0) {
      Text('暂无屏蔽词，可添加 http 屏蔽广告弹幕')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor('rgba(255,255,255,0.50)')
        .padding($r('app.float.space_md'))
    } else {
      Column() {
        ForEach(this.danmakuVm.blockWords, (word: string) => {
          Row() {
            Text(word)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor('rgba(255,255,255,0.70)')
              .layoutWeight(1)
            Text('删除')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.brand'))
              .onClick((): void => {
                this.danmakuVm.removeBlockWord(word);
              })
          }
          .width('100%')
          .padding({
            top: $r('app.float.space_xs'),
            bottom: $r('app.float.space_xs')
          })
        }, (word: string): string => word)
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_md'),
        right: $r('app.float.space_md')
      })
    }
  }
}

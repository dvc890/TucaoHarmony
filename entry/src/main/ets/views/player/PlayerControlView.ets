/**
 * 播放控制层（接线完成）
 * - 详情页半屏与全屏页共用：fullscreen 参数切换布局（标题栏/底部按钮组一致）
 * - systemMaterial 显式 uiMaterial.Material.empty（视频上方不做模糊材质，功耗豁免）
 * - 控制项：返回、投屏、播放/暂停、±10s、+90s、进度滑杆、倍速菜单、清晰度菜单、
 *   弹幕设置、弹幕输入条（全屏）、选集、全屏切换、时间+电量（全屏标题栏最右）
 * - 投播中（CastVM.casting）：底部本机控制替换为 CastControlBar 远端迷你控制条
 * - 全屏形态避让：顶栏/底栏 padding 取 WindowSizeInfo 状态栏/导航条/挖孔避让（px→vp）
 * - 键盘（全屏形态）：空格=播放暂停、←→=±10s、↑↓=音量(应用内)步进 0.1、Esc=退出全屏
 *   （半屏形态不注册按键，方向键保留给页面滚动）
 * - 音量 HUD：↑↓ 操作后浮层显示 800ms（系统音量键不受应用控制）
 */
import { uiMaterial } from '@kit.ArkUI';
import { batteryInfo } from '@kit.BasicServicesKit';
import { KeyCode } from '@kit.InputKit';
import { VideoDetailVM } from '../../viewmodel/VideoDetailVM';
import { DanmakuVM } from '../../viewmodel/DanmakuVM';
import { CastVM } from '../../viewmodel/CastVM';
import { PlayerCoreState } from '../../service/player/PlayerController';
import { QualityOption, QualityTable, ScaleTable, ScaleModeOption } from '../../common/Constants';
import { GlobalState, WindowSizeInfo } from '../../common/GlobalState';
import { MediaSlider } from '../../components/MediaSlider';
import { CastControlBar } from './CastControlBar';

/** 倍速候选（AVPlayer 原生最高 3.0x，无 4x 档位） */
export class SpeedTable {
  static readonly ALL: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];

  static labelOf(rate: number): string {
    return `${rate}x`;
  }
}

@ComponentV2
export struct PlayerControlView {
  /** 共享 VM（镜像态驱动 UI） */
  @Param vm: VideoDetailVM = VideoDetailVM.shared();
  /** 控制层可见性（父级持有并负责自动隐藏计时） */
  @Param visible: boolean = false;
  /** 全屏形态（true=全屏页：显示 Esc 语义/返回=退出全屏） */
  @Param fullscreen: boolean = true;
  /** 返回/退出全屏 */
  @Param onBack: () => void = (): void => {
  };
  /** 全屏切换 */
  @Param onToggleFullscreen: () => void = (): void => {
  };
  /** 交互通知（重置自动隐藏计时） */
  @Param onInteraction: () => void = (): void => {
  };
  /** 选集入口（页面决定呈现：半屏=滚动到分集区；全屏=侧拉列表） */
  @Param onOpenParts: () => void = (): void => {
  };
  /** 设置面板入口（全屏页面提供） */
  @Param onOpenSettings: () => void = (): void => {
  };
  /** 点击空白背景：切换控制层显隐（再次点击可隐藏） */
  @Param onToggleControls: () => void = (): void => {
  };
  /** 竖向滑动转发：亮度/音量手势在控制层可见时同样生效（Player 页实现，隐藏时由页面手势层处理） */
  @Param onVerticalPanStart: (event: GestureEvent) => void = (_event: GestureEvent): void => {
  };
  @Param onVerticalPanUpdate: (event: GestureEvent) => void = (_event: GestureEvent): void => {
  };
  @Param onVerticalPanEnd: () => void = (): void => {
  };

  /** 音量 HUD 可见 */
  @Local volumeHudVisible: boolean = false;
  /** 音量 HUD 文案 */
  @Local volumeHudText: string = '';
  /** 弹幕输入条文案 */
  @Local danmakuInput: string = '';
  /** 标题栏时钟（HH:mm 24 小时制；控制层每次唤出时刷新） */
  @Local titleClock: string = '';
  /** 标题栏电量（batterySOC 0-100 同步读；控制层每次唤出时刷新） */
  @Local titleBattery: string = '';
  private volumeHudTimer: number = -1;
  private castVm: CastVM = CastVM.shared();
  private danmakuVm: DanmakuVM = DanmakuVM.shared();
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  private isPlaying(): boolean {
    return this.vm.coreState === PlayerCoreState.PLAYING;
  }

  private interact(): void {
    this.onInteraction();
  }

  /** 发送弹幕（本地回显立即生效） */
  private doSendDanmu(): void {
    const text: string = this.danmakuInput;
    if (text.trim().length === 0) {
      return;
    }
    this.danmakuVm.sendDanmu(text);
    this.danmakuInput = '';
    this.interact();
  }

  /** 全屏形态顶栏避让（状态栏高度 px→vp） */
  private avoidTopVp(): number {
    if (!this.fullscreen) {
      return 0;
    }
    return this.getUIContext().px2vp(this.windowSize.statusBarHeightPx);
  }

  /** 全屏形态底栏避让（导航条高度 px→vp） */
  private avoidBottomVp(): number {
    if (!this.fullscreen) {
      return 0;
    }
    return this.getUIContext().px2vp(this.windowSize.navBarHeightPx);
  }

  /** 全屏形态左右避让（挖孔屏横屏；竖屏时值为 0 天然不避让） */
  private avoidSideVp(): number {
    if (!this.fullscreen) {
      return 0;
    }
    const left: number = this.getUIContext().px2vp(this.windowSize.cutoutLeftPx);
    const right: number = this.getUIContext().px2vp(this.windowSize.cutoutRightPx);
    return Math.max(left, right);
  }

  /** 音量步进 ±0.1 + HUD */
  private stepVolume(direction: number): void {
    const next: number = this.vm.volume + direction * 0.1;
    this.vm.setVolume(next);
    this.volumeHudText = `音量 ${Math.round(Math.min(1, Math.max(0, next)) * 100)}%`;
    this.volumeHudVisible = true;
    if (this.volumeHudTimer >= 0) {
      clearTimeout(this.volumeHudTimer);
    }
    this.volumeHudTimer = setTimeout((): void => {
      this.volumeHudVisible = false;
      this.volumeHudTimer = -1;
    }, 800);
  }

  aboutToAppear(): void {
    // 标题栏时间+电量：控制层每次唤出 = 本控件重建，aboutToAppear 即自然刷新
    // （复刻安卓 DanmuVideoPlayer 唤出控制条时刷新一次的语义）
    this.refreshTitleStatus();
  }

  /** 标题栏 HH:mm 时钟 + 电量百分比（batterySOC 同步读，无需权限） */
  private refreshTitleStatus(): void {
    const now: Date = new Date();
    const hours: number = now.getHours();
    const minutes: number = now.getMinutes();
    const hh: string = hours < 10 ? `0${hours}` : `${hours}`;
    const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
    this.titleClock = `${hh}:${mm}`;
    this.titleBattery = `${Math.round(batteryInfo.batterySOC)}%`;
  }

  aboutToDisappear(): void {
    if (this.volumeHudTimer >= 0) {
      clearTimeout(this.volumeHudTimer);
      this.volumeHudTimer = -1;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 半透明底（半屏较浅，全屏较深）：点击空白切换控制层显隐
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.fullscreen ? 'rgba(0,0,0,0.45)' : 'rgba(0,0,0,0.30)')
        .onClick((): void => {
          this.onToggleControls();
        })

      // 音量 HUD
      if (this.volumeHudVisible) {
        Text(this.volumeHudText)
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
          .backgroundColor('rgba(0,0,0,0.60)')
          .borderRadius($r('app.float.radius_card'))
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            top: $r('app.float.space_sm'),
            bottom: $r('app.float.space_sm')
          })
      }

      // 主体控制区
      Column() {
        // 顶栏：返回 + 标题 + 投屏
        Row({ space: $r('app.float.space_sm') }) {
          Image($r('app.media.ic_video_back'))
            .width(24)
            .height(28)
            .objectFit(ImageFit.Contain)
            .padding({
              left: $r('app.float.space_sm'),
              right: $r('app.float.space_sm')
            })
            .onClick((): void => {
              this.interact();
              this.onBack();
            })
          Column({ space: 2 }) {
            Text(this.topTitle())
              .fontSize($r('app.float.font_size_body'))
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.partTitle())
              .fontSize($r('app.float.font_size_caption'))
              .fontColor('rgba(255,255,255,0.70)')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          // 投屏入口（→  接线）：唤起投屏面板（Player 页 bindSheet 承载 CastPanel）
          Text('投屏')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(this.castVm.casting ? $r('app.color.brand') : Color.White)
            .padding({
              left: $r('app.float.space_sm'),
              right: $r('app.float.space_sm'),
              top: $r('app.float.space_xs'),
              bottom: $r('app.float.space_xs')
            })
            .onClick((): void => {
              this.interact();
              this.castVm.openPanel();
            })
          // 设置入口（全屏页面 → 统一设置面板；半屏隐藏以免入口留空）
          // 锁定入口已移至全屏页右侧垂直居中锁按钮（复刻安卓 lock_screen，R8）
          if (this.fullscreen) {
            Image($r('app.media.ic_settings_white'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .padding($r('app.float.space_xs'))
              .onClick((): void => {
                this.interact();
                this.onOpenSettings();
              })
            // 标题栏时间+电量（复刻安卓 danmu_video_land 14sp 白字最右）：
            // 控制层每次唤出（本控件重建）刷新一次，对齐安卓行为
            Text(this.titleClock)
              .fontSize(14)
              .fontColor(Color.White)
            Text(this.titleBattery)
              .fontSize(14)
              .fontColor(Color.White)
          }
        }
        .width('100%')
        .padding({
          left: this.avoidSideVp() > 0 ? this.avoidSideVp() : $r('app.float.space_sm'),
          right: $r('app.float.space_md'),
          top: this.avoidTopVp() > 0 ? this.avoidTopVp() : $r('app.float.space_sm')
        })

        // 空白条点击 = 隐藏控制层（不挂在主体 Column 上，避免按钮点击冒泡连带切换）
        Blank()
          .onClick((): void => {
            this.onToggleControls();
          })

        // 中央播放/暂停（使用安卓版 icon）
        Image(this.isPlaying() ? $r('app.media.ic_video_pause') : $r('app.media.ic_video_play'))
          .width(52)
          .height(52)
          .objectFit(ImageFit.Contain)
          .padding(12)
          .backgroundColor('rgba(0,0,0,0.35)')
          .borderRadius(32)
          .onClick((): void => {
            this.interact();
            this.vm.togglePlay();
          })

        Blank()
          .onClick((): void => {
            this.onToggleControls();
          })

        if (this.castVm.casting) {
          // 投播中：远端迷你控制条替代本机控制
          CastControlBar({
            vm: this.castVm,
            onInteraction: (): void => {
              this.interact();
            }
          })
            .width('100%')
            .padding({
              left: this.avoidSideVp() > 0 ? this.avoidSideVp() : $r('app.float.space_md'),
              right: $r('app.float.space_md'),
              bottom: this.avoidBottomVp() > 0 ? this.avoidBottomVp() : $r('app.float.space_sm')
            })
        } else {
          // 底部：时间 + 滑杆 + 按钮组（弹幕输入合入按钮行，不再单独一行）
          Column({ space: $r('app.float.space_sm') }) {
            Row({ space: $r('app.float.space_sm') }) {
              Text(VideoDetailVM.formatClock(this.vm.currentMs))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(Color.White)
              MediaSlider({
                value: this.vm.currentMs,
                maxValue: this.vm.totalMs,
                onSeek: (ms: number): void => {
                  this.vm.seekTo(ms);
                },
                onInteraction: (): void => {
                  this.interact();
                }
              })
                .layoutWeight(1)
              Text(VideoDetailVM.formatClock(this.vm.totalMs))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(Color.White)
            }
            .width('100%')

            Row({ space: $r('app.float.space_lg') }) {
              Image(this.isPlaying() ? $r('app.media.ic_video_pause') : $r('app.media.ic_video_play'))
                .width(26)
                .height(26)
                .objectFit(ImageFit.Contain)
                .onClick((): void => {
                  this.interact();
                  this.vm.togglePlay();
                })
              Text('-10s')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(Color.White)
                .onClick((): void => {
                  this.interact();
                  this.vm.skipBy(-10000);
                })
              Text('+90s')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(Color.White)
                .onClick((): void => {
                  this.interact();
                  this.vm.skipBy(90000);
                })
              // 下一集（多分集显示）
              if (this.vm.video !== null && !this.vm.video.isSinglePart) {
                Text('下集')
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor(Color.White)
                  .onClick((): void => {
                    this.interact();
                    this.vm.playNextPart();
                  })
              }
              // 倍速菜单
              Text(SpeedTable.labelOf(this.vm.speed))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(this.vm.speed === 1.0 ? Color.White : $r('app.color.brand'))
                .bindMenu(this.buildSpeedMenu())
              // 画面缩放（仅全屏形态显示）
              if (this.fullscreen) {
                Text(ScaleTable.labelOf(this.vm.scaleMode))
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor(this.vm.scaleMode === 'fit' ? Color.White : $r('app.color.brand'))
                  .bindMenu(this.buildScaleMenu())
              }
              // 清晰度（仅 playurl 分集显示）
              if (this.vm.qualities.length > 0) {
                Text(this.vm.currentQualitySrc.length > 0
                  ? QualityTable.labelOf(this.vm.currentQualitySrc) : '画质')
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor(this.vm.currentQualitySrc.length > 0 ? $r('app.color.brand') : Color.White)
                  .bindMenu(this.buildQualityMenu())
              }
              // 弹幕快捷开关（对齐安卓：显示开/关状态，点击切换）
              Text(this.danmakuVm.danmakuOn ? '弹幕开' : '弹幕关')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(this.danmakuVm.danmakuOn ? Color.White : 'rgba(255,255,255,0.40)')
                .onClick((): void => {
                  this.interact();
                  this.danmakuVm.danmakuOn = !this.danmakuVm.danmakuOn;
                })
              // 弹幕输入+发送（合入操作栏，仅全屏）：发送后本地立即回显
              if (this.fullscreen) {
                TextInput({ placeholder: '发个弹幕见证当下', text: this.danmakuInput })
                  .layoutWeight(1)
                  .height(36)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor(Color.White)
                  .placeholderColor('rgba(255,255,255,0.60)')
                  .placeholderFont({ size: $r('app.float.font_size_caption') })
                  .backgroundColor('rgba(255,255,255,0.16)')
                  .borderRadius(18)
                  .padding({ left: $r('app.float.space_md'), right: $r('app.float.space_md') })
                  .onChange((value: string): void => {
                    this.danmakuInput = value;
                    this.interact();
                  })
                  .onSubmit((): void => {
                    this.doSendDanmu();
                  })
                Text('发送')
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.brand'))
                  .padding({
                    left: $r('app.float.space_sm'),
                    right: $r('app.float.space_sm'),
                    top: $r('app.float.space_xs'),
                    bottom: $r('app.float.space_xs')
                  })
                  .onClick((): void => {
                    this.doSendDanmu();
                  })
              } else {
                Blank()
              }
              // 选集（多分集显示）
              if (this.vm.video !== null && !this.vm.video.isSinglePart) {
                Text('选集')
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor(Color.White)
                  .onClick((): void => {
                    this.interact();
                    this.onOpenParts();
                  })
              }
              // 全屏切换（使用安卓版 icon）
              Image(this.fullscreen ? $r('app.media.ic_video_exit_fullscreen') : $r('app.media.ic_video_fullscreen'))
                .width(24)
                .height(24)
                .objectFit(ImageFit.Contain)
                .onClick((): void => {
                  this.interact();
                  this.onToggleFullscreen();
                })
            }
            .width('100%')
            .padding({
              left: $r('app.float.space_md'),
              right: $r('app.float.space_md')
            })
          }
          .width('100%')
          .padding({
            bottom: this.avoidBottomVp() > 0 ? this.avoidBottomVp() : $r('app.float.space_sm'),
            left: this.avoidSideVp(),
            right: this.avoidSideVp()
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    // 竖向滑动（亮度/音量）：控制层可见时由本层识别并转发；
    // 各按钮为 onClick（点击链），与 Pan 手势链独立，不受影响
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Vertical })
        .onActionStart((event: GestureEvent): void => {
          this.onVerticalPanStart(event);
        })
        .onActionUpdate((event: GestureEvent): void => {
          this.onVerticalPanUpdate(event);
        })
        .onActionEnd((): void => {
          this.onVerticalPanEnd();
        })
        .onActionCancel((): void => {
          this.onVerticalPanEnd();
        })
    )
    // 显式空材质（视频上方不做高斯模糊，规避额外功耗）
    .systemMaterial(uiMaterial.Material.empty)
    //  键盘快捷键（仅全屏形态注册；半屏方向键保留给列表滚动）
    .focusable(this.fullscreen)
    .defaultFocus(this.fullscreen)
    // 方向键（DPAD）经 onKeyEvent 处理
    .onKeyEvent((event: KeyEvent): void => {
      if (event.type !== KeyType.Down || !this.fullscreen) {
        return;
      }
      if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT) {
        this.vm.skipBy(-10000);
      } else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
        this.vm.skipBy(10000);
      } else if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
        this.stepVolume(0.1);
      } else if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
        this.stepVolume(-0.1);
      }
    })
    // 空格 = 播放/暂停
    .keyboardShortcut(' ', [], (): void => {
      this.vm.togglePlay();
    })
    // Esc = 退出全屏（全屏形态）
    .keyboardShortcut(FunctionKey.ESC, [], (): void => {
      if (this.fullscreen) {
        this.onToggleFullscreen();
      }
    })
  }

  /** 当前分集标题（空标题兜底「第N集」，统一） */
  private partTitle(): string {
    const video = this.vm.video;
    if (video === null || video.isSinglePart) {
      return '';
    }
    const part = video.parts[this.vm.partIndex];
    if (part === undefined) {
      return '';
    }
    return part.title.length > 0 ? part.title : `第${this.vm.partIndex + 1}集`;
  }

  /** 顶栏标题（全屏多分集时拼接集数，看标题即知当前集） */
  private topTitle(): string {
    const video = this.vm.video;
    if (video === null) {
      return '';
    }
    if (this.fullscreen && !video.isSinglePart) {
      return `${video.title} · 第${this.vm.partIndex + 1}/${video.parts.length}集`;
    }
    return video.title;
  }

  /** 倍速菜单 */
  @Builder
  private buildSpeedMenu() {
    Menu() {
      ForEach(SpeedTable.ALL, (rate: number) => {
        MenuItem({
          content: SpeedTable.labelOf(rate)
        })
          .selected(this.vm.speed === rate)
          .selectIcon(true)
          .onClick((): void => {
            this.vm.setSpeed(rate);
          })
      }, (rate: number): string => `speed-${rate}`)
    }
  }

  /** 清晰度菜单 */
  @Builder
  private buildQualityMenu() {
    Menu() {
      ForEach(this.vm.qualities, (option: QualityOption) => {
        MenuItem({
          content: option.label
        })
          .selected(this.vm.currentQualitySrc === option.src)
          .selectIcon(true)
          .onClick((): void => {
            this.vm.setQuality(option.src);
          })
      }, (option: QualityOption): string => `quality-${option.src}`)
    }
  }

  /** 画面缩放菜单（原比例/16:9/4:3/撑满） */
  @Builder
  private buildScaleMenu() {
    Menu() {
      ForEach(ScaleTable.ALL, (option: ScaleModeOption) => {
        MenuItem({
          content: option.label
        })
          .selected(this.vm.scaleMode === option.mode)
          .selectIcon(true)
          .onClick((): void => {
            this.vm.setScaleMode(option.mode);
          })
      }, (option: ScaleModeOption): string => `scale-${option.mode}`)
    }
  }
}

/**
 * 记忆续播提示条（wiring：详情页/全屏页共用）
 * - 显示"上次看到 xx:xx"，点击续播，右侧关闭
 */
@ComponentV2
export struct ResumeTipBar {
  @Param vm: VideoDetailVM = VideoDetailVM.shared();

  build() {
    if (this.vm.resumeTipVisible) {
      Row({ space: $r('app.float.space_sm') }) {
        Text(`上次看到 ${this.vm.resumeTipText}`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(Color.White)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('续播')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.brand'))
          .padding({ left: $r('app.float.space_sm'), right: $r('app.float.space_sm') })
          .onClick((): void => {
            this.vm.resumeFromTip();
          })
        Text('✕')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor('rgba(255,255,255,0.70)')
          .onClick((): void => {
            this.vm.resumeTipVisible = false;
          })
      }
      .width('100%')
      .backgroundColor('rgba(0,0,0,0.60)')
      .padding({
        left: $r('app.float.space_md'),
        right: $r('app.float.space_md'),
        top: $r('app.float.space_sm'),
        bottom: $r('app.float.space_sm')
      })
    }
  }
}

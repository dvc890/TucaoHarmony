/**
 * 弹幕设置抽屉
 *
 * bindSheet 半模态设置面板（对齐安卓 SettingDanmuViewFactory + 屏蔽词页签）：
 * - 显示弹幕总开关
 * - 不透明度（20%~100%）/ 字号倍率（0.50x~2.00x）/ 滚动速度（0.30x~2.00x）Slider，即时生效
 * - 关键词屏蔽：总开关 + 屏蔽词列表（增删；默认 http，对齐安卓 BlockListHelpers）
 * - 池状态提示：加载失败 / 暂无弹幕
 *
 *  接线说明：
 * - 本组件为"锚点 + Sheet"一体结构，自身不占布局（100% 透明层，HitTestMode.None），
 *   仅需在一处挂载（建议 VideoDetail.ets 页根 Stack 内）；
 * - Player 全屏页设置入口直接调用 DanmakuVM.shared().openSettings()，
 *   Sheet 以窗口层级弹出，跨页生效；
 * - 设置入口按钮建议放 PlayerControlView 清晰度菜单旁。
 */
import { DanmakuVM } from '../../viewmodel/DanmakuVM';

@ComponentV2
export struct DanmakuSettingsDrawer {
  @Param vm: DanmakuVM = DanmakuVM.shared();
  @Local isPresented: boolean = false;
  @Local newWord: string = '';

  @Monitor('vm.settingsOpen')
  onSettingsOpenChanged(): void {
    this.isPresented = this.vm.settingsOpen;
  }

  build() {
    Stack() {
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .bindSheet(this.isPresented, this.sheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      onDisappear: (): void => {
        this.vm.closeSettings();
      },
      shouldDismiss: (sheetDismiss: SheetDismiss) => {
        sheetDismiss.dismiss();
      }
    })
  }

  @Builder
  sheetBuilder() {
    Column({ space: $r('app.float.space_md') }) {
      Text('弹幕设置')
        .fontSize($r('app.float.font_size_title'))
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Bold)

      // 显示弹幕总开关
      Row() {
        Text('显示弹幕')
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.vm.danmakuOn })
          .onChange((isOn: boolean) => {
            this.vm.danmakuOn = isOn;
          })
      }
      .width('100%')

      // 池状态提示
      if (this.vm.poolError.length > 0) {
        Text(this.vm.poolError)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
      } else if (this.vm.poolEmpty) {
        Text('暂无弹幕，发送一条开启气氛吧')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
      }

      // 不透明度
      Column({ space: $r('app.float.space_xs') }) {
        Row() {
          Text('不透明度')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(`${Math.round(this.vm.danmakuOpacity * 100)}%`)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        Slider({
          value: this.vm.danmakuOpacity,
          min: 0.2,
          max: 1.0,
          step: 0.05,
          style: SliderStyle.OutSet
        })
          .selectedColor($r('app.color.brand'))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.vm.danmakuOpacity = value;
          })
      }
      .width('100%')

      // 字号倍率
      Column({ space: $r('app.float.space_xs') }) {
        Row() {
          Text('字号倍率')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(`${this.vm.danmakuScale.toFixed(2)}x`)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        Slider({
          value: this.vm.danmakuScale,
          min: 0.5,
          max: 2.0,
          step: 0.05,
          style: SliderStyle.OutSet
        })
          .selectedColor($r('app.color.brand'))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.vm.danmakuScale = value;
          })
      }
      .width('100%')

      // 滚动速度
      Column({ space: $r('app.float.space_xs') }) {
        Row() {
          Text('滚动速度')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(`${this.vm.danmakuSpeed.toFixed(2)}x`)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        Slider({
          value: this.vm.danmakuSpeed,
          min: 0.3,
          max: 2.0,
          step: 0.05,
          style: SliderStyle.OutSet
        })
          .selectedColor($r('app.color.brand'))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.vm.danmakuSpeed = value;
          })
      }
      .width('100%')

      // 关键词屏蔽总开关
      Row() {
        Text('关键词屏蔽')
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.vm.blockEnable })
          .onChange((isOn: boolean) => {
            this.vm.blockEnable = isOn;
          })
      }
      .width('100%')

      // 屏蔽词添加
      Row({ space: $r('app.float.space_sm') }) {
        TextInput({ placeholder: '输入屏蔽词', text: this.newWord })
          .layoutWeight(1)
          .onChange((value: string) => {
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
          .onClick(() => {
            this.vm.addBlockWord(this.newWord);
            this.newWord = '';
          })
      }
      .width('100%')

      // 屏蔽词列表
      if (this.vm.blockWords.length === 0) {
        Text('暂无屏蔽词，可添加 http 屏蔽广告弹幕')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
      } else {
        ForEach(this.vm.blockWords, (word: string) => {
          Row() {
            Text(word)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Text('删除')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.brand'))
              .onClick(() => {
                this.vm.removeBlockWord(word);
              })
          }
          .width('100%')
          .padding({
            top: $r('app.float.space_xs'),
            bottom: $r('app.float.space_xs')
          })
        }, (word: string) => word)
      }
    }
    .padding($r('app.float.space_lg'))
    .width('100%')
  }
}

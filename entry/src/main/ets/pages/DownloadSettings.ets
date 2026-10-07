/**
 * 缓存设置页（布局重排为分组卡片）
 * - 分组卡片结构（对齐 Settings 新页/我的页行样式，保持全应用一致性）：
 *   「缓存目录」组：目录展示（自选 label+uri / 应用默认沙箱 download）+ 操作行
 *     （更改目录 / 恢复默认目录，仅自选目录时显示）
 *   「说明」组：目录变更影响/授权/空间建议三条文案
 * - 更改目录：canIUse 预检 → DocumentViewPicker(FOLDER) → fileShare.persistPermission
 *   → DownloadDirStore 保存（引擎 resolveBaseDir 每次现取，新任务即时生效）
 * - 恢复默认：revokePermission（失败忽略，可能是应用重装后授权已失效）→ 清空设置
 * - 平板两列布局：SM 手机保持单列全宽（零变化）；MD+ 缓存目录|说明 两列并排，
 *   内容区限宽 840 居中（CenteredShell，SM/MD 全宽零退化；自绘标题栏保持全宽）
 * - 路由：router_map.json → DownloadSettingsBuilder（无参数；Router.goDownloadSettings()）
 */
import { picker, fileShare, fileUri } from '@kit.CoreFileKit';
import { AppContextHolder, GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { DownloadDirStore, DownloadDirSetting } from '../model/entity/DownloadEntities';
import { Router } from '../common/Router';
import { CenteredShell } from '../components/CenteredShell';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function DownloadSettingsBuilder(name: string, param: Object) {
  DownloadSettings()
}

/** 目录操作行（分组卡片内行样式，对齐 Settings 页 SettingsRow） */
@ComponentV2
struct DirActionRow {
  @Param label: string = '';
  @Event onTap: () => void = (): void => {};

  build() {
    Row({ space: $r('app.float.space_md') }) {
      Text(this.label)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text('›')
        .fontSize(20)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(48)
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md')
    })
    .onClick(() => {
      this.onTap();
    })
  }
}

@ComponentV2
struct DownloadSettings {
  /** 目录设置（@ObservedV2，@Trace uri/label 驱动刷新） */
  @Local setting: DownloadDirSetting = DownloadDirStore.get();
  /** 窗口断点（SM 单列 / MD+ 两列） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  // ==================== 分组 Builder（SM 单列 / MD+ 两列共用） ====================

  /** 缓存目录组：目录展示 + 更改/恢复操作行 */
  @Builder
  private dirGroup() {
    Column({ space: $r('app.float.space_md') }) {
      Text('缓存目录')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: $r('app.float.space_md') })

      Column() {
        // 目录展示区
        Column({ space: $r('app.float.space_xs') }) {
          if (this.setting.isCustom()) {
            Text(this.setting.label.length > 0 ? this.setting.label : '自选目录')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.brand'))
              .width('100%')
            Text(this.setting.uri)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          } else {
            Text('应用默认目录')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.brand'))
              .width('100%')
            Text('视频与弹幕保存在应用沙箱 download 目录，卸载应用后将被清除')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
        }
        .width('100%')
        .padding({
          left: $r('app.float.space_md'),
          right: $r('app.float.space_md'),
          top: $r('app.float.space_md'),
          bottom: $r('app.float.space_md')
        })
        .alignItems(HorizontalAlign.Start)

        Divider()
          .color($r('app.color.divider'))
          .width('100%')

        // 操作行
        DirActionRow({
          label: '更改目录',
          onTap: (): void => {
            this.changeFolder();
          }
        })
        if (this.setting.isCustom()) {
          Divider()
            .color($r('app.color.divider'))
            .width('100%')
          DirActionRow({
            label: '恢复默认目录',
            onTap: (): void => {
              this.resetFolder();
            }
          })
        }
      }
      .width('100%')
      .borderRadius($r('app.float.radius_card'))
      .backgroundColor($r('app.color.card_background'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 说明组：目录变更影响/授权/空间建议三条文案 */
  @Builder
  private noteGroup() {
    Column({ space: $r('app.float.space_md') }) {
      Text('说明')
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: $r('app.float.space_md') })

      Column({ space: $r('app.float.space_xs') }) {
        Text('· 更改目录仅影响之后的新任务，已缓存内容仍保留在原目录')
        Text('· 自选目录需要授权，授权后应用可在重启后继续写入')
        Text('· 建议选择剩余空间充足的目录，单集视频通常占用数十至数百 MB')
      }
      .width('100%')
      .padding($r('app.float.space_md'))
      .borderRadius($r('app.float.radius_card'))
      .backgroundColor($r('app.color.card_background'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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
          Text('缓存设置')
            .fontSize($r('app.float.font_size_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_sm'),
          top: $r('app.float.space_sm'),
          bottom: $r('app.float.space_sm')
        })
        // 全局沉浸：topbar 底色仅扩展绘制延伸到状态栏下（不改布局，内容绝对位置不变）
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

        Scroll() {
          // LG/XL 内容限宽 840 居中（SM/MD 全宽，零退化）
          CenteredShell({ maxWidth: 840 }) {
            if (this.windowSize.isCompact()) {
              // ===== SM：单列全宽（保持现状） =====
              Column({ space: $r('app.float.space_md') }) {
                this.dirGroup()
                this.noteGroup()
              }
              .width('100%')
              .padding({
                left: $r('app.float.space_md'),
                right: $r('app.float.space_md'),
                top: $r('app.float.space_sm'),
                bottom: $r('app.float.space_lg')
              })
              .alignItems(HorizontalAlign.Start)
            } else {
              // ===== MD+：两列分组卡片（缓存目录 | 说明），提高平板屏幕利用率 =====
              Column() {
                Row({ space: $r('app.float.space_md') }) {
                  Column() {
                    this.dirGroup()
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Column() {
                    this.noteGroup()
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }
              .width('100%')
              .padding({
                left: $r('app.float.space_md'),
                right: $r('app.float.space_md'),
                top: $r('app.float.space_sm'),
                bottom: $r('app.float.space_lg')
              })
              .alignItems(HorizontalAlign.Start)
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_background'))
  }

  // ==================== 目录操作 ====================

  /** 更改目录：目录选择器 → 持久授权 → 保存设置 */
  private async changeFolder(): Promise<void> {
    if (!canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
      this.toast('当前设备不支持选择目录');
      return;
    }
    const context = AppContextHolder.get();
    if (context === null) {
      this.toast('应用尚未就绪，请稍后重试');
      return;
    }
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      options.maxSelectNumber = 1;
      const uris: Array<string> = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      // 持久化读写授权（用户已通过选择器临时授权，此处转为永久）
      const policy: fileShare.PolicyInfo = {
        uri: uri,
        operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
      };
      await fileShare.persistPermission([policy]);
      const picked: fileUri.FileUri = new fileUri.FileUri(uri);
      this.setting.uri = uri;
      this.setting.label = picked.name;
      DownloadDirStore.save();
      this.toast('缓存目录已更新');
    } catch (err) {
      this.toast('未能获取目录的写入权限');
    }
  }

  /** 恢复默认：撤回授权（失败忽略）→ 清空设置 */
  private async resetFolder(): Promise<void> {
    const oldUri: string = this.setting.uri;
    if (oldUri.length > 0) {
      try {
        const policy: fileShare.PolicyInfo = {
          uri: oldUri,
          operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
        };
        await fileShare.revokePermission([policy]);
      } catch (err) {
        // 授权可能已失效（应用重装等），忽略
      }
    }
    this.setting.uri = '';
    this.setting.label = '';
    DownloadDirStore.save();
    this.toast('已恢复默认目录');
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }
}

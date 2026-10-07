/**
 * 简介视图（详情页"简介"Tab）
 * - 头部：封面缩略 + 发布时间 + 播放/弹幕数 + UP 主（点击跳转个人页）；
 *   视频标题由页面级 DetailHeader 呈现（hero 转场标题锚点，不在本视图）
 * - 简介：默认 2 行折叠，点击展开（LayoutAnimation 免配置）
 * - 分集列表：当前分集高亮、已看置灰、"已下载"角标、下载中/失败态提示；点击切集
 * - 收藏开关：本地 star.json 持久化（纯本地，toggle 后 EventBus 通知收藏页刷新）
 * - 缓存入口：bindSheet 承载 DownloadSheet 分集选择面板（接线）
 * - 评论 Tab 容器由页面持有（接入 CommentsView）
 */
import { Video, Part, DownloadStatus } from '../../model/entity/BaseEntities';
import { VideoDetailVM } from '../../viewmodel/VideoDetailVM';
import { RelativeTime } from '../../components/RelativeTimeText';
import { NetworkImage } from '../../components/NetworkImage';
import { PlayCountText } from '../home/VideoCardView';
import { DownloadSheet } from './DownloadSheet';
import { Router } from '../../common/Router';
import { GlobalState, WidthBreakpoint } from '../../common/GlobalState';
import { KnockShareController } from '../../service/share/KnockShareController';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

@ComponentV2
export struct InfoView {
  @Param vm: VideoDetailVM = VideoDetailVM.shared();
  /** 简介 展开/折叠 */
  @Local descExpanded: boolean = false;
  /** 缓存分集选择面板可见性（bindSheet 承载 DownloadSheet） */
  @Local downloadSheetVisible: boolean = false;

  /** 分集网格列数：手机3 / 中屏4 / 平板6 */
  private episodeColumns(): number {
    const bp: WidthBreakpoint = GlobalState.windowSizeInfo().breakpoint;
    if (bp === WidthBreakpoint.XL || bp === WidthBreakpoint.LG) return 6;
    if (bp === WidthBreakpoint.MD) return 4;
    return 3;
  }

  /** 将 parts 按列数拆成行，末行用空位（null）补齐，保证每行列数恒定、列对齐 */
  private partRowCells(): (Part | null)[][] {
    const cols: number = this.episodeColumns();
    const parts: Part[] = this.vm.video !== null ? this.vm.video.parts : [];
    const rows: (Part | null)[][] = [];
    for (let i = 0; i < parts.length; i += cols) {
      const row: (Part | null)[] = [];
      for (let j = 0; j < cols; j++) {
        row.push(i + j < parts.length ? parts[i + j] : null);
      }
      rows.push(row);
    }
    return rows;
  }

  /** 分集全局序号（行内 layout 项用） */
  private partIndex(part: Part): number {
    if (this.vm.video === null) {
      return 0;
    }
    return this.vm.video.parts.indexOf(part);
  }

  private partFlagText(part: Part): string {
    if (part.flag === DownloadStatus.COMPLETED) {
      return '已缓存';
    }
    if (part.flag === DownloadStatus.DOWNLOADING || part.flag === DownloadStatus.CONNECTING
      || part.flag === DownloadStatus.OBTAIN_URL) {
      return '缓存中';
    }
    if (part.flag === DownloadStatus.PAUSED) {
      return '已暂停';
    }
    if (part.flag === DownloadStatus.FAILED) {
      return '缓存失败';
    }
    return '';
  }

  /** 拉系统分享面板（面板华为分享推荐设备 /  复制链接等通道）；
   *  与碰一碰共用同一份 HYPERLINK 分享数据（KnockShareController.buildShareData） */
  private shareVideo(): void {
    const video: Video | null = this.vm.video;
    if (video === null) {
      return;
    }
    const uiContext: UIContext = this.getUIContext();
    if (!KnockShareController.isPanelSupported()) {
      // 无 Share Kit 环境优雅降级：toast 提示，不崩溃
      uiContext.getPromptAction().showToast({ message: '当前设备不支持分享' });
      return;
    }
    const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
    KnockShareController.getInstance().showSharePanel(context, video, 'info_share_btn')
      .then((): void => {
        hilog.info(0x0000, 'InfoView', 'share panel shown');
      })
      .catch((error: BusinessError): void => {
        hilog.error(0x0000, 'InfoView', `share panel failed: ${error.code} ${error.message}`);
        uiContext.getPromptAction().showToast({ message: '分享面板拉起失败' });
      });
  }

  build() {
    Scroll() {
      Column() {
        // ===== 头部信息 =====
        Row({ space: $r('app.float.space_md') }) {
          NetworkImage({
            url: this.vm.video !== null ? this.vm.video.thumb : '',
            imageWidth: 120,
            imageHeight: 75,
            radius: 8
          })
          Column({ space: $r('app.float.space_xs') }) {
            Text(this.vm.video !== null
              ? RelativeTime.formatPublishDate(this.vm.video.create) : '')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
            Row({ space: $r('app.float.space_sm') }) {
              Text(`播放 ${PlayCountText.format(this.vm.video !== null ? this.vm.video.play : 0)}`)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_secondary'))
              Text(`弹幕 ${PlayCountText.format(this.vm.video !== null ? this.vm.video.mukio : 0)}`)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_secondary'))
            }
            // UP 主（跳转个人页）
            Text(this.vm.video !== null ? `UP主：${this.vm.video.user}` : '')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.brand'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick((): void => {
                if (this.vm.video !== null && this.vm.video.userid.length > 0) {
                  Router.goUploader(this.vm.video.userid);
                }
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        // ===== 简介（折叠/展开） =====
        if (this.vm.video !== null && this.vm.video.description.length > 0) {
          Column({ space: $r('app.float.space_xs') }) {
            Text(this.vm.video.description)
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_secondary'))
              .maxLines(this.descExpanded ? 20 : 2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick((): void => {
                this.descExpanded = !this.descExpanded;
              })
            Text(this.descExpanded ? '收起 ▴' : '展开 ▾')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.brand'))
              .alignSelf(ItemAlign.Start)
              .onClick((): void => {
                this.descExpanded = !this.descExpanded;
              })
          }
          .width('100%')
          .margin({ top: $r('app.float.space_md') })
        }

        // ===== 操作条：收藏 / 缓存 =====
        Row({ space: $r('app.float.space_lg') }) {
          Row({ space: $r('app.float.space_xs') }) {
            Text(this.vm.starred ? '★' : '☆')
              .fontSize($r('app.float.font_size_body'))
              .fontColor(this.vm.starred ? $r('app.color.brand') : $r('app.color.text_secondary'))
            Text('收藏')
              .fontSize($r('app.float.font_size_body'))
              .fontColor(this.vm.starred ? $r('app.color.brand') : $r('app.color.text_secondary'))
          }
          .onClick((): void => {
            this.vm.toggleStar();
            this.getUIContext().getPromptAction()
              .showToast({ message: this.vm.starred ? '已收藏' : '已取消收藏' });
          })

          // 离线缓存入口（接线）：bindSheet 承载 DownloadSheet 分集选择面板
          Row({ space: $r('app.float.space_xs') }) {
            Text('⤓')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_secondary'))
            Text('缓存')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_secondary'))
          }
          .onClick((): void => {
            if (this.vm.video !== null) {
              this.downloadSheetVisible = true;
            }
          })
          .bindSheet(this.downloadSheetVisible, this.downloadSheetBuilder(), {
            detents: ['75%'],
            dragBar: true,
            showClose: false,
            onDisappear: (): void => {
              this.downloadSheetVisible = false;
            },
            shouldDismiss: (sheetDismiss: SheetDismiss) => {
              sheetDismiss.dismiss();
            }
          })

          // 分享入口（碰一碰 / 降级通道）：拉系统分享面板，面板内可走华为分享
          // 推荐设备/ 复制链接等任意通道；id 供大屏面板锚点定位
          Row({ space: $r('app.float.space_xs') }) {
            Text('⤒')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_secondary'))
            Text('分享')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_secondary'))
          }
          .id('info_share_btn')
          .onClick((): void => {
            this.shareVideo();
          })
        }
        .width('100%')
        .margin({ top: $r('app.float.space_md') })

// ===== 分集列表（固定列数网格，手机3/中屏4/平板6，等宽胶囊列对齐） =====
          if (this.vm.video !== null && !this.vm.video.isSinglePart) {
            Text('分集列表')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_primary'))
              .margin({ top: $r('app.float.space_lg'), bottom: $r('app.float.space_sm') })
              .alignSelf(ItemAlign.Start)
            Column({ space: $r('app.float.space_sm') }) {
              ForEach(this.partRowCells(), (row: (Part | null)[]) => {
                Row({ space: $r('app.float.space_sm') }) {
                  ForEach(row, (part: Part | null, cellIndex: number) => {
                    if (part === null) {
                      // 末行占位格：保持列宽恒定，避免末行拉伸错列
                      Row()
                        .layoutWeight(1)
                        .height(40)
                    } else {
                      // 胶囊角标化（R9）：标题居中独占（Ellipsis 生效防溢出），
                      // 已看=右上小标，缓存状态=右下小角标（已缓存=✓），互不挤占
                      Stack() {
                        // 标题层：居中横贯，长标题省略
                        Stack({ alignContent: Alignment.Center }) {
                          Text(part.title.length > 0 ? part.title : `第${this.partIndex(part) + 1}集`)
                            .fontSize($r('app.float.font_size_body'))
                            .fontColor(this.vm.partIndex === this.partIndex(part) ? $r('app.color.brand')
                              : (part.hadPlay ? $r('app.color.text_tertiary') : $r('app.color.text_primary')))
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .padding({
                              left: $r('app.float.space_sm'),
                              right: $r('app.float.space_sm')
                            })
                        }
                        .width('100%')
                        .height('100%')

                        // 已看角标：右上小标
                        Stack({ alignContent: Alignment.TopEnd }) {
                          if (part.hadPlay) {
                            Text('已看')
                              .fontSize($r('app.float.font_size_caption'))
                              .fontColor($r('app.color.text_tertiary'))
                              .margin(3)
                          }
                        }
                        .width('100%')
                        .height('100%')

                        // 缓存角标（catalog 合并态）：右下；已缓存=✓ 小勾，其余状态保留小字
                        Stack({ alignContent: Alignment.BottomEnd }) {
                          if (this.partFlagText(part).length > 0) {
                            Text(part.flag === DownloadStatus.COMPLETED ? '✓' : this.partFlagText(part))
                              .fontSize($r('app.float.font_size_caption'))
                              .fontColor(part.flag === DownloadStatus.COMPLETED
                                ? $r('app.color.brand') : $r('app.color.text_tertiary'))
                              .maxLines(1)
                              .margin(3)
                          }
                        }
                        .width('100%')
                        .height('100%')
                      }
                      .layoutWeight(1)
                      .height(40)
                      .borderRadius(12)
                      .backgroundColor(this.vm.partIndex === this.partIndex(part) ? $r('app.color.brand_surface')
                        : Color.Transparent)
                      .border({
                        width: 1,
                        color: this.vm.partIndex === this.partIndex(part)
                          ? $r('app.color.brand') : $r('app.color.divider')
                      })
                      .onClick((): void => {
                        this.vm.switchPart(this.partIndex(part));
                      })
                    }
                  }, (part: Part | null, cellIndex: number): string => `${cellIndex}`)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
              }, (row: (Part | null)[]): string => `${row[0] === null ? 'pad' : row[0].vid}`)
            }
            .width('100%')
          }
      }
      .width('100%')
      .padding($r('app.float.space_md'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.TopStart)
  }

  /** 缓存分集选择面板（DownloadSheet 自带标题与关闭） */
  @Builder
  downloadSheetBuilder() {
    DownloadSheet({
      vm: this.vm,
      onClose: (): void => {
        this.downloadSheetVisible = false;
      }
    })
  }
}

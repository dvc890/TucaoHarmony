/**
 * 下载管理页（大屏 UX 适配）
 * - 双 Tab：下载中（进度/摘要 + 分集明细展开：暂停/继续/重试/删除）/ 已下载（点击进离线播放）
 * - 删除：手机左滑（swipeAction）；大屏右键 + 手机长按（bindContextMenu 链式）；确认弹窗
 * - 多选：长按菜单进入；底部操作栏批量删除
 * - 全部暂停：下载中 Tab 顶栏入口
 * - 空态：EmptyView
 * - 不网格化（管理列表含进度/操作按钮，卡片化劣化操作密度）；
 *   LG/XL 列表区限宽 840 居中（标题栏/Tab 栏/底部操作栏保持全宽）
 * - 路由：router_map.json → DownloadBuilder（无参数；Router.goDownload()）
 */
import { Video, Part, DownloadStatus } from '../model/entity/BaseEntities';
import { DownloadVM, DownloadPartStatus } from '../viewmodel/DownloadVM';
import { DownloadEngine } from '../service/download/DownloadEngine';
import { GlobalState, WindowSizeInfo } from '../common/GlobalState';
import { ContentWidth } from '../common/BreakpointLayout';
import { EmptyView } from '../components/EmptyView';
import { NetworkImage } from '../components/NetworkImage';
import { Router } from '../common/Router';

/** 路由 builder（router_map.json 注册用） */
@Builder
export function DownloadBuilder(name: string, param: Object) {
  Download()
}

@ComponentV2
struct Download {
  @Local vm: DownloadVM = DownloadVM.shared();
  /** 当前 Tab（0=下载中 1=已下载） */
  @Local currentTab: number = 0;
  /** 展开分集明细的 hid（空=无） */
  @Local expandedHid: string = '';
  /** 窗口断点（LG/XL 列表区限宽居中） */
  private windowSize: WindowSizeInfo = GlobalState.windowSizeInfo();

  aboutToDisappear(): void {
    this.vm.resetOnLeave();
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（中性底，双分支文字同主文字色） =====
        Row({ space: $r('app.float.space_sm') }) {
          if (this.vm.selectMode) {
            Text('取消')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_primary'))
              .padding($r('app.float.space_sm'))
              .onClick((): void => {
                this.vm.exitSelect();
              })
            Text(`已选 ${this.vm.selectedHids.length} 部`)
              .fontSize($r('app.float.font_size_title'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
          } else {
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
            Text('离线缓存')
              .fontSize($r('app.float.font_size_title'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            if (this.currentTab === 0 && this.vm.downloadingList.length > 0) {
              Text('全部暂停')
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.text_primary'))
                .padding($r('app.float.space_sm'))
                .onClick((): void => {
                  this.vm.pauseAll();
                  this.getUIContext().getPromptAction().showToast({ message: '已暂停全部任务' });
                })
            }
            Text('设置')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_primary'))
              .padding($r('app.float.space_sm'))
              .onClick((): void => {
                Router.goDownloadSettings();
              })
          }
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

        // ===== Tab 栏（多选模式下隐藏，列表合并展示） =====
        if (!this.vm.selectMode) {
          Row({ space: $r('app.float.space_lg') }) {
            this.TabBarItem('下载中', 0)
            this.TabBarItem('已下载', 1)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: $r('app.float.space_xs'), bottom: $r('app.float.space_xs') })
        }

        // ===== 列表区（LG/XL 限宽 840 居中；标题栏/Tab 栏/底部操作栏保持全宽） =====
        Column() {
          if (this.vm.selectMode) {
            this.SelectList()
          } else {
            Tabs({ barPosition: BarPosition.Start, index: this.currentTab }) {
              TabContent() {
                this.DownloadingTab()
              }
              .tabBar(this.TabBarItem('下载中', 0))

              TabContent() {
                this.DownloadedTab()
              }
              .tabBar(this.TabBarItem('已下载', 1))
            }
            .barHeight(0)
            .layoutWeight(1)
            .width('100%')
            .onChange((index: number): void => {
              this.currentTab = index;
            })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .constraintSize({ maxWidth: ContentWidth.cap(840, this.windowSize.isExpanded()) })

        // ===== 多选底部操作栏 =====
        if (this.vm.selectMode) {
          Row({ space: $r('app.float.space_md') }) {
            Text(this.isAllCurrentSelected() ? '取消全选' : '全选')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_secondary'))
              .onClick((): void => {
                this.toggleSelectAll();
              })
            Blank()
            Button(`删除所选 (${this.vm.selectedHids.length})`)
              .fontSize($r('app.float.font_size_body'))
              .fontColor(Color.White)
              .backgroundColor($r('app.color.error'))
              .borderRadius($r('app.float.radius_button'))
              .height(40)
              .enabled(this.vm.selectedHids.length > 0)
              .padding({
                left: $r('app.float.space_lg'),
                right: $r('app.float.space_lg')
              })
              .onClick((): void => {
                this.confirmRemoveSelected();
              })
          }
          .width('100%')
          .padding($r('app.float.space_lg'))
          .backgroundColor($r('app.color.card_background'))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_background'))
  }

  // ==================== Tab ====================

  /** Tab 计数（builder 内直接读 @Trace 数组，保证实时刷新） */
  private tabCountOf(index: number): number {
    return index === 0 ? this.vm.downloadingList.length : this.vm.downloadedList.length;
  }

  @Builder
  TabBarItem(title: string, index: number) {
    Text(this.tabCountOf(index) > 0 ? `${title} (${this.tabCountOf(index)})` : title)
      .fontSize($r('app.float.font_size_body'))
      .fontWeight(this.currentTab === index ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.currentTab === index ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .padding({ top: $r('app.float.space_xs'), bottom: $r('app.float.space_xs') })
      .border({
        width: { bottom: this.currentTab === index ? 2 : 0 },
        color: $r('app.color.brand')
      })
      .onClick((): void => {
        this.currentTab = index;
      })
  }

  // ==================== 列表 ====================

  /** 多选模式合并列表（两 Tab 去重） */
  private mergedListForSelect(): Video[] {
    const merged: Video[] = [];
    const seen: string[] = [];
    const downloading: Video[] = this.vm.downloadingList;
    const downloaded: Video[] = this.vm.downloadedList;
    for (let i = 0; i < downloading.length; i++) {
      merged.push(downloading[i]);
      seen.push(downloading[i].hid);
    }
    for (let i = 0; i < downloaded.length; i++) {
      if (seen.indexOf(downloaded[i].hid) < 0) {
        merged.push(downloaded[i]);
      }
    }
    return merged;
  }

  private isAllCurrentSelected(): boolean {
    const list: Video[] = this.vm.selectMode ? this.mergedListForSelect()
      : (this.currentTab === 0 ? this.vm.downloadingList : this.vm.downloadedList);
    if (list.length === 0) {
      return false;
    }
    for (let i = 0; i < list.length; i++) {
      if (!this.vm.isSelected(list[i].hid)) {
        return false;
      }
    }
    return true;
  }

  private toggleSelectAll(): void {
    const list: Video[] = this.mergedListForSelect();
    if (this.isAllCurrentSelected()) {
      for (let i = 0; i < list.length; i++) {
        if (this.vm.isSelected(list[i].hid)) {
          this.vm.toggleSelect(list[i].hid);
        }
      }
    } else {
      for (let i = 0; i < list.length; i++) {
        if (!this.vm.isSelected(list[i].hid)) {
          this.vm.toggleSelect(list[i].hid);
        }
      }
    }
  }

  /** 下载中 Tab（直接读 @Trace 数组，删除/进度变化时随引擎事件实时刷新） */
  @Builder
  DownloadingTab() {
    if (this.vm.downloadingList.length === 0) {
      Column() {
        EmptyView({ message: '暂无缓存任务，去视频详情页开启缓存吧' })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      // space 参数类型仅收 string|number（不收 Resource），4 = space_xs
      List({ space: 4 }) {
        ForEach(this.vm.downloadingList, (video: Video) => {
          ListItem() {
            this.VideoCard(video)
          }
          .swipeAction({
            end: this.buildDeleteSwipe(video)
          })
        }, (video: Video): string => video.hid)
      }
      .width('100%')
      .height('100%')
      .padding({
        left: $r('app.float.space_md'),
        right: $r('app.float.space_md'),
        bottom: $r('app.float.space_md')
      })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 已下载 Tab */
  @Builder
  DownloadedTab() {
    if (this.vm.downloadedList.length === 0) {
      Column() {
        EmptyView({ message: '还没有已缓存的视频' })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      // space 参数类型仅收 string|number（不收 Resource），4 = space_xs
      List({ space: 4 }) {
        ForEach(this.vm.downloadedList, (video: Video) => {
          ListItem() {
            this.VideoCard(video)
          }
          .swipeAction({
            end: this.buildDeleteSwipe(video)
          })
        }, (video: Video): string => video.hid)
      }
      .width('100%')
      .height('100%')
      .padding({
        left: $r('app.float.space_md'),
        right: $r('app.float.space_md'),
        bottom: $r('app.float.space_md')
      })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 多选模式合并列表（两 Tab 去重） */
  @Builder
  SelectList() {
    if (this.mergedListForSelect().length === 0) {
      Column() {
        EmptyView({ message: '还没有已缓存的视频' })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      // space 参数类型仅收 string|number（不收 Resource），4 = space_xs
      List({ space: 4 }) {
        ForEach(this.mergedListForSelect(), (video: Video) => {
          ListItem() {
            this.VideoCard(video)
          }
          .swipeAction({
            end: this.buildDeleteSwipe(video)
          })
        }, (video: Video): string => video.hid)
      }
      .width('100%')
      .height('100%')
      .padding({
        left: $r('app.float.space_md'),
        right: $r('app.float.space_md'),
        bottom: $r('app.float.space_md')
      })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  VideoCard(video: Video) {
    Column({ space: $r('app.float.space_sm') }) {
      // 合集行
      Row({ space: $r('app.float.space_md') }) {
        if (this.vm.selectMode) {
          Column() {
            if (this.vm.isSelected(video.hid)) {
              Text('✓')
                .fontSize(12)
                .fontColor($r('app.color.text_on_brand'))
            }
          }
          .width(20)
          .height(20)
          .borderRadius(10)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.vm.isSelected(video.hid) ? $r('app.color.brand') : Color.Transparent)
          .border({
            width: 1,
            color: this.vm.isSelected(video.hid) ? $r('app.color.brand') : $r('app.color.divider')
          })
        }
        NetworkImage({
          url: video.thumb,
          imageWidth: 128,
          imageHeight: 80,
          radius: 8
        })
        Column({ space: $r('app.float.space_xs') }) {
          Text(video.title)
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.vm.completedCountOf(video) > 0) {
            Text(this.subtitleOf(video))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (DownloadVM.hasUnfinished(video)) {
            Progress({
              value: this.vm.percentOfVideo(video),
              total: 100,
              type: ProgressType.Linear
            })
              .width('100%')
              .height(4)
              .color($r('app.color.brand'))
              .backgroundColor($r('app.color.divider'))
              .borderRadius(2)
            Text(`${this.vm.summaryTextOf(video)} · ${this.vm.percentOfVideo(video)}%`)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.brand'))
              .maxLines(1)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (!this.vm.selectMode) {
          Text(this.expandedHid === video.hid ? '▾' : '▸')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .padding($r('app.float.space_xs'))
        }
      }
      .width('100%')
      .onClick((): void => {
        this.onCardTap(video);
      })
      .bindContextMenu(this.buildRowMenu(video), ResponseType.RightClick)
      .bindContextMenu(this.buildRowMenu(video), ResponseType.LongPress)

      // 分集明细（展开态）
      if (this.expandedHid === video.hid && !this.vm.selectMode) {
        Column({ space: 0 }) {
          ForEach(video.parts, (part: Part, index: number) => {
            this.PartRow(video, part, index)
          }, (part: Part, index: number): string => `${part.vid}#${index}`)
        }
        .width('100%')
        .padding({ left: $r('app.float.space_md') })
      }
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.card_background'))
  }

  @Builder
  PartRow(video: Video, part: Part, index: number) {
    Row({ space: $r('app.float.space_sm') }) {
      Text(part.title.length > 0 ? part.title : `第${index + 1}集`)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(DownloadPartStatus.textOf(video, index, DownloadEngine.getInstance()))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor(this.partStatusColor(video, index))
      Text(this.partActionText(video, index))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.brand'))
        .padding({
          left: $r('app.float.space_sm'),
          right: $r('app.float.space_sm'),
          top: $r('app.float.space_xs'),
          bottom: $r('app.float.space_xs')
        })
        .onClick((): void => {
          this.onPartAction(video, index);
        })
    }
    .width('100%')
    .padding({ top: $r('app.float.space_sm'), bottom: $r('app.float.space_sm') })
  }

  // ==================== 状态/交互 ====================

  private subtitleOf(video: Video): string {
    const size: string = this.vm.completedSizeText(video);
    const count: number = this.vm.completedCountOf(video);
    return size.length > 0 ? `${count} 集已缓存 · ${size}` : `${count} 集已缓存`;
  }

  private partStatusColor(video: Video, index: number): ResourceColor {
    const part: Part | undefined = video.parts[index];
    if (part === undefined) {
      return $r('app.color.text_tertiary');
    }
    if (part.flag === DownloadStatus.COMPLETED) {
      return $r('app.color.success');
    }
    if (part.flag === DownloadStatus.FAILED) {
      return $r('app.color.error');
    }
    if (part.flag === DownloadStatus.PAUSED) {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.brand');
  }

  /** 分集动作文案：已完成=删除 / 已暂停=继续 / 失败=重试 / 其余=暂停 */
  private partActionText(video: Video, index: number): string {
    const part: Part | undefined = video.parts[index];
    if (part === undefined) {
      return '';
    }
    if (part.flag === DownloadStatus.COMPLETED) {
      return '删除';
    }
    if (part.flag === DownloadStatus.PAUSED) {
      return '继续';
    }
    if (part.flag === DownloadStatus.FAILED) {
      return '重试';
    }
    return '暂停';
  }

  private onPartAction(video: Video, index: number): void {
    const part: Part | undefined = video.parts[index];
    if (part === undefined) {
      return;
    }
    if (part.flag === DownloadStatus.COMPLETED) {
      this.confirmRemovePart(video.hid, index);
    } else if (part.flag === DownloadStatus.PAUSED || part.flag === DownloadStatus.FAILED) {
      this.vm.resumePart(video.hid, index);
    } else {
      this.vm.pausePart(video.hid, index);
    }
  }

  /** 合集行点击：多选=勾选；下载中=展开明细；已下载=进离线播放 */
  private onCardTap(video: Video): void {
    if (this.vm.selectMode) {
      this.vm.toggleSelect(video.hid);
      return;
    }
    if (this.expandedHid === video.hid) {
      this.expandedHid = '';
      return;
    }
    if (!DownloadVM.hasUnfinished(video)) {
      Router.goOfflinePlayer(video.hid);
      return;
    }
    this.expandedHid = video.hid;
  }

  /** 删除分集确认 */
  private confirmRemovePart(hid: string, index: number): void {
    this.getUIContext().showAlertDialog({
      title: '删除缓存分集',
      message: '将删除该分集的缓存文件，删除后不可恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.vm.removePart(hid, index);
          this.getUIContext().getPromptAction().showToast({ message: '已删除该分集' });
        }
      },
      cancel: (): void => {
      }
    });
  }

  /** 删除合集确认 */
  private confirmRemoveVideo(hid: string): void {
    this.getUIContext().showAlertDialog({
      title: '删除缓存',
      message: '将删除该合集的全部缓存分集与文件，删除后不可恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.vm.removeVideo(hid);
          this.getUIContext().getPromptAction().showToast({ message: '已删除缓存' });
        }
      },
      cancel: (): void => {
      }
    });
  }

  /** 批量删除确认 */
  private confirmRemoveSelected(): void {
    if (this.vm.selectedHids.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除所选缓存',
      message: `将删除已选 ${this.vm.selectedHids.length} 部合集的全部缓存文件，删除后不可恢复。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.vm.removeSelected();
          this.expandedHid = '';
          this.getUIContext().getPromptAction().showToast({ message: '已删除所选缓存' });
        }
      },
      cancel: (): void => {
      }
    });
  }

  /** 左滑删除（手机形态） */
  @Builder
  private buildDeleteSwipe(video: Video) {
    Row() {
      Text('删除')
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.text_on_brand'))
        .padding({
          left: $r('app.float.space_lg'),
          right: $r('app.float.space_lg')
        })
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.error'))
        .borderRadius($r('app.float.radius_card'))
        .onClick((): void => {
          this.confirmRemoveVideo(video.hid);
        })
    }
    .height('100%')
    .justifyContent(FlexAlign.End)
  }

  /** 右键/长按菜单：多选 + 删除（两形态同构） */
  @Builder
  private buildRowMenu(video: Video) {
    Menu() {
      MenuItem({ content: '多选' })
        .onClick((): void => {
          this.vm.enterSelect(video.hid);
        })
      MenuItem({ content: '删除缓存' })
        .onClick((): void => {
          this.confirmRemoveVideo(video.hid);
        })
    }
  }
}

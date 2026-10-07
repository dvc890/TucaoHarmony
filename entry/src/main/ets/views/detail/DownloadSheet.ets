/**
 * 缓存分集选择面板
 * - 纯内容组件：由 InfoView「缓存」入口 bindSheet 承载（接线），@Param vm + onClose
 * - 勾选态：checked 数组整体替换（@Local 数组元素赋值不可靠）
 * - 禁选分集：已缓存（COMPLETED）/ 已在下载队列或执行中（engine.isPending）
 * - 发起：收集可缓存勾选项 → DownloadEngine.enqueueDownload → toast「已加入下载队列 N 集」→ 关闭面板
 * 状态展示：已缓存(success)/缓存中/排队中(warning) + 已缓存分集体积
 */
import { Video, Part, DownloadStatus } from '../../model/entity/BaseEntities';
import { DownloadEngine } from '../../service/download/DownloadEngine';
import { DownloadStateText, FileSizeText } from '../../model/entity/DownloadEntities';
import { VideoDetailVM } from '../../viewmodel/VideoDetailVM';

@ComponentV2
export struct DownloadSheet {
  /** 详情 VM（单例，取当前 video.parts） */
  @Param vm: VideoDetailVM = VideoDetailVM.shared();
  /** 关闭面板回调（bindSheet 关闭由宿主执行） */
  @Param onClose: () => void = (): void => {
  };
  /** 勾选态（按分集下标；整体替换触发刷新） */
  @Local checked: boolean[] = [];
  private engine: DownloadEngine = DownloadEngine.getInstance();

  aboutToAppear(): void {
    const parts: Part[] = this.partsOf();
    const states: boolean[] = [];
    for (let i = 0; i < parts.length; i++) {
      states.push(false);
    }
    this.checked = states;
  }

  build() {
    Column({ space: 0 }) {
      // 标题栏
      Row({ space: $r('app.float.space_md') }) {
        Column({ space: $r('app.float.space_xs') }) {
          Text('缓存视频')
            .fontSize($r('app.float.font_size_title_lg'))
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Bold)
          Text(this.videoTitle())
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('✕')
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .height(36)
          .width(36)
          .padding(0)
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: $r('app.float.space_lg'), right: $r('app.float.space_md'), top: $r('app.float.space_lg') })

      // 全选行
      Row() {
        Text(this.allSelected() ? '取消全选' : '全选')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.brand'))
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            top: $r('app.float.space_sm'),
            bottom: $r('app.float.space_sm')
          })
          .onClick((): void => {
            this.toggleAll();
          })
        Blank()
        Text(`${this.selectableCount()} 集可缓存`)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
          .padding({ right: $r('app.float.space_lg') })
      }
      .width('100%')

      // 分集列表
      Scroll() {
        Column({ space: 0 }) {
          ForEach(this.partsOf(), (part: Part, index: number) => {
            this.PartRow(part, index)
          }, (part: Part, index: number): string => `${part.vid}#${index}`)
        }
        .width('100%')
        .padding({ bottom: $r('app.float.space_md') })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .width('100%')

      // 底部操作栏
      Row({ space: $r('app.float.space_md') }) {
        Text(this.selectedCount() > 0 ? `已选 ${this.selectedCount()} 集` : '请选择要缓存的分集')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Button('开始缓存')
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_on_brand'))
          .backgroundColor(this.selectedCount() > 0 ? $r('app.color.brand') : $r('app.color.text_tertiary'))
          .borderRadius($r('app.float.radius_button'))
          .height(40)
          .padding({ left: $r('app.float.space_lg'), right: $r('app.float.space_lg') })
          .enabled(this.selectedCount() > 0)
          .onClick((): void => {
            this.startDownload();
          })
      }
      .width('100%')
      .padding($r('app.float.space_lg'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  // ==================== 行渲染 ====================

  @Builder
  PartRow(part: Part, index: number) {
    Row({ space: $r('app.float.space_md') }) {
      // 勾选圈
      Column() {
        if (this.isChecked(index)) {
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
      .backgroundColor(this.isChecked(index) ? $r('app.color.brand') : Color.Transparent)
      .border({
        width: 1,
        color: this.isChecked(index) ? $r('app.color.brand') : $r('app.color.divider')
      })

      // 分集标题 + 附加信息
      Column({ space: $r('app.float.space_xs') }) {
        Text(part.title.length > 0 ? part.title : `第${index + 1}集`)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.statusTextOf(part).length > 0) {
          Text(this.statusTextOf(part))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(this.statusColorOf(part))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 右侧状态
      if (!this.canSelect(part)) {
        Text(part.flag === DownloadStatus.COMPLETED ? this.sizeTextOf(part) : this.statusTextOf(part))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(this.statusColorOf(part))
      } else if (part.totalSize > 0) {
        Text(FileSizeText.format(part.totalSize))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_lg'),
      right: $r('app.float.space_lg'),
      top: $r('app.float.space_md'),
      bottom: $r('app.float.space_md')
    })
    .onClick((): void => {
      this.toggle(index);
    })
  }

  // ==================== 状态计算 ====================

  private partsOf(): Part[] {
    const video: Video | null = this.vm.video;
    return video !== null ? video.parts : [];
  }

  private videoTitle(): string {
    const video: Video | null = this.vm.video;
    return video !== null ? video.title : '';
  }

  /** 分集可选（已缓存/队列中禁选） */
  private canSelect(part: Part): boolean {
    if (part.flag === DownloadStatus.COMPLETED) {
      return false;
    }
    const video: Video | null = this.vm.video;
    return video === null || !this.engine.isPending(video.hid, this.partsOf().indexOf(part));
  }

  private isChecked(index: number): boolean {
    return index < this.checked.length && this.checked[index];
  }

  private statusTextOf(part: Part): string {
    if (part.flag === DownloadStatus.COMPLETED) {
      return '已缓存';
    }
    const video: Video | null = this.vm.video;
    if (video !== null) {
      const index: number = this.partsOf().indexOf(part);
      if (this.engine.isPending(video.hid, index)) {
        return this.engine.isTaskActive(video.hid, index) ? '缓存中' : '排队中';
      }
    }
    if (part.flag === DownloadStatus.FAILED) {
      return DownloadStateText.of(part.flag);
    }
    return '';
  }

  private statusColorOf(part: Part): ResourceColor {
    if (part.flag === DownloadStatus.COMPLETED) {
      return $r('app.color.success');
    }
    if (part.flag === DownloadStatus.FAILED) {
      return $r('app.color.error');
    }
    return $r('app.color.warning');
  }

  /** 已缓存分集体积（durls totalSize 求和） */
  private sizeTextOf(part: Part): string {
    let bytes: number = 0;
    for (let i = 0; i < part.durls.length; i++) {
      bytes += part.durls[i].totalSize;
    }
    return bytes > 0 ? FileSizeText.format(bytes) : '已缓存';
  }

  private selectedCount(): number {
    let count: number = 0;
    const parts: Part[] = this.partsOf();
    for (let i = 0; i < this.checked.length && i < parts.length; i++) {
      if (this.checked[i] && this.canSelect(parts[i])) {
        count++;
      }
    }
    return count;
  }

  /** 可缓存分集总数（全选上限） */
  private selectableCount(): number {
    let count: number = 0;
    const parts: Part[] = this.partsOf();
    for (let i = 0; i < parts.length; i++) {
      if (this.canSelect(parts[i])) {
        count++;
      }
    }
    return count;
  }

  private allSelected(): boolean {
    const selectable: number = this.selectableCount();
    if (selectable === 0) {
      return false;
    }
    return this.selectedCount() >= selectable;
  }

  // ==================== 交互 ====================

  private toggle(index: number): void {
    const parts: Part[] = this.partsOf();
    if (index < 0 || index >= parts.length || !this.canSelect(parts[index])) {
      return;
    }
    const next: boolean[] = this.checked.slice();
    while (next.length <= index) {
      next.push(false);
    }
    next[index] = !next[index];
    this.checked = next;
  }

  private toggleAll(): void {
    const parts: Part[] = this.partsOf();
    const target: boolean = !this.allSelected();
    const next: boolean[] = [];
    for (let i = 0; i < parts.length; i++) {
      next.push(target && this.canSelect(parts[i]));
    }
    this.checked = next;
  }

  private startDownload(): void {
    const video: Video | null = this.vm.video;
    if (video === null) {
      return;
    }
    const parts: Part[] = this.partsOf();
    const indexes: number[] = [];
    for (let i = 0; i < this.checked.length && i < parts.length; i++) {
      if (this.checked[i] && this.canSelect(parts[i])) {
        indexes.push(i);
      }
    }
    if (indexes.length === 0) {
      return;
    }
    const added: number = this.engine.enqueueDownload(video, indexes);
    this.getUIContext().getPromptAction().showToast({
      message: added > 0 ? `已加入下载队列 ${added} 集` : '所选分集已在队列中'
    });
    this.onClose();
  }
}

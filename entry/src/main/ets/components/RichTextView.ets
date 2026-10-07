/**
 * 富文本视图（评论富文本）
 * 基于 @ohos/htmlspanner 纯逻辑 API（HtmlSpanner.fromHtmlAsync → StyledString →
 * TextController.setStyledString + Text），不使用库内 V1 HtmlSpannerText 组件
 * （State Management V2 代际铁律：仅引入纯逻辑库，@ComponentV2 树内不嵌 V1 UI 组件）。
 * - 网络图片：createScaledHttpImageAttachmentResolver 离屏解码缩放为 ImageAttachment
 * - 刷新纪律：generation 计数防异步竞态（旧请求完成后丢弃）
 * - 失败兜底：富文本解析异常时回退纯文本（调用方传入的 fallbackText）
 */
import { HtmlSpanner, createScaledHttpImageAttachmentResolver } from '@ohos/htmlspanner';

@ComponentV2
export struct RichTextView {
  /** HTML 内容（空串不渲染） */
  @Param html: string = '';
  /** 纯文本兜底（HTML 解析失败时展示） */
  @Param fallbackText: string = '';
  /** 基础字号（fp，对齐正文 token） */
  @Param baseFontSize: number = 15;
  /** 文本颜色（默认跟随主题主文本色） */
  @Param textColor: ResourceColor = $r('app.color.text_primary');
  /** 内容宽度 vp（图片行盒上限；0 = 不限制） */
  @Param contentWidthVp: number = 0;
  @Local renderFailed: boolean = false;
  private controller: TextController = new TextController();
  /** 异步刷新代数（丢弃过期结果） */
  private generation: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  @Monitor('html')
  onHtmlChange(): void {
    this.refresh();
  }

  private refresh(): void {
    this.generation += 1;
    const current: number = this.generation;
    const html: string = this.html.trim();
    if (html.length === 0) {
      this.renderFailed = true;
      return;
    }
    // 同步短路径优先：无 <img 时走 fromHtml（纯 CPU，毫秒级）；
    // 含 <img> 走 fromHtmlAsync（网络图离屏解码）
    const hasImage: boolean = html.includes('<img');
    try {
      const spanner: HtmlSpanner = RichTextView.createSpanner();
      if (!hasImage) {
        const styled: StyledString = spanner.fromHtml(html);
        if (current === this.generation) {
          this.controller.setStyledString(styled);
          this.renderFailed = false;
        }
        return;
      }
      const task: Promise<StyledString> = spanner.fromHtmlAsync(html);
      task.then((styled: StyledString): void => {
        if (current === this.generation) {
          this.controller.setStyledString(styled);
          this.renderFailed = false;
        }
      }).catch((): void => {
        if (current === this.generation) {
          this.renderFailed = true;
        }
      });
    } catch (err) {
      this.renderFailed = true;
    }
  }

  private static createSpanner(): HtmlSpanner {
    // 渲染选项：正文 15fp、品牌色链接；图片按 160vp 上限离屏缩放
    return new HtmlSpanner(undefined, {
      baseFontSize: 15,
      linkColor: '#EC407A',
      imageAttachmentResolver: createScaledHttpImageAttachmentResolver(160, 160)
    });
  }

  build() {
    if (this.renderFailed) {
      Text(this.fallbackText.length > 0 ? this.fallbackText : this.html)
        .fontSize(this.baseFontSize)
        .fontColor(this.textColor)
        .width('100%')
    } else {
      Text('', { controller: this.controller })
        .fontSize(this.baseFontSize)
        .fontColor(this.textColor)
        .width('100%')
    }
  }
}

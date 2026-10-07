/**
 * 大屏布局工具（– 大屏 UX 适配）
 * - VideoGridColumns：断点 → 视频网格列数/列模板，对齐首页/频道页网格惯例
 *   （SM 2 / MD 3 / LG 4 / XL 6 列）
 * - ContentWidth：内容限宽工具。SM/MD 保持全宽（零退化），
 *   LG/XL 按设计稿对内容区施加 maxWidth 约束；配合父容器默认居中
 *   实现「限宽居中」（.width('100%') + constraintSize 标准模式）
 */
import { WidthBreakpoint } from './GlobalState';

/** 视频网格列数与列模板（与 ChannelListView 网格惯例一致） */
export class VideoGridColumns {
  /** 断点 → 列数（SM 2 / MD 3 / LG 4 / XL 6） */
  static count(breakpoint: WidthBreakpoint): number {
    if (breakpoint === WidthBreakpoint.XL) {
      return 6;
    }
    if (breakpoint === WidthBreakpoint.LG) {
      return 4;
    }
    if (breakpoint === WidthBreakpoint.MD) {
      return 3;
    }
    return 2;
  }

  /** 断点 → Grid columnsTemplate（count 个 '1fr' 以空格连接） */
  static template(breakpoint: WidthBreakpoint): string {
    const parts: string[] = [];
    const count: number = VideoGridColumns.count(breakpoint);
    for (let i = 0; i < count; i++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }
}

/** 内容限宽工具（大屏「限宽居中」模式） */
export class ContentWidth {
  /** 不限宽占位值（远超任何屏宽，等效无约束，保持 SM/MD 全宽零退化） */
  static readonly UNLIMITED: number = 100000;

  /** applyCap=true 返回 maxVp（生效限宽），否则返回 UNLIMITED（全宽） */
  static cap(maxVp: number, applyCap: boolean): number {
    return applyCap ? maxVp : ContentWidth.UNLIMITED;
  }
}

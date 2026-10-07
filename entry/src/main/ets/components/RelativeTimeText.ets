/**
 * 相对时间文本（基于 @mui/dayjs 计算）
 * - 站点时间字符串 → 「x分钟前 / x小时前 / x天前…」中文文案
 * - relativeTime 插件的类型增强只作用于 'dayjs' 模块名，对 '@mui/dayjs' 不生效，
 *   故中文文案格式化自行实现，dayjs 仅负责解析与 diff（全部为核心类型安全 API）
 */
import dayjs from '@mui/dayjs';

export class RelativeTime {
  /** '2018-05-05 12:00:00' 等 → 相对时间文案；解析失败原样返回 */
  static format(dateText: string): string {
    const target = dayjs(dateText);
    if (!target.isValid()) {
      return dateText;
    }
    const now = dayjs();
    const seconds = now.diff(target, 'second');
    if (seconds < 60) {
      return '刚刚';
    }
    const minutes = now.diff(target, 'minute');
    if (minutes < 60) {
      return `${minutes}分钟前`;
    }
    const hours = now.diff(target, 'hour');
    if (hours < 24) {
      return `${hours}小时前`;
    }
    const days = now.diff(target, 'day');
    if (days < 30) {
      return `${days}天前`;
    }
    const months = now.diff(target, 'month');
    if (months < 12) {
      return `${months}个月前`;
    }
    const years = now.diff(target, 'year');
    return `${years}年前`;
  }

  /** unix 秒字符串 → 相对时间文案（api_v2 的 create 字段为 "1788334307" 形态） */
  static formatUnixSeconds(unixText: string): string {
    const seconds: number = Number.parseInt(unixText);
    if (Number.isNaN(seconds) || seconds <= 0) {
      return RelativeTime.format(unixText);
    }
    const target = dayjs(seconds * 1000);
    const now = dayjs();
    const days = now.diff(target, 'day');
    if (days < 1) {
      return RelativeTime.format(target.format('YYYY-MM-DD HH:mm:ss'));
    }
    if (days < 30) {
      return `${days}天前`;
    }
    return target.format('YYYY-MM-DD');
  }

  /** unix 秒字符串 → 「发布于 yyyy-MM-dd」（详情页发布时间，对齐安卓版 VideoInfoViewModel） */
  static formatPublishDate(unixText: string): string {
    const seconds: number = Number.parseInt(unixText);
    if (Number.isNaN(seconds) || seconds <= 0) {
      return unixText;
    }
    return `发布于 ${dayjs(seconds * 1000).format('YYYY-MM-DD')}`;
  }
}

@ComponentV2
export struct RelativeTimeText {
  /** 原始时间文本 */
  @Param timeText: string = '';
  @Local display: string = '';

  aboutToAppear(): void {
    this.display = RelativeTime.format(this.timeText);
  }

  @Monitor('timeText')
  onTimeTextChange(): void {
    this.display = RelativeTime.format(this.timeText);
  }

  build() {
    Text(this.display)
      .fontSize($r('app.float.font_size_caption'))
      .fontColor($r('app.color.text_tertiary'))
  }
}

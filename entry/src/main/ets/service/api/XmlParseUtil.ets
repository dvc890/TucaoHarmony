/**
 * XML 流式解析工具
 * 两个解析器共用 @ohos.util XmlPullParser（parseXml 回调式，parse() 已废弃）：
 * - parsePlayUrl：playurl 接口 XML（<video><durl><order/><length/><url/></durl>...</video>）
 * - parseDanmaku：弹幕 XML（<i><d p="stime,mode,size,color,date,pool,userhash,dmid">text</d></i>）
 * 在线拉取与离线 danmu.xml 走同一解析器（同构）。
 */
import { xml, util } from '@kit.ArkTS';
import { Danmaku, Durl } from '../../model/entity/BaseEntities';

/** playurl 解析结果（video 根节点字段 + durl 列表） */
export class PlayUrlResult {
  /** 接口回执（succ/fail） */
  result: string = '';
  /** 视频总时长 ms */
  timelength: number = 0;
  /** 清晰度源序号 */
  src: number = 0;
  /** 分段列表 */
  durls: Durl[] = [];

  get hasUrl(): boolean {
    return this.durls.length > 0;
  }
}

export class XmlParseUtil {
  /** playurl XML 文本 → PlayUrlResult（解析失败返回空结果，不抛异常） */
  static parsePlayUrl(xmlText: string): PlayUrlResult {
    const playResult: PlayUrlResult = new PlayUrlResult();
    const durls: Durl[] = [];
    let currentDurl: Durl | undefined = undefined;
    let currentField: string = '';
    let buffer: string = '';

    const onToken = (eventType: xml.EventType, info: xml.ParseInfo): boolean => {
      switch (eventType) {
        case xml.EventType.START_TAG: {
          const name: string = info.getName();
          if (name === 'durl') {
            currentDurl = new Durl();
            currentField = '';
            buffer = '';
          } else if (name === 'order' || name === 'length' || name === 'url') {
            currentField = name;
            buffer = '';
          } else {
            currentField = '';
          }
          break;
        }
        case xml.EventType.TEXT:
        case xml.EventType.CDSECT: {
          if (currentField !== '') {
            buffer += info.getText();
          }
          break;
        }
        case xml.EventType.END_TAG: {
          const name: string = info.getName();
          if (name === 'durl') {
            if (currentDurl !== undefined && currentDurl.url.length > 0) {
              durls.push(currentDurl);
            }
            currentDurl = undefined;
            currentField = '';
          } else if (name === currentField) {
            if (currentDurl !== undefined) {
              if (currentField === 'order') {
                currentDurl.order = XmlParseUtil.toInt(buffer);
              } else if (currentField === 'length') {
                currentDurl.length = XmlParseUtil.toInt(buffer);
              } else if (currentField === 'url') {
                currentDurl.url = buffer.trim();
              }
            }
            currentField = '';
          }
          break;
        }
        default:
          break;
      }
      return true;
    };

    // result/timelength/src（video 根级字段，不在 durl 内）：独立小状态跟踪
    let videoField: string = '';
    let videoBuffer: string = '';
    const onVideoToken = (eventType: xml.EventType, info: xml.ParseInfo): boolean => {
      if (eventType === xml.EventType.START_TAG) {
        const name: string = info.getName();
        if (name === 'result' || name === 'timelength' || name === 'src') {
          videoField = name;
          videoBuffer = '';
        } else {
          videoField = '';
        }
      } else if (eventType === xml.EventType.TEXT || eventType === xml.EventType.CDSECT) {
        if (videoField !== '') {
          videoBuffer += info.getText();
        }
      } else if (eventType === xml.EventType.END_TAG) {
        const name: string = info.getName();
        if (name === videoField) {
          if (videoField === 'result') {
            playResult.result = videoBuffer.trim();
          } else if (videoField === 'timelength') {
            playResult.timelength = XmlParseUtil.toInt(videoBuffer);
          } else if (videoField === 'src') {
            playResult.src = XmlParseUtil.toInt(videoBuffer);
          }
          videoField = '';
        }
      }
      return true;
    };

    const tokenHandler = (eventType: xml.EventType, info: xml.ParseInfo): boolean => {
      const keepA: boolean = onToken(eventType, info);
      const keepB: boolean = onVideoToken(eventType, info);
      return keepA && keepB;
    };

    XmlParseUtil.runParser(xmlText, tokenHandler, undefined);
    playResult.durls = durls;
    return playResult;
  }

  /** 弹幕 XML 文本 → Danmaku[]（解析失败返回空数组，不抛异常） */
  static parseDanmaku(xmlText: string): Danmaku[] {
    const result: Danmaku[] = [];
    let insideD: boolean = false;
    let pValue: string = '';
    let textBuffer: string = '';

    const onToken = (eventType: xml.EventType, info: xml.ParseInfo): boolean => {
      switch (eventType) {
        case xml.EventType.START_TAG: {
          if (info.getName() === 'd') {
            insideD = true;
            pValue = '';
            textBuffer = '';
          }
          break;
        }
        case xml.EventType.TEXT:
        case xml.EventType.CDSECT: {
          if (insideD) {
            textBuffer += info.getText();
          }
          break;
        }
        case xml.EventType.END_TAG: {
          if (insideD && info.getName() === 'd') {
            const dm: Danmaku | undefined = XmlParseUtil.buildDanmaku(pValue, textBuffer);
            if (dm !== undefined) {
              result.push(dm);
            }
            insideD = false;
          }
          break;
        }
        default:
          break;
      }
      return true;
    };

    // p 属性捕获（弹幕文件中仅 <d> 携带 p 属性）
    const onAttribute = (name: string, value: string): boolean => {
      if (name === 'p') {
        pValue = value;
      }
      return true;
    };

    XmlParseUtil.runParser(xmlText, onToken, onAttribute);
    return result;
  }

  /** p 属性 + 文本 → Danmaku（p 字段次序：stime,mode,size,color,date,pool,userhash,dmid） */
  private static buildDanmaku(pValue: string, text: string): Danmaku | undefined {
    const trimmed: string = text.trim();
    if (pValue.length === 0 || trimmed.length === 0) {
      return undefined;
    }
    const values: string[] = pValue.split(',');
    if (values.length < 4) {
      return undefined;
    }
    // 时间秒 → ms
    const stime: number = Math.round(XmlParseUtil.toFloat(values[0]) * 1000);
    const mode: number = XmlParseUtil.toInt(values[1]);
    const size: number = XmlParseUtil.toFloat(values[2]);
    const color: number = XmlParseUtil.toInt(values[3]);
    const pool: number = values.length > 5 ? XmlParseUtil.toInt(values[5]) : 0;
    return new Danmaku(mode, stime, color, size, trimmed, pool);
  }

  /** 执行 XmlPullParser（文本 → UTF-8 ArrayBuffer → parseXml） */
  private static runParser(xmlText: string,
    onToken: (eventType: xml.EventType, info: xml.ParseInfo) => boolean,
    onAttribute?: (name: string, value: string) => boolean): void {
    if (xmlText.length === 0) {
      return;
    }
    try {
      const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
      const encoded: Uint8Array = encoder.encodeInto(xmlText);
      const buffer: ArrayBuffer = encoded.buffer as ArrayBuffer;
      const parser: xml.XmlPullParser = new xml.XmlPullParser(buffer, 'utf-8');
      const options: xml.ParseOptions = {
        supportDoctype: false,
        ignoreNameSpace: true,
        tagValueCallbackFunction: undefined,
        attributeValueCallbackFunction: onAttribute,
        tokenValueCallbackFunction: onToken
      };
      parser.parseXml(options);
    } catch (err) {
      // 解析失败静默返回（调用方拿空列表）
    }
  }

  /** 字符串 → 整数（容错 NaN → 0） */
  private static toInt(value: string): number {
    const parsed: number = Number.parseInt(value.trim());
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  /** 字符串 → 浮点（容错 NaN → 0） */
  private static toFloat(value: string): number {
    const parsed: number = Number.parseFloat(value.trim());
    return Number.isNaN(parsed) ? 0 : parsed;
  }
}

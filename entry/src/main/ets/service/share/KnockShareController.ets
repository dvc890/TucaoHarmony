/**
 * 碰一碰分享控制器（华为 Share Kit）
 * -  直发：详情页前台注册 knockShare，设备顶部轻碰对端后回调内构造 HYPERLINK
 *   分享数据发送（零权限，canIUse('SystemCapability.Collaboration.HarmonyShare') 守卫）
 * - / 降级：showSharePanel() 拉系统分享面板（推荐区华为分享设备 / 复制链接 / 其他应用）
 * - 数据同构：utd=HYPERLINK + 站点网页版详情 URL（https://www.tucao.my/play/h{hid}/），
 *   碰一碰与面板共用同一份 SharedData；对端未装本应用时浏览器兜底
 * - 3 秒约束：碰一碰回调内先 share()（缩略图可缺省），网络封面异步下载入沙箱后
 *   updateShareData() 延迟补图（6.0.0(20)+），防止回调内同步等下载超时失败
 * - PC/2in1：注册/注销需传 windowId（window.getLastWindow 取主窗口，官方最佳实践）
 * - 详情未就绪：reject(NO_CONTENT_ERROR) 异常终止（5.0.3(15)+），系统侧提示用户
 * -  二维码（revisitShareRecordData，6.1.0(23)）：要求 utd=TEXT + READING_SHARE
 *   阅读分享模板，与视频链接卡片形态不匹配，标注待做（见方案 §五）
 */
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Video } from '../../model/entity/BaseEntities';
import { Host } from '../../common/Constants';
import { AppContextHolder } from '../../common/GlobalState';

/** 日志域与标签（对齐工程 0x0000 惯例） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'KnockShare';

export class KnockShareController {
  private static instance: KnockShareController | undefined;

  static getInstance(): KnockShareController {
    if (KnockShareController.instance === undefined) {
      KnockShareController.instance = new KnockShareController();
    }
    return KnockShareController.instance;
  }

  /** 设备是否支持华为分享（碰一碰）能力 */
  static isKnockSupported(): boolean {
    return canIUse('SystemCapability.Collaboration.HarmonyShare');
  }

  /** 设备是否支持系统分享面板（降级通道） */
  static isPanelSupported(): boolean {
    return canIUse('SystemCapability.Collaboration.SystemShare');
  }

  /** 当前监听态（幂等注册/注销；2in1 异步注册等待期同样生效防双注册） */
  private listening: boolean = false;
  /** 分享内容提供器（页面注入；碰一碰回调时取最新视频，详情未就绪返回 null） */
  private videoProvider: (() => Video | null) | null = null;
  /** 2in1 注册所用窗口配置（注销需原样回传） */
  private windowRegistry: harmonyShare.SendCapabilityRegistry | null = null;
  /** 缩略图缓存（key=网络图 URL，value=沙箱路径；碰一碰与面板共用免重复下载） */
  private cachedThumbUrl: string = '';
  private cachedThumbPath: string = '';

  /** 碰一碰回调（3 秒约束：先 share 后补图；详情未就绪 reject 异常终止） */
  private onKnock(target: harmonyShare.SharableTarget): void {
    const video: Video | null = this.videoProvider !== null ? this.videoProvider() : null;
    if (video === null || video.hid.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'knock triggered but detail not ready, reject');
      target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
        .catch((error: BusinessError): void => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, `reject failed: ${error.code}`);
        });
      return;
    }
    const thumbPath: string = this.cachedThumbOf(video);
    const shareData: systemShare.SharedData = KnockShareController.buildShareData(video, thumbPath);
    target.share(shareData)
      .then((): void => {
        hilog.info(LOG_DOMAIN, LOG_TAG, `knock share sent, hid=${video.hid}`);
      })
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, `knock share failed: ${error.code} ${error.message}`);
      });
    // 缩略图未就绪：异步下载完成后延迟补图（数据未发送前生效，6.0.0(20)+）
    if (thumbPath.length === 0 && video.thumb.length > 0) {
      this.downloadThumb(video)
        .then((path: string): void => {
          if (path.length === 0) {
            return;
          }
          const updated: harmonyShare.UpdatedData = { thumbnailUri: fileUri.getUriFromPath(path) };
          target.updateShareData(updated)
            .then((): void => {
              hilog.info(LOG_DOMAIN, LOG_TAG, 'knock share thumbnail updated');
            })
            .catch((error: BusinessError): void => {
              hilog.warn(LOG_DOMAIN, LOG_TAG, `updateShareData failed: ${error.code}`);
            });
        });
    }
  }

  /** 详情页可见时注册（VideoDetail.onShown 调用；canIUse 守卫 + 幂等） */
  listen(videoProvider: () => Video | null): void {
    this.videoProvider = videoProvider;
    if (!KnockShareController.isKnockSupported() || this.listening) {
      return;
    }
    this.listening = true;
    try {
      if (deviceInfo.deviceType === '2in1') {
        // PC/2in1：需 windowId 指定可轻贴窗口（官方最佳实践 immersiveListeningPC）
        const context: common.UIAbilityContext | null = AppContextHolder.get();
        if (context === null) {
          this.listening = false;
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'listen: no UIAbilityContext, skip');
          return;
        }
        window.getLastWindow(context)
          .then((win: window.Window): void => {
            if (!this.listening) {
              return; // 等待期已注销：放弃注册
            }
            const registry: harmonyShare.SendCapabilityRegistry = {
              windowId: win.getWindowProperties().id,
              sendOnly: true
            };
            this.windowRegistry = registry;
            harmonyShare.on('knockShare', registry,
              (target: harmonyShare.SharableTarget): void => { this.onKnock(target); });
            hilog.info(LOG_DOMAIN, LOG_TAG, `knockShare registered (windowId=${registry.windowId})`);
          })
          .catch((error: BusinessError): void => {
            this.listening = false;
            hilog.error(LOG_DOMAIN, LOG_TAG, `getLastWindow failed: ${error.code} ${error.message}`);
          });
      } else {
        harmonyShare.on('knockShare',
          (target: harmonyShare.SharableTarget): void => { this.onKnock(target); });
        hilog.info(LOG_DOMAIN, LOG_TAG, 'knockShare registered');
      }
    } catch (err) {
      this.listening = false;
      const error: BusinessError = err as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, `knockShare register exception: ${error.code} ${error.message}`);
    }
  }

  /** 详情页不可见/销毁时注销（onHidden / aboutToDisappear 调用；幂等） */
  unlisten(): void {
    this.videoProvider = null;
    if (!this.listening) {
      return;
    }
    this.listening = false;
    try {
      if (this.windowRegistry !== null) {
        harmonyShare.off('knockShare', this.windowRegistry);
        this.windowRegistry = null;
      } else {
        harmonyShare.off('knockShare');
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'knockShare unregistered');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, `knockShare unregister exception: ${error.code}`);
    }
  }

  /** 构造分享数据（HYPERLINK + 站点详情 URL；碰一碰与分享面板共用） */
  static buildShareData(video: Video, thumbPath: string): systemShare.SharedData {
    const record: systemShare.SharedRecord = {
      utd: utd.UniformDataType.HYPERLINK,
      content: Host.videoShareUrl(video.hid),
      title: video.title,
      description: video.user.length > 0 ? `UP主：${video.user}` : '吐槽视频分享'
    };
    if (thumbPath.length > 0) {
      // 沙箱缩略图转 URI（thumbnailUri 无 32KB 限制，官方推荐优先于 thumbnail）
      record.thumbnailUri = fileUri.getUriFromPath(thumbPath);
    }
    return new systemShare.SharedData(record);
  }

  /** / 降级通道：拉系统分享面板（推荐区华为分享设备 / 复制链接 / 其他应用） */
  async showSharePanel(context: common.UIAbilityContext, video: Video, anchorId: string): Promise<void> {
    if (!KnockShareController.isPanelSupported()) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'systemShare unsupported, skip panel');
      return;
    }
    // 面板无 3 秒约束：等待缩略图下载完成再拉起（超时/失败则无图分享，系统用默认图标）
    let thumbPath: string = this.cachedThumbOf(video);
    if (thumbPath.length === 0 && video.thumb.length > 0) {
      thumbPath = await this.downloadThumb(video);
    }
    const shareData: systemShare.SharedData = KnockShareController.buildShareData(video, thumbPath);
    const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
    controller.on('dismiss', (): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'share panel dismissed');
    });
    const options: systemShare.ShareControllerOptions = {
      previewMode: systemShare.SharePreviewMode.DEFAULT,
      selectionMode: systemShare.SelectionMode.SINGLE,
      anchor: anchorId
    };
    await controller.show(context, options);
    hilog.info(LOG_DOMAIN, LOG_TAG, `share panel shown, hid=${video.hid}`);
  }

  /** 缩略图缓存命中（同 URL 才复用，切视频自动失效） */
  private cachedThumbOf(video: Video): string {
    return video.thumb.length > 0 && video.thumb === this.cachedThumbUrl ? this.cachedThumbPath : '';
  }

  private cacheThumb(url: string, path: string): void {
    this.cachedThumbUrl = url;
    this.cachedThumbPath = path;
  }

  /** 网络封面下载入沙箱（cache/share_thumb/；命中历史文件直接复用） */
  private async downloadThumb(video: Video): Promise<string> {
    const context: common.UIAbilityContext | null = AppContextHolder.get();
    if (context === null || video.thumb.length === 0) {
      return '';
    }
    const cached: string = this.cachedThumbOf(video);
    if (cached.length > 0) {
      return cached;
    }
    const dir: string = `${context.cacheDir}/share_thumb`;
    const path: string = `${dir}/thumb_${video.hid}.${KnockShareController.thumbExt(video.thumb)}`;
    const client: http.HttpRequest = http.createHttp();
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      if (fileIo.accessSync(path)) {
        this.cacheThumb(video.thumb, path);
        return path;
      }
      const response: http.HttpResponse = await client.request(video.thumb, {
        method: http.RequestMethod.GET,
        connectTimeout: 6000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, `thumb bad response: ${response.responseCode}`);
        return '';
      }
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, response.result);
      } finally {
        fileIo.closeSync(file);
      }
      this.cacheThumb(video.thumb, path);
      hilog.info(LOG_DOMAIN, LOG_TAG, `thumb downloaded: ${path}`);
      return path;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG, `thumb download failed: ${error.code} ${error.message}`);
      return '';
    } finally {
      client.destroy();
    }
  }

  /** 从 URL 尾段取图片扩展名（默认 jpg） */
  private static thumbExt(url: string): string {
    const queryStripped: string = url.split('?')[0];
    const dot: number = queryStripped.lastIndexOf('.');
    if (dot < 0 || dot <= queryStripped.lastIndexOf('/')) {
      return 'jpg';
    }
    const ext: string = queryStripped.substring(dot + 1).toLowerCase();
    return ext === 'png' || ext === 'webp' || ext === 'gif' ? ext : 'jpg';
  }
}

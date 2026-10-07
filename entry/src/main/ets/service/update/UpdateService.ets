/**
 * 应用更新服务（对标安卓 JsonApiService.update + MainActivity.checkUpdate）
 * - 端点：http://45.63.54.11:12450/api/app-portal/version（独立更新服务器，非主站）
 * - 参数：appKey=3990dcd7-49e1-4040-92e9-912082dc1896 & appToken=3d580ea3-54e9-4659-9131-a78c56cf9b86 &
 *   versionCode（服务端下发 app-portal 的版本信息，安卓各版本即该 appKey/appToken）
 * - status==1 且 versionCode>当前 → 有新版本；否则无更新
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 更新信息（对齐安卓 model/json/Version.kt） */
export class VersionInfo {
  /** 服务端下发状态（1=正常） */
  status: number = 0;
  /** 新版 versionCode */
  versionCode: number = 0;
  /** 新版 versionName */
  versionName: string = '';
  /** 更新说明 */
  description: string = '';
  /** APK 下载地址 */
  apkUrl: string = '';
  /** APK 大小（字节） */
  apkSize: number = 0;
  /** 省流量差分包地址（可为空） */
  patchUrl: string = '';
  /** 差分包大小（字节） */
  patchSize: number = 0;
}

export class UpdateService {
  private static readonly APP_KEY: string = '3990dcd7-49e1-4040-92e9-912082dc1896';
  private static readonly APP_TOKEN: string = '3d580ea3-54e9-4659-9131-a78c56cf9b86';
  private static readonly UPDATE_URL: string = 'http://45.63.54.11:12450/api/app-portal/version';
  private static readonly URL_ENCODED: string = 'application/x-www-form-urlencoded';

  private static instance: UpdateService | undefined;

  static shared(): UpdateService {
    if (UpdateService.instance === undefined) {
      UpdateService.instance = new UpdateService();
    }
    return UpdateService.instance;
  }

  /**
   * 检查更新
   * @param currentVersionCode 本机 bundleManager 读取的 versionCode
   * @returns 有新版本返回 VersionInfo；无更新 / 服务端非 status=1 返回 null；网络异常抛错误
   */
  async checkForUpdate(currentVersionCode: number): Promise<VersionInfo | null> {
    const params: Record<string, string> = {
      'appKey': UpdateService.APP_KEY,
      'appToken': UpdateService.APP_TOKEN,
      'versionCode': `${currentVersionCode}`
    };
    const query: string = Object.keys(params)
      .map((key: string): string => `${key}=${encodeURIComponent(params[key])}`)
      .join('&');
    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await httpRequest.request(
        `${UpdateService.UPDATE_URL}?${query}`,
        {
          method: http.RequestMethod.GET,
          connectTimeout: 8000,
          readTimeout: 8000,
          header: { 'Content-Type': UpdateService.URL_ENCODED }
        });
      if (response.result === undefined) {
        throw new Error('update response empty');
      }
      const data: Record<string, Object> = response.result as Record<string, Object>;
      if (data['status'] !== 1) {
        return null;
      }
      const info: VersionInfo = new VersionInfo();
      info.status = data['status'] as number;
      info.versionCode = data['versionCode'] as number;
      info.versionName = data['versionName'] as string;
      info.description = data['description'] as string;
      info.apkUrl = data['apkUrl'] as string ?? '';
      info.apkSize = data['apkSize'] as number ?? 0;
      info.patchUrl = data['patchUrl'] as string ?? '';
      info.patchSize = data['patchSize'] as number ?? 0;
      return info;
    } finally {
      httpRequest.destroy();
    }
  }

  /** 字节数人性化（对齐安卓 formatWithUnit，如 23.1MB） */
  static formatSize(bytes: number): string {
    if (bytes <= 0) {
      return '';
    }
    const mb: number = bytes / (1024 * 1024);
    if (mb >= 100) {
      return `${mb.toFixed(0)}MB`;
    }
    if (mb >= 10) {
      return `${mb.toFixed(1)}MB`;
    }
    return `${mb.toFixed(1)}MB`;
  }
}
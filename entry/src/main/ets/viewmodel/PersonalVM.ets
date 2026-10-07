/**
 * 个人中心 VM
 * 对齐安卓版 PersonalViewModel：
 * - 用户摘要展示（昵称/签名/邮箱/等级/未读短消息）
 * - 头像更换：相册（PhotoViewPicker）或拍照（cameraPicker）→ 自绘 1:1 裁剪 → uploadAvatar
 * - 修改资料（昵称+签名）、修改密码（成功后清会话需重新登录）、退出登录
 * 裁剪算法：图片 fit 展示于舞台（宽=屏宽-32，高≤屏宽*0.7），
 * 正方形裁剪窗在图内拖动，窗坐标按 像素宽/展示宽 比例映射到像素区域后 PixelMap.crop。
 */
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { AppContextHolder } from '../common/GlobalState';
import { User } from '../model/entity/BaseEntities';
import { SessionService } from '../service/session/SessionService';

@ObservedV2
export class PersonalVM {
  /** 用户摘要（currentUser 镜像，操作成功后 refresh） */
  @Trace loggedIn: boolean = false;
  @Trace email: string = '';
  @Trace nickname: string = '';
  @Trace avatar: string = '';
  @Trace level: number = 0;
  @Trace signature: string = '';
  @Trace unreadMessage: number = 0;
  /** 资料/密码提交中 */
  @Trace busy: boolean = false;

  /** 裁剪浮层状态 */
  @Trace cropActive: boolean = false;
  @Trace cropPixels: image.PixelMap | null = null;
  /** 图片展示尺寸（vp） */
  @Trace cropDispW: number = 0;
  @Trace cropDispH: number = 0;
  /** 裁剪窗位置（vp，图内坐标） */
  @Trace cropWinX: number = 0;
  @Trace cropWinY: number = 0;
  /** 头像上传中 */
  @Trace uploading: boolean = false;

  /** 原图像素尺寸 */
  private cropPxW: number = 0;
  private cropPxH: number = 0;

  private readonly session: SessionService = SessionService.shared();

  /** 裁剪窗边长（vp，正方形 = 展示宽高较小者） */
  get cropSide(): number {
    return Math.min(this.cropDispW, this.cropDispH);
  }

  /** 从本地会话刷新摘要 */
  refresh(): void {
    const user: User = this.session.currentUser();
    this.loggedIn = user.isValid();
    this.email = this.loggedIn ? user.email : '';
    this.nickname = this.loggedIn ? user.name : '';
    this.avatar = this.loggedIn ? user.avatar : '';
    this.level = this.loggedIn ? user.level : 0;
    this.signature = this.loggedIn ? user.signature : '';
    this.unreadMessage = this.loggedIn ? user.message : 0;
  }

  /** 进入页面：本地摘要 + 后台回抓个人页（对齐安卓版进入即刷新） */
  init(): void {
    this.refresh();
    this.session.fetchPersonal().then((): void => {
      this.refresh();
    }).catch((_err: Object): void => {
      // 后台刷新失败不打扰用户（展示本地摘要）
    });
  }

  /** 从相册选择头像 */
  async pickFromGallery(): Promise<void> {
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result.photoUris.length > 0) {
        await this.beginCrop(result.photoUris[0]);
      }
    } catch (err) {
      // 用户取消或选择器异常：静默
    }
  }

  /** 拍照获取头像 */
  async takePhoto(): Promise<void> {
    try {
      const result: cameraPicker.PickerResult = await cameraPicker.pick(AppContextHolder.get(),
        [cameraPicker.PickerMediaType.PHOTO],
        { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK });
      if (result.resultUri.length > 0) {
        await this.beginCrop(result.resultUri);
      }
    } catch (err) {
      // 用户取消或相机异常：静默
    }
  }

  /** 解码所选图片并进入裁剪（pick uri → fd → ImageSource → PixelMap） */
  private async beginCrop(uri: string): Promise<void> {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const source: image.ImageSource = image.createImageSource(file.fd);
      const info: image.ImageInfo = await source.getImageInfo();
      this.cropPxW = info.size.width;
      this.cropPxH = info.size.height;
      if (this.cropPxW <= 0 || this.cropPxH <= 0) {
        source.release();
        return;
      }
      const pixels: image.PixelMap = await source.createPixelMap();
      source.release();
      // 展示尺寸：fit 舞台（宽 = 屏宽 - 2*16，高 ≤ 屏宽 * 0.7，保持纵横比）
      const disp: display.Display = display.getDefaultDisplaySync();
      const density: number = disp.densityPixels > 0 ? disp.densityPixels : 3;
      const screenW: number = disp.width / density;
      const stageW: number = Math.max(screenW - 32, 100);
      const stageMaxH: number = screenW * 0.7;
      let dispW: number = stageW;
      let dispH: number = stageW * this.cropPxH / this.cropPxW;
      if (dispH > stageMaxH) {
        dispH = stageMaxH;
        dispW = stageMaxH * this.cropPxW / this.cropPxH;
      }
      this.cropDispW = dispW;
      this.cropDispH = dispH;
      // 裁剪窗初始居中
      const side: number = Math.min(dispW, dispH);
      this.cropWinX = (dispW - side) / 2;
      this.cropWinY = (dispH - side) / 2;
      this.cropPixels = pixels;
      this.cropActive = true;
    } catch (err) {
      // 解码失败：静默（可重试）
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 拖动裁剪窗（图内坐标，自动夹紧） */
  moveWindowTo(x: number, y: number): void {
    const side: number = this.cropSide;
    const maxX: number = Math.max(this.cropDispW - side, 0);
    const maxY: number = Math.max(this.cropDispH - side, 0);
    this.cropWinX = Math.min(Math.max(x, 0), maxX);
    this.cropWinY = Math.min(Math.max(y, 0), maxY);
  }

  /** 取消裁剪 */
  cancelCrop(): void {
    this.closeCrop();
  }

  /** 应用裁剪并上传头像（返回是否成功） */
  async applyCrop(): Promise<boolean> {
    const pixels: image.PixelMap | null = this.cropPixels;
    if (pixels === null || this.uploading) {
      return false;
    }
    // 展示坐标 → 像素坐标（等比缩放）
    const scale: number = this.cropPxW / this.cropDispW;
    const sideVp: number = this.cropSide;
    const x: number = Math.max(0, Math.round(this.cropWinX * scale));
    const y: number = Math.max(0, Math.round(this.cropWinY * scale));
    const sizePx: number = Math.max(16, Math.round(sideVp * scale));
    const width: number = Math.min(sizePx, this.cropPxW - x);
    const height: number = Math.min(sizePx, this.cropPxH - y);
    if (width <= 0 || height <= 0) {
      return false;
    }
    this.uploading = true;
    try {
      await pixels.crop({ x: x, y: y, size: { width: width, height: height } });
      const oldAvatar: string = this.avatar;
      await this.session.uploadAvatar(pixels);
      this.refresh();
      // 站点头像地址未变时追加时间戳，避免图片缓存展示旧头像
      if (this.avatar.length > 0 && this.avatar === oldAvatar) {
        this.avatar = this.avatar + (this.avatar.indexOf('?') >= 0 ? '&' : '?') + 't=' + Date.now();
      }
      this.closeCrop();
      return true;
    } catch (err) {
      return false;
    } finally {
      this.uploading = false;
    }
  }

  /** 关闭裁剪并释放位图（延迟释放，避开渲染中引用） */
  private closeCrop(): void {
    this.cropActive = false;
    const pixels: image.PixelMap | null = this.cropPixels;
    this.cropPixels = null;
    if (pixels !== null) {
      setTimeout((): void => {
        pixels.release();
      }, 600);
    }
  }

  /** 保存资料（昵称+签名），返回是否成功 */
  async saveProfile(nickname: string, signature: string): Promise<boolean> {
    const name: string = nickname.trim();
    if (name.length < 2 || name.length > 20) {
      return false;
    }
    this.busy = true;
    try {
      await this.session.changeInfo(name, signature.trim());
      this.refresh();
      return true;
    } catch (err) {
      return false;
    } finally {
      this.busy = false;
    }
  }

  /** 修改密码（成功后会话失效，需重新登录），返回是否成功 */
  async changePassword(oldPassword: string, newPassword: string, renewPassword: string): Promise<boolean> {
    if (oldPassword.length === 0 || newPassword.length < 6 || newPassword.length > 20) {
      return false;
    }
    if (newPassword !== renewPassword) {
      return false;
    }
    this.busy = true;
    try {
      await this.session.changePassword(oldPassword, newPassword, renewPassword);
      this.refresh();
      return true;
    } catch (err) {
      return false;
    } finally {
      this.busy = false;
    }
  }

  /** 退出登录（本地立即清空，服务端登出异步进行） */
  async logout(): Promise<void> {
    await this.session.logout();
    this.refresh();
  }
}

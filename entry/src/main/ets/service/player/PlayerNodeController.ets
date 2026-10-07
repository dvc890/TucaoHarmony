/**
 * 播放器活节点单例（全工程唯一 XComponent）
 * - BuilderNode 内持 XComponent（SURFACE 类型）：NodeContainer 挂载即渲染，
 *   半屏 ⇄ 全屏/转场飞行 = 同一节点换宿主，播放画面全程连续不黑屏
 * - XComponent onLoad → notifySurfaceReady → 页面注册的监听（转发 VM attachSurface）
 * - 同帧交接：源页面置 nodeHost=undefined 卸载 NodeContainer，目标页 NodeContainer 挂载时
 *   makeNode 返回缓存 FrameNode（组件 aboutToAppear/onLoad 不重触发 → surface 不变，无需换绑）
 * - dispose：销毁 BuilderNode；下次 makeNode 重建全新节点（新 surface/新 onLoad）
 */
import { BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';

/** XComponent 载体（哑组件：仅持有 XComponent，surface 就绪经单例转发） */
@Component
struct PlayerSurfaceNode {
  private xComponentController: XComponentController = new XComponentController();

  aboutToAppear(): void {
    PlayerNodeController.getInstance().attachXComponentController(this.xComponentController);
  }

  build() {
    XComponent({ type: XComponentType.SURFACE, controller: this.xComponentController })
      .onLoad((): void => {
        PlayerNodeController.getInstance()
          .notifySurfaceReady(this.xComponentController.getXComponentSurfaceId());
      })
      .width('100%')
      .height('100%')
  }
}

/** 全局 @Builder（wrapBuilder 包装后交 BuilderNode.build 挂载） */
@Builder
function playerSurfaceBuilder() {
  PlayerSurfaceNode()
}

/** 活节点控制器（单例）：跨页面迁移的播放器画面载体 */
export class PlayerNodeController extends NodeController {
  private static instance: PlayerNodeController | undefined = undefined;
  private rootNode: BuilderNode<[]> | null = null;
  private wrapBuilderRef: WrappedBuilder<[]> = wrapBuilder(playerSurfaceBuilder);
  private xcontroller: XComponentController | null = null;
  private surfaceId: string = '';
  private surfaceListener: ((surfaceId: string) => void) | null = null;

  private constructor() {
    super();
  }

  static getInstance(): PlayerNodeController {
    if (PlayerNodeController.instance === undefined) {
      PlayerNodeController.instance = new PlayerNodeController();
    }
    return PlayerNodeController.instance;
  }

  /** XComponent 挂载（PlayerSurfaceNode aboutToAppear） */
  attachXComponentController(controller: XComponentController): void {
    this.xcontroller = controller;
  }

  /** XComponent onLoad：surface 就绪通知（每次 BuilderNode 生命周期触发一次） */
  notifySurfaceReady(surfaceId: string): void {
    this.surfaceId = surfaceId;
    if (this.surfaceListener !== null) {
      this.surfaceListener(surfaceId);
    }
  }

  /** 直发当前 surface（宿主页面重建但节点未重建时补偿重绑，幂等） */
  dispatchSurface(): void {
    if (this.surfaceId.length > 0 && this.surfaceListener !== null) {
      this.surfaceListener(this.surfaceId);
    }
  }

  /** 注册 surface 监听（VideoDetail aboutToAppear：转发 VM attachSurface） */
  setSurfaceListener(listener: (surfaceId: string) => void): void {
    this.surfaceListener = listener;
  }

  /** 当前 XComponentController（PiP componentController 用；节点未建返回 null） */
  getXComponentController(): XComponentController | null {
    return this.xcontroller;
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    if (this.rootNode === null) {
      this.rootNode = new BuilderNode(uiContext);
      this.rootNode.build(this.wrapBuilderRef);
    }
    return this.rootNode.getFrameNode();
  }

  /** 销毁节点与后端实体引用：下次 makeNode 重建全新节点（新 surface/新 onLoad） */
  dispose(): void {
    if (this.rootNode !== null) {
      this.rootNode.dispose();
      this.rootNode = null;
    }
    this.xcontroller = null;
    this.surfaceId = '';
  }
}

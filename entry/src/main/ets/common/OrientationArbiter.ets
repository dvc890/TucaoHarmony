/**
 * 方向仲裁器（§3.5 方向所有权统一：三通道 → 一通道）
 * 窗口方向是窗口级持久状态（页面返回不自动还原），历史上三通道竞争：
 * A 幂等重申（VideoDetail.restoreWindowOrientation 直发）/ B 阶梯归还（原
 * ExitOrientationRestorer）/ C 声明式属性（页面销毁框架自动释放注入 UNSPECIFIED
 * 噪声）。C 已随两处声明式 preferredOrientation 拆除而消失；本类收编 A+B 成为
 * 唯一方向请求序列所有者：
 * - requestEnter()：进全屏"先旋转后展开"（§3.1）——LANDSCAPE 请求 + 几何稳定确认
 *   （windowSizeChange 驱动的 GlobalState 轮询 + 300ms 稳定拍，不用请求返回值判
 *   几何）；粘性容器超时兜底：UNSPECIFIED 重置 + 重发一次（实测重置后 LANDSCAPE
 *   可正常接受），再超时返回 false 由调用方按当前几何降级推进
 * - requestRestore(target)：退/中断归还——第一拍立即发目标值（原通道 A 并入：
 *   健康容器即刻翻转，近零成本），随后阶梯"UNSPECIFIED 重置 → 间隔 → 目标 →
 *   几何校验"循环（粘性容器唯一可靠通道：sceneboard 对全屏期 LANDSCAPE 存粘性
 *   换算态，单发 PORTRAIT 会被 "Convert from: 2 to: 2" 丢弃；首阶 3000ms 为
 *    实测生效值，1800 被丢弃）；传感器跟随支路（平板/折叠）无确定目标几何，
 *   单次两步不校验。同目标在途重入幂等（触发点：B 档第二段=详情页销毁支路 /
 *   平板折叠落位复位 / 快速双返回中断，多处触发不重复起序列）
 * - cancel()：作废在途序列（进全屏转场/新播放页进入），generation 见代自检
 * 静态实现（归还序列须在 Player/VideoDetail 析构后继续跑），显式 cancel 语义
 * 与原 ExitOrientationRestorer 一致
 */
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContextHolder, GlobalState, WindowSizeInfo } from './GlobalState';
import { WindowModeHelper } from './WindowModeHelper';

export class OrientationArbiter {
  /** 几何稳定轮询间隔 ms（GlobalState 由 EntryAbility windowSizeChange 实时写入）。
   *  【旋转提速】100→50：模拟器实测旋转事件 52-203ms 内落定，50ms 轮询最多
   *  晚发现 50ms（原 100ms），几何事件本体系统绑定不受影响 */
  private static readonly ENTER_POLL_GAP_MS: number = 50;
  /** 几何稳定拍 ms：尺寸事件静默窗口，两采样一致才认稳定（抖动过滤，§3.1 步骤 5）。
   *  【旋转提速】300→150：稳定拍防的是"稳定拍内又有新尺寸事件"（旋转抖动连续
   *  事件流）；实测单次进全屏仅一条 windowSizeChange 事件（3/3 run），150ms
   *  静默窗口（~9 帧）足以过滤相邻事件抖动 */
  private static readonly ENTER_STABLE_BEAT_MS: number = 150;
  /** 单轮 LANDSCAPE 等待超时 ms（模拟器旋转 ~1.6s + 余量；真机 ~400ms） */
  private static readonly ENTER_TIMEOUT_MS: number = 2500;
  /** 归还阶梯间隔 ms：首阶 3000 为  实测生效值（1800 被粘性换算丢弃），后续放宽兜底 */
  private static readonly LADDER_GAPS_MS: number[] = [3000, 4400, 6000, 6000];
  /** 第一拍与阶梯起步的错峰 ms（复用原 START_DELAY_MS 语义：第一拍先落地） */
  private static readonly RESTORE_START_DELAY_MS: number = 80;
  /** 阶梯目标请求后几何校验等待 ms（> 系统旋转动画时长 ~400ms） */
  private static readonly VERIFY_DELAY_MS: number = 700;
  /** 传感器跟随支路固定间隔 ms（与阶梯首阶同源） */
  private static readonly SENSOR_GAP_MS: number = 1800;

  /** 在跑计时器（cancel 清理用；已触发的 id 再 clearTimeout 无害） */
  private static timers: number[] = [];
  /** 序列代号：cancel/新序列自增，在途异步步进（enter 轮询/阶梯）见代自检作废 */
  private static generation: number = 0;
  /** 在途归还目标（同目标重入幂等去重） */
  private static restoreTarget: window.Orientation = window.Orientation.UNSPECIFIED;
  private static restoreActive: boolean = false;
  /** 【旋转提速】beginEnter 缓存的窗口句柄：awaitEnterStable 粘性兜底重发与
   *  整体式回退共用；cancel() 清理（窗口句柄本身仅引用不持有） */
  private static enterWindow: window.Window | undefined = undefined;

  /** 进全屏第 1 步（§3.1 步骤 1-2，点击瞬间同步执行）：作废在途序列 → 经
   *  WindowModeHelper 缓存主窗口同步派发 LANDSCAPE（省 getLastWindow IPC 往返，
   *  请求与点击同帧发出）。
   *  返回序列代号 gen（awaitEnterStable 入参）；-1 = 缓存窗口不可达（init 前/
   *  异常时序），调用方回退整体式 requestEnter（内部 getLastWindow 兜底） */
  static beginEnter(): number {
    // §3.1 步骤 1：若有归还循环在跑立即取消（防其中途转回竖屏打断进全屏链）
    OrientationArbiter.cancel();
    const gen: number = OrientationArbiter.generation;
    const win: window.Window | undefined = WindowModeHelper.mainWindow();
    if (win === undefined) {
      return -1;
    }
    OrientationArbiter.enterWindow = win;
    hilog.info(0x0000, 'TucaoArbiter', 'requestEnter: LANDSCAPE sent');
    win.setPreferredOrientation(window.Orientation.LANDSCAPE).catch((): void => {
      // 忽略：窗口可能正在销毁（几何未变，走降级路径）
    });
    return gen;
  }

  /** 进全屏第 2 步（§3.1 步骤 3-5，与第 1 步同帧发起后可等待）：几何稳定确认
   *  （超时一次 UNSPECIFIED 重置 + 重发兜底）。
   *  返回 true = 横屏几何已稳定；false = 降级（重发后仍未翻转/被作废），
   *  调用方按当前几何强行推进（退化为现状相位，保底可用）。gen<0 恒 false */
  static async awaitEnterStable(gen: number): Promise<boolean> {
    if (gen < 0) {
      return false;
    }
    if (await OrientationArbiter.awaitLandscapeStable(gen, OrientationArbiter.ENTER_TIMEOUT_MS)) {
      hilog.info(0x0000, 'TucaoArbiter', 'requestEnter: landscape stable');
      return true;
    }
    if (gen !== OrientationArbiter.generation) {
      return false;
    }
    const win: window.Window | undefined = OrientationArbiter.enterWindow;
    if (win === undefined) {
      return false;
    }
    // 粘性兜底（§3.1）：LANDSCAPE 被容器换算丢弃 → UNSPECIFIED 重置 + 重发（单次即止）
    hilog.warn(0x0000, 'TucaoArbiter', 'requestEnter: timeout, sticky reset + resend LANDSCAPE');
    win.setPreferredOrientation(window.Orientation.UNSPECIFIED).catch((): void => {
      // 忽略
    });
    win.setPreferredOrientation(window.Orientation.LANDSCAPE).catch((): void => {
      // 忽略
    });
    const second: boolean =
      await OrientationArbiter.awaitLandscapeStable(gen, OrientationArbiter.ENTER_TIMEOUT_MS);
    if (!second && gen === OrientationArbiter.generation) {
      hilog.warn(0x0000, 'TucaoArbiter', 'requestEnter: degrade, landscape unconfirmed');
    }
    return second;
  }

  /** 进全屏（§3.1，整体等待式兼容入口）：beginEnter + awaitEnterStable 连跑。
   *  缓存窗口不可达时回退 getLastWindow IPC 路径（语义与拆分前一致）。返回
   *  true = 横屏几何已稳定；false = 降级/被作废，调用方按当前几何强行推进 */
  static async requestEnter(): Promise<boolean> {
    const gen: number = OrientationArbiter.beginEnter();
    if (gen >= 0) {
      return OrientationArbiter.awaitEnterStable(gen);
    }
    // 回退：缓存窗口缺失（init 前/异常时序）——原 getLastWindow 整体路径
    OrientationArbiter.cancel();
    const legacyGen: number = OrientationArbiter.generation;
    const context = AppContextHolder.get();
    if (context === null) {
      return false;
    }
    let mainWindow: window.Window;
    try {
      mainWindow = await window.getLastWindow(context);
    } catch (_err) {
      return false;
    }
    if (legacyGen !== OrientationArbiter.generation) {
      return false;
    }
    OrientationArbiter.enterWindow = mainWindow;
    hilog.info(0x0000, 'TucaoArbiter', 'requestEnter: LANDSCAPE sent');
    mainWindow.setPreferredOrientation(window.Orientation.LANDSCAPE).catch((): void => {
      // 忽略：窗口可能正在销毁（几何未变，走降级路径）
    });
    return OrientationArbiter.awaitEnterStable(legacyGen);
  }

  /** 退/中断归还（§3.2/§3.5）：窗口方向唯一归还通道。同目标在途时幂等 no-op；
   *  异目标/在途 enter 等待则作废旧序列重启。
   *  【退向提速】缓存窗口快路径：主窗口经 WindowModeHelper 缓存句柄同步派发
   *  第一拍（省 getLastWindow IPC 往返 ~5ms；restoreNodeHost 在 850ms 死线
   *  收尾触发的紧贴场景下，beat1 发出越早竖屏旋转越早落地）；缓存缺失
   *  （init 前/异常时序）回退 getLastWindow 异步原路径，语义不变 */
  static requestRestore(restore: window.Orientation): void {
    if (OrientationArbiter.restoreActive && OrientationArbiter.restoreTarget === restore) {
      return;
    }
    OrientationArbiter.cancel();
    const gen: number = OrientationArbiter.generation;
    OrientationArbiter.restoreTarget = restore;
    OrientationArbiter.restoreActive = true;
    const cached: window.Window | undefined = WindowModeHelper.mainWindow();
    if (cached !== undefined) {
      OrientationArbiter.dispatchRestore(cached, restore, gen);
      return;
    }
    const context = AppContextHolder.get();
    if (context === null) {
      OrientationArbiter.restoreActive = false;
      return;
    }
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      if (gen !== OrientationArbiter.generation) {
        return;
      }
      OrientationArbiter.dispatchRestore(mainWindow, restore, gen);
    }).catch((): void => {
      if (gen === OrientationArbiter.generation) {
        OrientationArbiter.restoreActive = false;
      }
    });
  }

  /** requestRestore 派发主体（取得窗口句柄后执行，原 then 块整体迁移）：
   *  - PORTRAIT：第一拍立即发目标值（健康容器即刻翻转）+ 阶梯步进挂 RESTORE_START_DELAY_MS
   *  - 传感器跟随：beat1 UNSPECIFIED 重置 + SENSOR_GAP_MS 后 beat2 目标值 */
  private static dispatchRestore(mainWindow: window.Window, restore: window.Orientation,
    gen: number): void {
    if (restore === window.Orientation.PORTRAIT) {
      // 第一拍（原通道 A 并入）：健康容器（无粘性换算态）即刻翻转
      hilog.info(0x0000, 'TucaoArbiter', 'requestRestore: PORTRAIT first beat');
      mainWindow.setPreferredOrientation(window.Orientation.PORTRAIT).catch((): void => {
        // 忽略：窗口可能正在销毁
      });
      OrientationArbiter.track(setTimeout((): void => {
        OrientationArbiter.ladderStep(mainWindow, restore, 0, gen);
      }, OrientationArbiter.RESTORE_START_DELAY_MS));
    } else {
      // 传感器跟随支路（平板/折叠）：无确定目标几何不做校验，单次两步。
      // 【B8】两拍 INFO 留痕：退向旋转冻结恢复时序核对（beat1 重置发出 →
      // beat2 跟随声明发出 → 窗口竖屏几何事件 → 详情页首拍冻结）全链路可观测
      hilog.info(0x0000, 'TucaoArbiter', 'requestRestore: sensor beat1 UNSPECIFIED reset');
      mainWindow.setPreferredOrientation(window.Orientation.UNSPECIFIED).catch((): void => {
        // 忽略：窗口可能正在销毁
      });
      OrientationArbiter.track(setTimeout((): void => {
        if (gen !== OrientationArbiter.generation) {
          return;
        }
        hilog.info(0x0000, 'TucaoArbiter', 'requestRestore: sensor beat2 target sent');
        mainWindow.setPreferredOrientation(restore).catch((): void => {
          // 忽略：窗口可能正在销毁
        });
        OrientationArbiter.restoreActive = false;
      }, OrientationArbiter.SENSOR_GAP_MS));
    }
  }

  /** 作废在途序列（进全屏转场/新播放页进入/新归还启动前）：清计时器 + 自增代号，
   *  在途 requestEnter 轮询与阶梯步进在下一个见代检查点静默退场 */
  static cancel(): void {
    for (let i: number = 0; i < OrientationArbiter.timers.length; i++) {
      clearTimeout(OrientationArbiter.timers[i]);
    }
    OrientationArbiter.timers = [];
    OrientationArbiter.generation++;
    OrientationArbiter.restoreActive = false;
    OrientationArbiter.restoreTarget = window.Orientation.UNSPECIFIED;
    OrientationArbiter.enterWindow = undefined;
  }

  /** 几何稳定确认：轮询 GlobalState（EntryAbility windowSizeChange 实时写入），
   *  宽>高后静默一拍再采样一致才认稳定；超时返回 false。见代即退（序列已作废） */
  private static async awaitLandscapeStable(gen: number, timeoutMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      await OrientationArbiter.sleep(OrientationArbiter.ENTER_POLL_GAP_MS);
      if (gen !== OrientationArbiter.generation) {
        return false;
      }
      const win: WindowSizeInfo = GlobalState.windowSizeInfo();
      if (win.windowWidthVp > win.windowHeightVp && win.windowHeightVp > 0) {
        const wVp: number = win.windowWidthVp;
        const hVp: number = win.windowHeightVp;
        await OrientationArbiter.sleep(OrientationArbiter.ENTER_STABLE_BEAT_MS);
        if (gen !== OrientationArbiter.generation) {
          return false;
        }
        const beat: WindowSizeInfo = GlobalState.windowSizeInfo();
        if (beat.windowWidthVp === wVp && beat.windowHeightVp === hVp) {
          return true;
        }
        // 稳定拍内又有新尺寸事件（旋转抖动）：继续轮询
      }
    }
    return false;
  }

  /** 阶梯步（粘性容器唯一可靠通道，验证语义原样保留）：UNSPECIFIED 重置 →
   *  间隔 → 目标值 → 几何校验（翻回竖屏/阶梯耗尽即停，未翻回进下一阶）；
   *  每步见代自检（被新序列取代时静默退场） */
  private static ladderStep(mainWindow: window.Window, restore: window.Orientation,
    stage: number, gen: number): void {
    if (gen !== OrientationArbiter.generation) {
      return;
    }
    mainWindow.setPreferredOrientation(window.Orientation.UNSPECIFIED).catch((): void => {
      // 忽略：窗口可能正在销毁
    });
    const lastStage: number = OrientationArbiter.LADDER_GAPS_MS.length - 1;
    const gap: number = stage < lastStage ?
      OrientationArbiter.LADDER_GAPS_MS[stage] : OrientationArbiter.LADDER_GAPS_MS[lastStage];
    OrientationArbiter.track(setTimeout((): void => {
      if (gen !== OrientationArbiter.generation) {
        return;
      }
      hilog.info(0x0000, 'TucaoArbiter', 'restore ladder stage %{public}d: reset + PORTRAIT', stage);
      mainWindow.setPreferredOrientation(restore).catch((): void => {
        // 忽略：窗口可能正在销毁
      });
      OrientationArbiter.track(setTimeout((): void => {
        if (gen !== OrientationArbiter.generation) {
          return;
        }
        const win: WindowSizeInfo = GlobalState.windowSizeInfo();
        if (win.windowHeightVp > win.windowWidthVp || stage >= lastStage) {
          // 已翻回竖屏 / 阶梯耗尽：结束
          hilog.info(0x0000, 'TucaoArbiter', 'restore finished at stage %{public}d', stage);
          OrientationArbiter.restoreActive = false;
          return;
        }
        OrientationArbiter.ladderStep(mainWindow, restore, stage + 1, gen);
      }, OrientationArbiter.VERIFY_DELAY_MS));
    }, gap));
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  private static track(timerId: number): void {
    OrientationArbiter.timers.push(timerId);
  }
}

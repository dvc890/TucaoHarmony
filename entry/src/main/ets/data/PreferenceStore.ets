/**
 * 偏好存储（PersistenceV2）
 * - preferences:player_config → PlayerConfig（全量 @Trace，变更自动持久化）
 * - preferences:user → User（登录会话摘要）
 * 懒初始化：首次访问时 globalConnect（避开 Ability 早期无 UI 上下文阶段）；
 * connect 失败时回退为内存实例（功能可用，仅本次不落盘）。
 */
import { PersistenceV2, ConnectOptions } from '@kit.ArkUI';
import { PlayerConfig, User } from '../model/entity/BaseEntities';
import { PrefKey } from '../common/Constants';

export class PreferenceStore {
  private static playerConfigInstance: PlayerConfig | undefined = undefined;
  private static userInstance: User | undefined = undefined;

  /** 播放器配置单例 */
  static playerConfig(): PlayerConfig {
    if (PreferenceStore.playerConfigInstance === undefined) {
      const options: ConnectOptions<PlayerConfig> = {
        type: PlayerConfig,
        key: PrefKey.PLAYER_CONFIG,
        defaultCreator: (): PlayerConfig => new PlayerConfig()
      };
      const connected: PlayerConfig | undefined = PersistenceV2.globalConnect(options);
      PreferenceStore.playerConfigInstance = connected ?? new PlayerConfig();
    }
    return PreferenceStore.playerConfigInstance;
  }

  /** 用户单例 */
  static user(): User {
    if (PreferenceStore.userInstance === undefined) {
      const options: ConnectOptions<User> = {
        type: User,
        key: PrefKey.USER,
        defaultCreator: (): User => new User()
      };
      const connected: User | undefined = PersistenceV2.globalConnect(options);
      PreferenceStore.userInstance = connected ?? new User();
    }
    return PreferenceStore.userInstance;
  }

  /** 立即落盘播放器配置（批量修改后调用；@Trace 变更本会自动持久化） */
  static savePlayerConfig(): void {
    try {
      PersistenceV2.save(PrefKey.PLAYER_CONFIG);
    } catch (err) {
      // 忽略手动落盘失败
    }
  }

  /** 立即落盘用户 */
  static saveUser(): void {
    try {
      PersistenceV2.save(PrefKey.USER);
    } catch (err) {
      // 忽略手动落盘失败
    }
  }
}

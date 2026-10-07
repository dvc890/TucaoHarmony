/**
 * 全局常量与枚举定义
 * 端点与参数以 plan.md「Contracts & Interfaces」端点表为准（对齐安卓版 ApiConfig.kt，禁止改动后端协议）
 */

/** 站点协议与域名 */
export class Host {
  static readonly PROTOCOL: string = 'https';
  static readonly BASE_URL: string = 'www.tucao.my';
  /** 站点根地址（HTML 抓取页基地址） */
  static readonly BASE_RAW_API_URL: string = `https://www.tucao.my/`;
  /** api_v2 JSON 接口基地址 */
  static readonly BASE_JSON_API_URL: string = `https://www.tucao.my/api_v2/`;

  /** 视频网页版详情页 URL（分享用，与安卓版 ApiConfig.VIDEO_URL 同构；
   *  对端未装本应用时浏览器打开兜底，全链路永不失败） */
  static videoShareUrl(hid: string): string {
    return `${Host.BASE_RAW_API_URL}play/h${hid}/`;
  }
}

/** api_v2 通用注入参数 */
export class ApiParams {
  static readonly API_KEY: string = '25tids8f1ew1821ed';
  static readonly TYPE_JSON: string = 'json';
}

/** api_v2 JSON 端点（相对 BASE_JSON_API_URL） */
export class JsonApi {
  static readonly LIST: string = 'list.php';
  static readonly SEARCH: string = 'search.php';
  static readonly VIEW: string = 'view.php';
  // rank.php 已被站点废弃（合法参数返回 504），排行榜改走 RawApi hot.html 网页体系
  /** 评论楼中楼（绝对地址） */
  static readonly REPLY: string = 'https://www.tucao.my/index.php?m=comment&c=index&a=ajax';
}

/** XML 端点 */
export class XmlApi {
  /** 播放地址（type/vid/r 查询参数由调用方构造） */
  static readonly PLAY_URL: string = 'https://www.tucao.my/api/playurl';
  /** 弹幕拉取 */
  static readonly DANMU_INIT: string = 'https://www.tucao.my/index.php?m=mukio&c=index&a=init';
}

/** HTML 抓取端点（相对 BASE_RAW_API_URL，请求需带 Cookie: tucao_verify=ok） */
export class RawApi {
  /** 首页（推荐频道） */
  static readonly INDEX: string = '/';
  /** 频道列表页，{tid} 由调用方替换 */
  static readonly LIST: string = 'list/{tid}/';
  /** 新番放送表 */
  static readonly BGM: string = 'bgm/';
  /** 历史新番查询页 */
  static readonly BGM_LIST: string = 'bgm/list/';
  /** 排行榜（主榜；可选 ?p={catid} 分类过滤，无参数=全站） */
  static readonly HOT: string = 'html/hot.html';
  /** 追番榜 */
  static readonly FAV_HOT: string = 'html/fav_hot.html';
  /** 弹幕榜（角标=弹幕数） */
  static readonly DANMU_HOT: string = 'html/danmu.html';
  /** 在线榜（实时在线人数，无区块单列表） */
  static readonly ONLINE: string = 'html/ol.html';
  /** 神评论榜（视频 + 热门评论） */
  static readonly DIGG: string = 'html/digg.html';
  /** 无人区（分类区块：连载新番/天朝出品/日剧/电影） */
  static readonly ZERO: string = 'html/zero.html';
  /** u榜（用户榜：失足/存活/中出/观点/话唠五栏） */
  static readonly USER_HOT: string = 'html/user_hot.html';
  /** 热搜榜（关键词榜） */
  static readonly HOT_SEARCH: string = 'html/hot_search.html';
  /** 发送弹幕 */
  static readonly SEND_DANMU: string = 'index.php?m=mukio&c=index&a=post';
  /** 评论列表（HTML 分页） */
  static readonly COMMENT: string = 'index.php?m=comment&c=index&a=init&hot=0&iframe=1';
  /** 发表评论 */
  static readonly SEND_COMMENT: string = 'index.php?m=comment&c=index&a=post';
  /** 楼中楼回复（同评论端点，沿用原版 replyuid=undefined 后缀） */
  static readonly SEND_REPLY: string = 'index.php?m=comment&c=index&a=post&replyuid=undefined';
  /** 评论点赞 */
  static readonly SUPPORT: string = 'index.php?m=comment&c=index&a=support&format=json';
  /** 私信收件箱 */
  static readonly MESSAGE_INBOX: string = 'index.php?m=message&c=index&a=inbox';
  /** 私信会话明细 */
  static readonly MESSAGE_READ: string = 'index.php?m=message&c=index&a=read';
  /** 私信回复 */
  static readonly MESSAGE_REPLY: string = 'index.php?m=message&c=index&a=reply';
  /** 用户信息 */
  static readonly USER_INFO: string = 'api.php?op=user';
  /** 图形验证码（code_len/font_size/width/height 沿用原版） */
  static readonly CHECKCODE: string = 'api.php?op=checkcode&code_len=4&font_size=14&width=446&height=40';
  /** 登录 */
  static readonly LOGIN: string = 'index.php?m=member&c=index&a=login';
  /** 退出登录 */
  static readonly LOGOUT: string = 'index.php?m=member&c=index&a=logout&forward=&siteid=1';
  /** 注册 */
  static readonly REGISTER: string = 'index.php?m=member&c=index&a=register&siteid=1';
  /** 个人中心入口 */
  static readonly PERSONAL: string = 'index.php?m=member&c=index';
  /** UP 主空间视频页，{userid} 由调用方替换 */
  static readonly USER: string = 'play/u{userid}/';
  /** 视频播放页，{hid} 由调用方替换 */
  static readonly VIDEO: string = 'play/h{hid}/';
  /** 用户空间 */
  static readonly SPACE: string = 'index.php?m=member&c=space';
  /** 资料修改 */
  static readonly CHANGE_INFO: string = 'index.php?m=member&c=index&a=account_manage_info&t=account';
  /** 密码修改 */
  static readonly CHANGE_PASSWORD: string = 'index.php?m=member&c=index&a=account_manage_password&t=account';
  /** 忘记密码 */
  static readonly FORGOT_PASSWORD: string = 'index.php?m=member&c=index&a=public_forget_password&siteid=1';
  /** 注册查重：账号 */
  static readonly CHECK_USERNAME: string = 'index.php?clientid=username&m=member&c=index&a=public_checkname_ajax';
  /** 注册查重：昵称 */
  static readonly CHECK_NICKNAME: string = 'index.php?clientid=nickname&m=member&c=index&a=public_checknickname_ajax';
  /** 注册查重：邮箱 */
  static readonly CHECK_EMAIL: string = 'index.php?clientid=email&m=member&c=index&a=public_checkemail_ajax';
  /** 头像回执 */
  static readonly MANAGE_AVATAR: string = 'index.php?m=member&c=index&a=account_manage_avatar&t=account';
  /** 头像上传（phpsso 八进制流接口） */
  static readonly UPLOAD_AVATAR: string = 'phpsso_server/index.php?m=phpsso&c=index&a=uploadavatar&auth_data=v=1&appid=1';
}

/** HTTP 约定头 */
export class HttpConst {
  /** 抓取页必需的验证 Cookie */
  static readonly TUCAO_VERIFY_COOKIE: string = 'tucao_verify=ok';
  /** clicli 解析接口使用的桌面 Chrome UA */
  static readonly CHROME_UA: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.110 Safari/537.36';
  /** 移动 Chrome UA（通用 HTML 抓取） */
  static readonly MOBILE_UA: string =
    'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';
}

/** 频道（6 父频道 + 子频道树，typeid 对齐站点） */
export class Channel {
  readonly id: number;
  readonly name: string;
  readonly parentId: number | undefined;

  constructor(id: number, name: string, parentId?: number) {
    this.id = id;
    this.name = name;
    this.parentId = parentId;
  }

  /** 父频道 id（子频道归并到父频道） */
  getValidParentId(): number {
    return this.parentId !== undefined ? this.parentId : this.id;
  }
}

/** 频道静态表（与安卓版 Channel.kt 完全一致） */
export class ChannelTable {
  static readonly ALL: Channel[] = [
    new Channel(19, '动画'),
    new Channel(28, 'MAD·AMV·GMV', 19),
    new Channel(6, 'MMD·3D', 19),
    new Channel(25, '原创·配音', 19),
    new Channel(29, '综合·周边·其他', 19),
    new Channel(20, '音乐'),
    new Channel(7, 'acg音乐', 20),
    new Channel(31, '翻唱·原唱', 20),
    new Channel(37, '舞蹈', 20),
    new Channel(30, 'VOCALOID·UTAU', 20),
    new Channel(40, '演奏·乐器', 20),
    new Channel(88, 'op·ed·ost·角色歌', 20),
    new Channel(52, 'Live·声优相关', 20),
    new Channel(21, '游戏'),
    new Channel(8, '游戏影像', 21),
    new Channel(34, '网络游戏', 21),
    new Channel(44, '单机游戏', 21),
    new Channel(33, '电子竞技', 21),
    new Channel(42, '家机·掌机·手机', 21),
    new Channel(22, '三次元'),
    new Channel(9, '喜闻乐见', 22),
    new Channel(32, '娱乐鬼畜', 22),
    new Channel(57, '科技·数码', 22),
    new Channel(61, '运动体育', 22),
    new Channel(65, '军事情报', 22),
    new Channel(15, '宠物·猫·狗', 22),
    new Channel(23, '影剧'),
    new Channel(39, '电视剧', 23),
    new Channel(38, '电影', 23),
    new Channel(16, '综艺娱乐', 23),
    new Channel(27, '完结剧集', 23),
    new Channel(24, '新番'),
    new Channel(11, '连载新番', 24),
    new Channel(43, '天朝出品', 24),
    new Channel(26, 'OAD·OVA·剧场版', 24),
    new Channel(10, '完结番组', 24)
  ];

  /** 按 typeid 查找频道 */
  static find(tid: number): Channel | undefined {
    return ChannelTable.ALL.find((c: Channel) => c.id === tid);
  }

  /** 取自身与同父的兄弟频道（频道详情页 Tab 用） */
  static findSiblingChannels(tid: number): Channel[] {
    return ChannelTable.ALL.filter((c: Channel) => tid === c.id || tid === c.parentId);
  }

  /** 全部父频道（频道宫格用） */
  static findAllParentChannels(): Channel[] {
    return ChannelTable.ALL.filter((c: Channel) => c.parentId === undefined);
  }

  /** 按 typeid 取频道名（未知返回空串） */
  static nameOf(tid: number): string {
    const c: Channel | undefined = ChannelTable.find(tid);
    return c !== undefined ? c.name : '';
  }
}

/** 首页频道与"我的"Tab 定义 */
export class HomeTab {
  static readonly RECOMMEND: number = 0;
  static readonly BANGUMI: number = 1;
  static readonly MOVIE: number = 2;
  static readonly GAME: number = 3;
  static readonly ANIMATION: number = 4;
  static readonly CHANNEL: number = 5;
  /** "我的"（手机 Tab / 中屏 rail / 大屏内容区虚拟频道；SideNavView 常驻侧栏亦含同源功能清单） */
  static readonly MINE: number = 6;

  /** Tab 标题（顺序即 Tab 顺序；末位"我的"承载安卓 Drawer 菜单功能） */
  static readonly TITLES: string[] = ['推荐', '新番', '影剧', '游戏', '动画', '频道', '我的'];

  /** 新番/影剧/游戏/动画四频道对应的站点列表页 tid */
  static readonly LIST_TIDS: Record<string, number> = {
    '1': 24,
    '2': 23,
    '3': 21,
    '4': 19
  };
}

/** 列表排序（api_v2 order 查询参数值） */
export enum SortOrder {
  /** 发布时间 */
  DATE = 'date',
  /** 弹幕数 */
  MUKIO = 'mukio',
  /** 播放数 */
  PLAY = 'play'
}

/** 排序显示文案 */
export class SortOrderText {
  static readonly ALL: Record<string, string> = {
    'date': '发布时间',
    'mukio': '弹幕数',
    'play': '播放数'
  };

  static of(order: SortOrder): string {
    return SortOrderText.ALL[order] ?? '发布时间';
  }
}

/** 排行榜主榜分类（hot.html 的 ?p= 参数；仅作用于主榜，其余榜单无分类） */
export class RankCategory {
  readonly label: string;
  /** ?p= 参数值（空串 = 全站，不携带参数） */
  readonly pValue: string;

  constructor(label: string, pValue: string) {
    this.label = label;
    this.pValue = pValue;
  }

  /** 全部分类（顺序即 chip 顺序） */
  static readonly ALL: RankCategory[] = [
    new RankCategory('全站', ''),
    new RankCategory('连载新番', '11'),
    new RankCategory('完结番组', '10'),
    new RankCategory('剧场版', '26'),
    new RankCategory('电影', '38'),
    new RankCategory('电视剧', '39'),
    new RankCategory('天朝出品', '43')
  ];

  /** 默认分类（全站） */
  static defaultCategory(): RankCategory {
    return RankCategory.ALL[0];
  }

  /** 按下标取分类（越界回退全站） */
  static at(index: number): RankCategory {
    if (index >= 0 && index < RankCategory.ALL.length) {
      return RankCategory.ALL[index];
    }
    return RankCategory.defaultCategory();
  }

  /** 按分类取下标（chip 选中态用） */
  static indexOfCategory(category: RankCategory): number {
    for (let i = 0; i < RankCategory.ALL.length; i++) {
      if (RankCategory.ALL[i].pValue === category.pValue) {
        return i;
      }
    }
    return 0;
  }
}

/** 搜索频道筛选（全部 + 6 父频道，对齐安卓版） */
export class SearchChannelFilter {
  static readonly ALL: Record<string, string> = {
    '0': '全部分类',
    '19': '动画',
    '20': '音乐',
    '21': '游戏',
    '22': '三次元',
    '23': '影剧',
    '24': '新番'
  };
}

/** 分集来源类型 */
export enum PartSourceType {
  /** 直连地址 */
  DIRECT = 0,
  /** clicli 解析 */
  CLICLI = 1,
  /** 标准播放地址接口（playurl XML） */
  PLAYURL = 2
}

/** 本地 JSON 存储键名（files 目录下的文件名） */
export class StoreFile {
  static readonly DOWNLOAD_CATALOG: string = 'download_catalog.json';
  static readonly STAR: string = 'star.json';
  static readonly HISTORY: string = 'history.json';
  static readonly SEARCH_HISTORY: string = 'search_history.json';
  /** 屏蔽词列表 */
  static readonly BLOCK_LIST: string = 'block_list.json';
}

/** PersistenceV2 持久化键名 */
export class PrefKey {
  static readonly PLAYER_CONFIG: string = 'preferences:player_config';
  static readonly USER: string = 'preferences:user';
  /** 用户自选下载目录（无则用应用沙箱） */
  static readonly DOWNLOAD_DIR: string = 'preferences:download_dir';
}

/** 弹幕 player 约定：user=test 沿用原版宽松行为 */
export class DanmuConst {
  static readonly DEFAULT_USER: string = 'test';
  /** 默认屏蔽词 */
  static readonly DEFAULT_BLOCK_WORDS: string[] = ['http'];
}

/** 下载目录约定：{下载目录}/{hid}/p{order}/，弹幕文件 danmu.xml */
export class DownloadPath {
  static readonly DANMU_FILE: string = 'danmu.xml';

  /** 分集目录名：p1、p2… */
  static partDirName(order: number): string {
    return `p${order}`;
  }

  /** 分集目录相对路径 */
  static partRelativePath(hid: string, order: number): string {
    return `${hid}/${DownloadPath.partDirName(order)}`;
  }
}

/** 播放器 id 约定（对齐安卓版 generatePlayerId） */
export class PlayerId {
  static generate(hid: string, part: number): string {
    return `11-${hid}-1-${part}`;
  }
}

/** 清晰度选项（playurl 接口 src 参数；仅 PLAYURL 类型分集可选，直连分集自动隐藏清晰度菜单） */
export class QualityOption {
  readonly src: string;
  readonly label: string;

  constructor(src: string, label: string) {
    this.src = src;
    this.label = label;
  }
}

/** 清晰度集合（站点默认 src=2 起；当前站点内容以直连为主，菜单多数场景隐藏） */
export class QualityTable {
  static readonly ALL: QualityOption[] = [
    new QualityOption('2', '高清'),
    new QualityOption('3', '超清')
  ];

  static labelOf(src: string): string {
    for (let i = 0; i < QualityTable.ALL.length; i++) {
      if (QualityTable.ALL[i].src === src) {
        return QualityTable.ALL[i].label;
      }
    }
    return '默认';
  }
}

/** 画面缩放选项（全屏播放；mode 供 VM/页面布局分支使用） */
export class ScaleModeOption {
  readonly mode: string;
  readonly label: string;

  constructor(mode: string, label: string) {
    this.mode = mode;
    this.label = label;
  }
}

/** 画面缩放集合（fit=原比例留黑边；16:9/4:3=强制画面框比例；fill=保持比例裁剪撑满） */
export class ScaleTable {
  static readonly ALL: ScaleModeOption[] = [
    new ScaleModeOption('fit', '原比例'),
    new ScaleModeOption('16:9', '16:9'),
    new ScaleModeOption('4:3', '4:3'),
    new ScaleModeOption('fill', '撑满')
  ];

  static labelOf(mode: string): string {
    for (let i = 0; i < ScaleTable.ALL.length; i++) {
      if (ScaleTable.ALL[i].mode === mode) {
        return ScaleTable.ALL[i].label;
      }
    }
    return '原比例';
  }
}


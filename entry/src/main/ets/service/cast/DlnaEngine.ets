/**
 * 自研 DLNA 投屏引擎（兜底通道）
 * - 设备发现：SSDP M-SEARCH(ssdp:all, MX 3) → USN 去重 → 拉取 LOCATION 描述 XML →
 *   解析 friendlyName + AVTransport/RenderingControl 控制地址 → 仅保留含 AVTransport 的设备
 * - 投放：SetAVTransportURI(不带 DIDL 元数据，规避 XML 转义) + Play；多段视频段链式投放
 * - 控制：SOAP AVTransport:1 Play/Pause/Stop/Seek(REL_TIME)；RenderingControl 音量(0-100)
 * - 进度：1s 轮询 GetPositionInfo + GetTransportInfo；段播完续投下一段；
 *   连续 3 次 SOAP 失败或设备端 STOPPED（非段尾）→ 判离线断开，携带恢复位置
 * - 本地文件：经内置 LocalHttpServer 推流（TCPSocketServer，固定端口候选 8437/18437/28437，
 *   Range/206 分块推送；本机 IP 经 UDP 发包后 getLocalAddress 解析）
 * - DLNA 通道不接管 AVSession（播控中心命令冲突由 CastVM 守卫暂停本机播放）
 */
import { socket, http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CastChannel, CastDevice, CastMediaTarget, CastRemoteState } from './CastController';

/** DLNA 引擎回调（CastVM 注入） */
export class DlnaEngineCallbacks {
  /** 发现设备列表快照（渐进式：每解析成功一台即推送全量快照） */
  onDevicesFound: ((devices: CastDevice[]) => void) | null = null;
  /** 远端状态镜像变化（进度/时长为整集总时位） */
  onRemoteStateChanged: ((state: CastRemoteState) => void) | null = null;
  /** 断开（携带恢复用整集总时位 ms） */
  onDisconnected: ((resumePositionMs: number) => void) | null = null;
  /** 错误提示 */
  onError: ((message: string) => void) | null = null;
}

/** 本地 HTTP 推流单例（DLNA 渲染器拉流本端文件） */
export class LocalHttpServer {
  private static instance: LocalHttpServer | undefined;

  static getInstance(): LocalHttpServer {
    if (LocalHttpServer.instance === undefined) {
      LocalHttpServer.instance = new LocalHttpServer();
    }
    return LocalHttpServer.instance;
  }

  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private localIp: string = '';
  /** token → 本地文件路径 */
  private readonly fileMap: Map<string, string> = new Map();
  /** clientId → 推流任务 */
  private readonly tasks: Map<number, HttpServeTask> = new Map();

  private constructor() {
  }

  /** 推流服务是否已启动 */
  isRunning(): boolean {
    return this.server !== null;
  }

  /**
   * 启动推流服务（幂等）
   * @return 基础地址 http://ip:port；启动失败返回 null
   */
  async start(): Promise<string | null> {
    if (this.server !== null) {
      return this.baseUrl();
    }
    let ip: string = this.localIp;
    if (ip.length === 0) {
      ip = await LocalHttpServer.resolveLocalIp();
      if (ip.length === 0) {
        return null;
      }
      this.localIp = ip;
    }
    // 固定端口候选（TCP server 无查询已分配端口 API）
    const candidates: number[] = [8437, 18437, 28437];
    for (let i: number = 0; i < candidates.length; i++) {
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      const addr: socket.NetAddress = { address: '0.0.0.0', port: candidates[i] };
      try {
        await server.listen(addr);
        this.server = server;
        this.port = candidates[i];
        this.registerServerEvents(server);
        return this.baseUrl();
      } catch (err) {
        // 端口占用 → 尝试下一候选
      }
    }
    return null;
  }

  /** 注册本地文件，返回可被渲染器访问的 URL */
  registerFile(path: string): string | null {
    if (this.server === null) {
      return null;
    }
    const token: string = `${Date.now().toString(36)}${Math.floor(Math.random() * 1000000).toString(36)}`;
    this.fileMap.set(token, path);
    return `${this.baseUrl()}/f/${token}/video.mp4`;
  }

  /** 注销全部文件（断开投屏时调用） */
  clearFiles(): void {
    this.fileMap.clear();
  }

  /** 基础地址 */
  private baseUrl(): string {
    return `http://${this.localIp}:${this.port}`;
  }

  /** 解析本机局域网 IP：UDP 向组播地址发包后 getLocalAddress */
  private static async resolveLocalIp(): Promise<string> {
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    try {
      try {
        await udp.bind({ address: '0.0.0.0' } as socket.NetAddress);
      } catch (err) {
        await udp.bind({ address: '0.0.0.0', port: 0 } as socket.NetAddress);
      }
      const target: socket.NetAddress = { address: '239.255.255.250', port: 1900 };
      const options: socket.UDPSendOptions = { data: 'DISCOVER', address: target };
      await udp.send(options);
      const local: socket.NetAddress = await udp.getLocalAddress();
      if (local.address.length > 0 && local.address !== '0.0.0.0') {
        return local.address;
      }
      return '';
    } catch (err) {
      return '';
    } finally {
      try {
        await udp.close();
      } catch (err) {
        // 忽略
      }
    }
  }

  /** server 事件：接入连接 → 解析 HTTP 请求 → 应答/推流 */
  private registerServerEvents(server: socket.TCPSocketServer): void {
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      const state: ConnState = new ConnState();
      state.clientId = conn.clientId;
      conn.on('message', (info: socket.SocketMessageInfo): void => {
        state.buffer += LocalHttpServer.ab2text(info.message);
        const headerEnd: number = state.buffer.indexOf('\r\n\r\n');
        if (headerEnd >= 0 && !state.responded) {
          state.responded = true;
          this.handleRequest(conn, state.buffer.substring(0, headerEnd));
        }
      });
      conn.on('close', (): void => {
        this.abortTask(conn.clientId);
      });
      conn.on('error', (err: BusinessError): void => {
        this.abortTask(conn.clientId);
      });
    });
    server.on('error', (err: BusinessError): void => {
      // 监听异常：标记服务不可用（下次 start 重建）
      this.server = null;
    });
  }

  /** 解析请求行 + Range 头，应答并分块推送 */
  private handleRequest(conn: socket.TCPSocketConnection, rawHeader: string): void {
    const lines: string[] = rawHeader.split('\r\n');
    if (lines.length === 0) {
      this.respond404(conn);
      return;
    }
    const requestLine: string[] = lines[0].split(' ');
    if (requestLine.length < 2) {
      this.respond404(conn);
      return;
    }
    const method: string = requestLine[0].toUpperCase();
    const path: string = requestLine[1];
    // 路由：/f/{token}/{name}
    const parts: string[] = path.split('/');
    if (parts.length < 4 || parts[1] !== 'f') {
      this.respond404(conn);
      return;
    }
    const token: string = parts[2];
    const filePath: string | undefined = this.fileMap.get(token);
    if (filePath === undefined) {
      this.respond404(conn);
      return;
    }
    // Range 头解析
    let start: number = 0;
    let endInclusive: number = -1;
    for (let i: number = 1; i < lines.length; i++) {
      const header: string = lines[i];
      const idx: number = header.indexOf(':');
      if (idx < 0) {
        continue;
      }
      const name: string = header.substring(0, idx).trim().toLowerCase();
      const value: string = header.substring(idx + 1).trim();
      if (name === 'range') {
        const match: RegExpMatchArray | null = value.match(/bytes=(\d+)-(\d*)/);
        if (match !== null && match.length >= 2) {
          start = Number(match[1]);
          if (match.length >= 3 && match[2] !== undefined && match[2].length > 0) {
            endInclusive = Number(match[2]);
          }
        }
      }
    }
    try {
      const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const total: number = stat.size;
      if (start >= total) {
        fileIo.closeSync(file);
        this.respond416(conn, total);
        return;
      }
      const end: number = endInclusive >= 0 && endInclusive < total - 1 ? endInclusive : total - 1;
      const contentLength: number = end - start + 1;
      const contentType: string = LocalHttpServer.contentTypeOf(filePath);
      const statusLine: string = start > 0
        ? 'HTTP/1.1 206 Partial Content'
        : 'HTTP/1.1 200 OK';
      let header: string = `${statusLine}\r\n`;
      header += `Content-Type: ${contentType}\r\n`;
      header += `Content-Length: ${contentLength}\r\n`;
      header += 'Accept-Ranges: bytes\r\n';
      header += 'Connection: close\r\n';
      if (start > 0) {
        header += `Content-Range: bytes ${start}-${end}/${total}\r\n`;
      }
      header += '\r\n';
      const headText: string = header;
      const task: HttpServeTask = new HttpServeTask();
      task.file = file;
      task.filePos = start;
      task.end = end + 1;
      task.aborted = false;
      this.tasks.set(conn.clientId, task);
      if (method === 'HEAD') {
        conn.send({ data: headText });
        this.finishTask(conn.clientId);
        conn.close();
        return;
      }
      conn.send({ data: headText }, (): void => {
        this.sendChunk(conn, task);
      });
    } catch (err) {
      this.respond404(conn);
    }
  }

  /** 分块推送（64KB；上一块发送完成再续下一块，连接关闭即中止） */
  private sendChunk(conn: socket.TCPSocketConnection, task: HttpServeTask): void {
    if (task.aborted || task.file === null) {
      this.finishTask(conn.clientId);
      return;
    }
    const remaining: number = task.end - task.filePos;
    if (remaining <= 0) {
      this.finishTask(conn.clientId);
      conn.close();
      return;
    }
    const length: number = Math.min(65536, remaining);
    const buffer: ArrayBuffer = new ArrayBuffer(length);
    try {
      const read: number = fileIo.readSync(task.file.fd, buffer, { offset: task.filePos, length: length });
      if (read <= 0) {
        this.finishTask(conn.clientId);
        conn.close();
        return;
      }
      task.filePos += read;
      const payload: ArrayBuffer = read === length ? buffer : buffer.slice(0, read);
      conn.send({ data: payload }, (err: BusinessError): void => {
        if (err !== undefined && err !== null) {
          this.abortTask(conn.clientId);
          return;
        }
        this.sendChunk(conn, task);
      });
    } catch (err) {
      this.abortTask(conn.clientId);
    }
  }

  /** 结束任务（关闭文件句柄） */
  private finishTask(clientId: number): void {
    const task: HttpServeTask | undefined = this.tasks.get(clientId);
    if (task === undefined) {
      return;
    }
    this.tasks.delete(clientId);
    if (task.file !== null) {
      try {
        fileIo.closeSync(task.file);
      } catch (err) {
        // 忽略
      }
      task.file = null;
    }
  }

  /** 中止任务（连接关闭/发送失败） */
  private abortTask(clientId: number): void {
    const task: HttpServeTask | undefined = this.tasks.get(clientId);
    if (task !== undefined) {
      task.aborted = true;
      this.finishTask(clientId);
    }
  }

  private respond404(conn: socket.TCPSocketConnection): void {
    conn.send({ data: 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' });
    conn.close();
  }

  private respond416(conn: socket.TCPSocketConnection, total: number): void {
    conn.send({ data: `HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */${total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n` });
    conn.close();
  }

  /** ArrayBuffer → 文本（HTTP 头为 ASCII） */
  private static ab2text(buffer: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buffer);
    let text: string = '';
    const step: number = 4096;
    for (let i: number = 0; i < bytes.length; i += step) {
      const end: number = Math.min(i + step, bytes.length);
      let part: string = '';
      for (let j: number = i; j < end; j++) {
        part += String.fromCharCode(bytes[j]);
      }
      text += part;
    }
    return text;
  }

  /** 扩展名 → Content-Type */
  private static contentTypeOf(path: string): string {
    const lower: string = path.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) {
      return 'video/mp4';
    }
    if (lower.endsWith('.flv')) {
      return 'video/x-flv';
    }
    if (lower.endsWith('.ts') || lower.endsWith('.m4s')) {
      return 'video/mp2t';
    }
    if (lower.endsWith('.mkv')) {
      return 'video/x-matroska';
    }
    if (lower.endsWith('.webm')) {
      return 'video/webm';
    }
    if (lower.endsWith('.mp3')) {
      return 'audio/mpeg';
    }
    return 'application/octet-stream';
  }
}

/** 连接请求累积状态 */
class ConnState {
  clientId: number = 0;
  buffer: string = '';
  responded: boolean = false;
}

/** 单连接推流任务 */
class HttpServeTask {
  file: fileIo.File | null = null;
  filePos: number = 0;
  /** 结束位置（不含） */
  end: number = 0;
  aborted: boolean = false;
}

/** DLNA 引擎单例 */
export class DlnaEngine {
  private static instance: DlnaEngine | undefined;

  static getInstance(): DlnaEngine {
    if (DlnaEngine.instance === undefined) {
      DlnaEngine.instance = new DlnaEngine();
    }
    return DlnaEngine.instance;
  }

  readonly callbacks: DlnaEngineCallbacks = new DlnaEngineCallbacks();
  /** 发现的设备（USN → 设备） */
  private readonly foundDevices: Map<string, CastDevice> = new Map();
  private discoverySocket: socket.UDPSocket | null = null;
  private discoveryTimer: number = -1;
  private discovering: boolean = false;
  private activeDevice: CastDevice | null = null;
  private target: CastMediaTarget | null = null;
  private segmentIndex: number = 0;
  private segmentBaseMs: number = 0;
  private remoteState: CastRemoteState = new CastRemoteState();
  private pollTimer: number = -1;
  private consecutiveErrors: number = 0;
  private disconnecting: boolean = false;

  private constructor() {
  }

  /** 是否投播中 */
  isCasting(): boolean {
    return this.activeDevice !== null;
  }

  /** 当前连接设备 */
  currentDevice(): CastDevice | null {
    return this.activeDevice;
  }

  /** 是否正在发现设备 */
  isDiscovering(): boolean {
    return this.discovering;
  }

  /**
   * 开始 SSDP 设备发现（M-SEARCH ssdp:all, MX 3）
   * 响应收集约 4s 后自动停止；每解析成功一台设备即回调全量快照
   */
  async startDiscovery(): Promise<void> {
    if (this.discovering) {
      return;
    }
    this.stopDiscovery();
    this.foundDevices.clear();
    this.discovering = true;
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    this.discoverySocket = udp;
    try {
      try {
        await udp.bind({ address: '0.0.0.0' } as socket.NetAddress);
      } catch (err) {
        await udp.bind({ address: '0.0.0.0', port: 0 } as socket.NetAddress);
      }
      udp.on('message', (info: socket.SocketMessageInfo): void => {
        this.onSsdpResponse(info);
      });
      const msearch: string = 'M-SEARCH * HTTP/1.1\r\n'
        + 'HOST: 239.255.255.250:1900\r\n'
        + 'MAN: "ssdp:discover"\r\n'
        + 'MX: 3\r\n'
        + 'ST: ssdp:all\r\n'
        + '\r\n';
      const target: socket.NetAddress = { address: '239.255.255.250', port: 1900 };
      const options: socket.UDPSendOptions = { data: msearch, address: target };
      // 连发两次提高命中率
      await udp.send(options);
      await udp.send(options);
      // MX 3 + 缓冲 → 4s 后结束收集
      this.discoveryTimer = setTimeout((): void => {
        this.stopDiscovery();
      }, 4000);
    } catch (err) {
      this.discovering = false;
      this.discoverySocket = null;
      this.callbacks.onError?.('局域网搜索失败，请检查 Wi-Fi');
    }
  }

  /** 停止发现 */
  stopDiscovery(): void {
    if (this.discoveryTimer >= 0) {
      clearTimeout(this.discoveryTimer);
      this.discoveryTimer = -1;
    }
    const udp: socket.UDPSocket | null = this.discoverySocket;
    this.discoverySocket = null;
    this.discovering = false;
    if (udp !== null) {
      try {
        udp.off('message');
        udp.close();
      } catch (err) {
        // 忽略
      }
    }
  }

  /** 投放到指定 DLNA 设备（多段目标段链式投放） */
  async castToDevice(device: CastDevice, target: CastMediaTarget): Promise<void> {
    this.stopDiscovery();
    this.activeDevice = device;
    this.target = target;
    this.consecutiveErrors = 0;
    this.remoteState = new CastRemoteState();
    // 总时位 → 段索引 + 段内偏移
    let index: number = 0;
    let offset: number = target.startOffsetMs;
    while (index < target.segments.length - 1 && offset >= target.segments[index].lengthMs) {
      offset -= target.segments[index].lengthMs;
      index++;
    }
    const ok: boolean = await this.startSegment(index, offset);
    if (!ok) {
      await this.teardown(false);
      this.callbacks.onError?.('投屏启动失败，请重试');
      return;
    }
    // 音量能力探测（RenderingControl 缺失/失败 → 不支持音量）
    await this.probeVolume();
    this.startPolling();
    this.pushRemoteState();
  }

  /** 远端：播放 */
  async play(): Promise<void> {
    await this.soapAvTransport('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
  }

  /** 远端：暂停 */
  async pause(): Promise<void> {
    await this.soapAvTransport('Pause', '<InstanceID>0</InstanceID>');
  }

  /** 远端：跳转（整集总时位 ms） */
  async seekTo(totalMs: number): Promise<void> {
    const target: CastMediaTarget | null = this.target;
    if (target === null) {
      return;
    }
    let index: number = 0;
    let offset: number = totalMs;
    while (index < target.segments.length - 1 && offset >= target.segments[index].lengthMs) {
      offset -= target.segments[index].lengthMs;
      index++;
    }
    if (index !== this.segmentIndex) {
      await this.startSegment(index, offset);
      this.pushRemoteState();
      return;
    }
    await this.soapAvTransport('Seek',
      `<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${DlnaEngine.formatHms(offset)}</Target>`);
    this.remoteState.positionMs = totalMs;
    this.pushRemoteState();
  }

  /** 远端：设置音量（归一化 0~1 → 0-100） */
  async setVolume(volume01: number): Promise<void> {
    const device: CastDevice | null = this.activeDevice;
    if (device === null || device.renderingControlUrl.length === 0) {
      return;
    }
    const value: number = Math.round(Math.min(1, Math.max(0, volume01)) * 100);
    try {
      await this.soap(device.renderingControlUrl,
        'urn:schemas-upnp-org:service:RenderingControl:1', 'SetVolume',
        `<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>${value}</DesiredVolume>`);
      this.remoteState.volume = value / 100;
      this.pushRemoteState();
    } catch (err) {
      this.remoteState.volumeSupported = false;
      this.pushRemoteState();
    }
  }

  /** 结束投播（主动退出；断开回调由 CastVM 自行处理恢复） */
  async stopCasting(): Promise<void> {
    await this.teardown(false);
  }

  // ============ 内部：SSDP / 描述解析 ============

  /** SSDP 响应 → 去重 → 拉描述 XML → 解析设备 */
  private onSsdpResponse(info: socket.SocketMessageInfo): void {
    const text: string = DlnaEngine.ab2text(info.message);
    const location: string = DlnaEngine.headerValue(text, 'LOCATION');
    const usn: string = DlnaEngine.headerValue(text, 'USN');
    if (location.length === 0 || usn.length === 0) {
      return;
    }
    if (this.foundDevices.has(usn)) {
      return;
    }
    // 占位去重（描述解析失败会移除，避免重复拉取风暴即可）
    const placeholder: CastDevice = new CastDevice();
    placeholder.channel = CastChannel.DLNA_CUSTOM;
    placeholder.deviceId = usn;
    placeholder.deviceName = '';
    this.foundDevices.set(usn, placeholder);
    this.parseDeviceDescription(usn, location);
  }

  /** 拉取并解析设备描述 XML（friendlyName + 控制地址；仅保留含 AVTransport 的设备） */
  private async parseDeviceDescription(usn: string, location: string): Promise<void> {
    try {
      const xml: string = await DlnaEngine.httpGet(location);
      const nameMatch: RegExpMatchArray | null = xml.match(/<friendlyName>([^<]*)<\/friendlyName>/);
      const friendlyName: string = nameMatch !== null && nameMatch.length >= 2 ? nameMatch[1] : '';
      const baseUrl: string = DlnaEngine.originOf(location);
      let avTransportUrl: string = '';
      let renderingUrl: string = '';
      const serviceRe: RegExp = /<service>([\s\S]*?)<\/service>/g;
      let match: RegExpExecArray | null = serviceRe.exec(xml);
      while (match !== null) {
        const block: string = match[1];
        const typeMatch: RegExpMatchArray | null = block.match(/<serviceType>([^<]*)<\/serviceType>/);
        const urlMatch: RegExpMatchArray | null = block.match(/<controlURL>([^<]*)<\/controlURL>/);
        if (typeMatch !== null && urlMatch !== null && typeMatch.length >= 2 && urlMatch.length >= 2) {
          const serviceType: string = typeMatch[1];
          const controlUrl: string = DlnaEngine.resolveUrl(baseUrl, urlMatch[1]);
          if (serviceType.indexOf('AVTransport') >= 0 && avTransportUrl.length === 0) {
            avTransportUrl = controlUrl;
          } else if (serviceType.indexOf('RenderingControl') >= 0 && renderingUrl.length === 0) {
            renderingUrl = controlUrl;
          }
        }
        match = serviceRe.exec(xml);
      }
      if (avTransportUrl.length === 0) {
        // 非媒体渲染设备（路由器/打印机等）→ 移除占位
        this.foundDevices.delete(usn);
        return;
      }
      const device: CastDevice = new CastDevice();
      device.channel = CastChannel.DLNA_CUSTOM;
      device.deviceId = usn;
      device.deviceName = friendlyName.length > 0
        ? friendlyName
        : DlnaEngine.hostOf(location);
      device.controlUrl = avTransportUrl;
      device.renderingControlUrl = renderingUrl;
      this.foundDevices.set(usn, device);
      this.emitDevices();
    } catch (err) {
      // 描述拉取失败（设备已离线/不可达）→ 移除占位
      this.foundDevices.delete(usn);
    }
  }

  /** 推送设备列表快照 */
  private emitDevices(): void {
    const list: CastDevice[] = [];
    this.foundDevices.forEach((device: CastDevice): void => {
      if (device.deviceName.length > 0) {
        list.push(device);
      }
    });
    this.callbacks.onDevicesFound?.(list);
  }

  // ============ 内部：投放 / 轮询 ============

  /** 投放指定段（本地文件经 LocalHttpServer；远程 URL 直投） */
  private async startSegment(index: number, offsetMs: number): Promise<boolean> {
    const device: CastDevice | null = this.activeDevice;
    const target: CastMediaTarget | null = this.target;
    if (device === null || target === null) {
      return false;
    }
    const segment = target.segments[index];
    if (segment === undefined) {
      return false;
    }
    let castUrl: string = segment.url;
    if (segment.localPath.length > 0) {
      const server: LocalHttpServer = LocalHttpServer.getInstance();
      const base: string | null = await server.start();
      if (base === null) {
        return false;
      }
      const url: string | null = server.registerFile(segment.localPath);
      if (url === null) {
        return false;
      }
      castUrl = url;
    }
    // 段基准（总时位折算）
    this.segmentIndex = index;
    let baseMs: number = 0;
    for (let i: number = 0; i < index; i++) {
      const seg = target.segments[i];
      baseMs += seg !== undefined ? seg.lengthMs : 0;
    }
    this.segmentBaseMs = baseMs;
    // SetAVTransportURI（空元数据）→ Play
    try {
      await this.soapAvTransport('SetAVTransportURI',
        `<InstanceID>0</InstanceID><CurrentURI>${DlnaEngine.escapeXml(castUrl)}</CurrentURI>`
        + '<CurrentURIMetaData></CurrentURIMetaData>');
      await this.soapAvTransport('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
    } catch (err) {
      return false;
    }
    this.remoteState.positionMs = baseMs + offsetMs;
    this.remoteState.durationMs = target.totalMs;
    this.remoteState.playing = true;
    return true;
  }

  /** 音量能力探测 */
  private async probeVolume(): Promise<void> {
    const device: CastDevice | null = this.activeDevice;
    if (device === null || device.renderingControlUrl.length === 0) {
      this.remoteState.volumeSupported = false;
      return;
    }
    try {
      const xml: string = await this.soap(device.renderingControlUrl,
        'urn:schemas-upnp-org:service:RenderingControl:1', 'GetVolume',
        '<InstanceID>0</InstanceID><Channel>Master</Channel>');
      const volumeText: string = DlnaEngine.extractTag(xml, 'CurrentVolume');
      const volume: number = Number(volumeText);
      if (!Number.isNaN(volume)) {
        this.remoteState.volume = Math.min(1, Math.max(0, volume / 100));
      }
      this.remoteState.volumeSupported = true;
    } catch (err) {
      this.remoteState.volumeSupported = false;
    }
  }

  /** 启动 1s 轮询 */
  private startPolling(): void {
    this.stopPolling();
    this.pollTimer = setInterval((): void => {
      this.pollTick();
    }, 1000);
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 轮询：GetPositionInfo + GetTransportInfo → 镜像；段尾续投；设备端停止/连续失败 → 断开 */
  private async pollTick(): Promise<void> {
    const target: CastMediaTarget | null = this.target;
    if (target === null || this.activeDevice === null || this.disconnecting) {
      return;
    }
    try {
      const posXml: string = await this.soapAvTransport('GetPositionInfo', '<InstanceID>0</InstanceID>');
      const relMs: number = DlnaEngine.parseHms(DlnaEngine.extractTag(posXml, 'RelTime'));
      const durMs: number = DlnaEngine.parseHms(DlnaEngine.extractTag(posXml, 'TrackDuration'));
      const infoXml: string = await this.soapAvTransport('GetTransportInfo', '<InstanceID>0</InstanceID>');
      const transportState: string = DlnaEngine.extractTag(infoXml, 'CurrentTransportState');
      this.consecutiveErrors = 0;
      const segment = target.segments[this.segmentIndex];
      const segLen: number = segment !== undefined
        ? (segment.lengthMs > 0 ? segment.lengthMs : durMs)
        : durMs;
      const posTotal: number = this.segmentBaseMs + relMs;
      if (transportState === 'PLAYING') {
        this.remoteState.playing = true;
        this.remoteState.positionMs = posTotal;
        this.remoteState.durationMs = target.totalMs > 0 ? target.totalMs : durMs;
      } else if (transportState === 'PAUSED_PLAYBACK') {
        this.remoteState.playing = false;
        this.remoteState.positionMs = posTotal;
        this.remoteState.durationMs = target.totalMs > 0 ? target.totalMs : durMs;
      } else if (transportState === 'STOPPED') {
        // 段尾（容差 2s）→ 续投下一段；否则视为设备端主动停止 → 断开
        if (segLen > 0 && relMs >= segLen - 2000) {
          const next: number = this.segmentIndex + 1;
          if (next < target.segments.length) {
            const ok: boolean = await this.startSegment(next, 0);
            if (!ok) {
              await this.teardown(true);
              return;
            }
          } else {
            // 末段播完：镜像到末尾
            this.remoteState.playing = false;
            this.remoteState.positionMs = target.totalMs;
          }
        } else {
          await this.teardown(true);
          return;
        }
      }
      // TRANSITIONING 等中间态：保持上次镜像
      this.pushRemoteState();
    } catch (err) {
      this.consecutiveErrors++;
      if (this.consecutiveErrors >= 3) {
        await this.teardown(true);
      }
    }
  }

  /** 断开全链路（invokeCallback=true 时上报 onDisconnected 携带恢复位置） */
  private async teardown(invokeCallback: boolean): Promise<void> {
    if (this.disconnecting) {
      return;
    }
    this.disconnecting = true;
    const resumeMs: number = this.remoteState.positionMs;
    this.stopPolling();
    const device: CastDevice | null = this.activeDevice;
    this.activeDevice = null;
    this.target = null;
    this.segmentIndex = 0;
    this.segmentBaseMs = 0;
    // 设备端 Stop（尽力而为）
    if (device !== null) {
      try {
        await this.soapAvTransport('Stop', '<InstanceID>0</InstanceID>');
      } catch (err) {
        // 忽略
      }
    }
    LocalHttpServer.getInstance().clearFiles();
    this.disconnecting = false;
    if (invokeCallback) {
      this.callbacks.onDisconnected?.(resumeMs);
    }
  }

  /** 推送远端镜像 */
  private pushRemoteState(): void {
    const snapshot: CastRemoteState = new CastRemoteState();
    snapshot.playing = this.remoteState.playing;
    snapshot.positionMs = this.remoteState.positionMs;
    snapshot.durationMs = this.remoteState.durationMs;
    snapshot.volume = this.remoteState.volume;
    snapshot.volumeSupported = this.remoteState.volumeSupported;
    this.callbacks.onRemoteStateChanged?.(snapshot);
  }

  // ============ 内部：SOAP / 解析工具 ============

  /** AVTransport SOAP 调用 */
  private async soapAvTransport(action: string, innerBody: string): Promise<string> {
    const device: CastDevice | null = this.activeDevice;
    if (device === null) {
      throw new Error('未连接 DLNA 设备');
    }
    return await this.soap(device.controlUrl, 'urn:schemas-upnp-org:service:AVTransport:1',
      action, innerBody);
  }

  /** SOAP POST（非 2xx 抛错） */
  private async soap(controlUrl: string, serviceType: string, action: string,
    innerBody: string): Promise<string> {
    const body: string = `<?xml version="1.0" encoding="utf-8"?>`
      + '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
      + ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      + `<s:Body><u:${action} xmlns:u="${serviceType}">${innerBody}</u:${action}></s:Body></s:Envelope>`;
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'text/xml; charset="utf-8"',
          'SOAPACTION': `"${serviceType}#${action}"`
        },
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 3000,
        readTimeout: 3000
      };
      const resp: http.HttpResponse = await client.request(controlUrl, options);
      const text: string = typeof resp.result === 'string' ? resp.result : '';
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`SOAP ${action} 状态码 ${resp.responseCode}`);
      }
      return text;
    } finally {
      client.destroy();
    }
  }

  /** HTTP GET（设备描述拉取） */
  private static async httpGet(url: string): Promise<string> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 3000,
        readTimeout: 3000
      };
      const resp: http.HttpResponse = await client.request(url, options);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      return typeof resp.result === 'string' ? resp.result : '';
    } finally {
      client.destroy();
    }
  }

  /** HTTP 头取值（大小写不敏感） */
  private static headerValue(text: string, name: string): string {
    const lines: string[] = text.split('\r\n');
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const idx: number = line.indexOf(':');
      if (idx > 0 && line.substring(0, idx).trim().toUpperCase() === name.toUpperCase()) {
        return line.substring(idx + 1).trim();
      }
    }
    return '';
  }

  /** XML 标签取值（首个匹配） */
  private static extractTag(xml: string, tag: string): string {
    const match: RegExpMatchArray | null = xml.match(new RegExp(`<${tag}>([^<]*)</${tag}>`));
    return match !== null && match.length >= 2 ? match[1] : '';
  }

  /** H:MM:SS(.fff) → ms */
  private static parseHms(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    const clean: string = text.split('.')[0];
    const parts: string[] = clean.split(':');
    if (parts.length < 1) {
      return 0;
    }
    // 按 H:MM:SS 逐位累计
    let ms: number = 0;
    for (let i: number = 0; i < parts.length && i < 3; i++) {
      const value: number = Number(parts[i]);
      if (Number.isNaN(value)) {
        return 0;
      }
      if (i === 0) {
        ms = value * 3600000;
      } else if (i === 1) {
        ms += value * 60000;
      } else {
        ms += value * 1000;
      }
    }
    return Math.max(0, Math.floor(ms));
  }

  /** ms → H:MM:SS（REL_TIME 格式） */
  private static formatHms(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${h}:${mm}:${ss}`;
  }

  /** XML 转义（URL 文本嵌入 SOAP 体） */
  private static escapeXml(text: string): string {
    return text.replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;');
  }

  /** URL → scheme://host:port */
  private static originOf(url: string): string {
    const schemeIdx: number = url.indexOf('://');
    if (schemeIdx < 0) {
      return '';
    }
    const rest: string = url.substring(schemeIdx + 3);
    const pathIdx: number = rest.indexOf('/');
    return pathIdx >= 0 ? url.substring(0, schemeIdx + 3 + pathIdx) : url;
  }

  /** URL → host[:port]（设备名缺省时使用） */
  private static hostOf(url: string): string {
    const origin: string = DlnaEngine.originOf(url);
    const schemeIdx: number = origin.indexOf('://');
    return schemeIdx >= 0 ? origin.substring(schemeIdx + 3) : origin;
  }

  /** 描述基地址 + 控制地址 → 绝对地址 */
  private static resolveUrl(baseUrl: string, controlUrl: string): string {
    if (controlUrl.startsWith('http://') || controlUrl.startsWith('https://')) {
      return controlUrl;
    }
    if (baseUrl.length === 0) {
      return controlUrl;
    }
    if (controlUrl.startsWith('/')) {
      return baseUrl + controlUrl;
    }
    return `${baseUrl}/${controlUrl}`;
  }

  /** ArrayBuffer → 文本（SSDP 响应为 ASCII） */
  private static ab2text(buffer: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buffer);
    let text: string = '';
    const step: number = 4096;
    for (let i: number = 0; i < bytes.length; i += step) {
      const end: number = Math.min(i + step, bytes.length);
      let part: string = '';
      for (let j: number = i; j < end; j++) {
        part += String.fromCharCode(bytes[j]);
      }
      text += part;
    }
    return text;
  }
}

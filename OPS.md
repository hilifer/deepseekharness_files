# 公司文件服务器 — 运维操作手册

## 系统架构

```
https://192.168.1.225:8099/           ← 局域网/本机入口（dsh 工作台 / + 文件服务器 /files/）
https://127.0.0.1:8099/               ← 仅服务器本机可用
https://218.17.143.249:8099/          ← 公网入口（需云安全组放行 8099/9091 并 NAT 转发到 192.168.1.225）
https://192.168.1.225:9091/           ← Authelia 登录门户
```

```
https://192.168.1.225:8099/admin/     ← 员工管理后台（仅 admin）
```

**重要**：
- 必须用 `https://`（nginx 只在 TLS 端口监听，http 会返回 400 "plain HTTP request sent to HTTPS port"）
- 公网 IP `218.17.143.249` 是云 NAT 地址，不绑在本机网卡上——**在服务器本机浏览器里访问公网地址永远连不通**，本机请用 `https://127.0.0.1:8099` 或 `https://192.168.1.225:8099`
- 自签证书：首次访问浏览器会告警，点"高级 → 继续前往"即可

- **nginx** (8099/9091)：唯一出口，按用户路由 + TLS 自签证书
- **Authelia** (127.0.0.1:19091)：SSO 登录 + 认证代理
- **FileBrowser Quantum v1.5.2** (127.0.0.1:18080)：文件服务器与权限中心
- **dsh 主实例** (127.0.0.1:3080)：admin 专属
- **每员工 dsh 实例**：独立端口 13101+，独立 DSH_HOME

## 日常操作命令

### 1. 全栈重启
```bash
/home/ubuntu/dsh-runtime/start-all.sh   # 幂等，可重复执行
```

### 2. 员工增删改 —— 优先用管理后台

**https://192.168.1.225:8099/admin/** （仅 admin 可进）

新增 / 编辑 / 重置密码 / 删除 / 启停实例都在界面上完成，每行还会显示该员工在
Authelia、nginx、FileBrowser、dsh 实例、工作区目录五处的同步状态。

命令行等价物（与后台共用 `admin/core.py`，不存在第二套逻辑）：

```bash
# 新增。注意参数顺序是 <用户名> <部门> <角色> [姓名]
/home/ubuntu/scripts/provision-user.sh wang_er 研发部 员工 王二
INIT_PW='指定初始密码' /home/ubuntu/scripts/provision-user.sh wang_er 研发部 员工 王二

# 离职销号（停实例 + 清四个子系统；工作区文件默认保留）
/home/ubuntu/scripts/deprovision-user.sh wang_er
/home/ubuntu/scripts/deprovision-user.sh wang_er --delete-files   # 连文件一起永久删除

# 改部门/角色/姓名（改路径会连带迁移文件并重启实例）
python3 /home/ubuntu/admin/cli.py update wang_er --department 市场部
python3 /home/ubuntu/admin/cli.py update wang_er --role 主管

# 重置密码
python3 /home/ubuntu/admin/cli.py passwd wang_er

# 查看所有人及同步状态
python3 /home/ubuntu/admin/cli.py list
```

**重要提醒**：建号和改密码都会重启 Authelia，而会话存在内存里（未配 redis），
所以**每次操作都会把所有在线用户登出一次**。批量建号请一次做完，或安排在非工作时段。

### 3. 部署根不是 /home/ubuntu

nginx / FileBrowser / Authelia 的配置只能写绝对路径，仓库里默认是
`/home/ubuntu`。若实际部署在别的用户下（比如 `/home/robot`）：

```bash
scripts/configure-root.sh --show          # 先看当前写的是哪个根
scripts/configure-root.sh /home/robot     # 一次改完 22 处，幂等且可改回
```

各 shell 脚本与管理后台都读 `DSH_ROOT`（默认 `$HOME`），以非部署用户身份
运行时显式传：`DSH_ROOT=/home/robot ./dsh-runtime/start-all.sh`。

CI 里有一个 `alt-root` job 专门在 `/home/robot` 下跑通全栈（改根 → 生成
密钥 → `nginx -t` → 起管理后台并验鉴权 → 沙箱隔离测试），所以这条路是
每次都验过的，不是纸上写写。

### 4. 手工修复（后台不可用时的兜底）

```bash
# 登记表：/home/ubuntu/dsh-users/registry.json（权威来源，ports.json 由它同步生成）
# 手工改过 nginx / users_database.yml 后，让路由与登记表重新对齐：
python3 /home/ubuntu/admin/cli.py sync-nginx
# users_database.yml 每次写入前自动备份为 users_database.yml.bak.<时间戳>（保留最近 10 份）
```

### 5. 检查服务状态
```bash
# 全员同步状态一览（推荐）
python3 /home/ubuntu/admin/cli.py list
# 隔离验收
/home/ubuntu/scripts/preflight-sandbox.sh
# 各端口健康检查
for port in 3080 9091 8099 18080 19200 13101 13102 13103; do
  curl -sk -o /dev/null -w ":$port -> %{http_code}\n" --max-time 5 "http://127.0.0.1:$port/"
done
# 查看进程
ps aux | grep -E "dsh web|authelia|nginx|filebrowser"
```

### 6. nginx 配置热更新
```bash
/home/ubuntu/nginx/extracted/usr/sbin/nginx -t -c /home/ubuntu/nginx/conf/nginx.conf
/home/ubuntu/nginx/extracted/usr/sbin/nginx -s reload -c /home/ubuntu/nginx/conf/nginx.conf
```

### 7. FileBrowser 用户管理
```bash
# 列出所有用户
curl -s http://127.0.0.1:18080/files/api/users -H "X-Forwarded-User: admin"
# 修改用户权限（例：授予员工删除权限）
curl -X PUT "http://127.0.0.1:18080/files/api/users?username=zhangsan" \
  -H "X-Forwarded-User: admin" -H "Content-Type: application/json" \
  -d '{"which":["permissions"],"data":{"permissions":{...,"delete":true}}}'
```

## WebDAV 访问

FileBrowser v1.5.2 支持 WebDAV：
```
地址: https://218.17.143.249:8099/files/dav
认证: 同上（Authelia 会话自动认证，浏览器访问 /files/ 后 WebDAV client 可用相同 cookie）
```

Windows 映射网络驱动器：`https://218.17.143.249:8099/files/dav`（需信任自签证书）
macOS Finder：`前往 → 连接服务器 → https://218.17.143.249:8099/files/dav`

## 回收站说明

v1.5.2 版本无内置回收站。主管删除部门文件为**永久删除**（UI 有确认框）。
后续版本可考虑启用 Command Runner 钩子实现回收站。

## 关键技术细节

| 项目 | 细节 |
|------|------|
| 初始密码 | 见 initial-credentials.txt（首次登录后请修改） |
| TLS 证书 | 自签，`/home/ubuntu/nginx/certs/dsh.crt`/`dsh.key` |
| 配置文件 | `/home/ubuntu/nginx/conf/`, `/home/ubuntu/dsh-auth/config/`, `/home/ubuntu/filebrowser/config.yaml` |
| 日志位置 | `~/nginx/logs/`, `~/dsh-auth/authelia.log`, `~/filebrowser/logs/`, `~/dsh-users/<user>/dsh.log` |
| 员工登记表 | `/home/ubuntu/dsh-users/registry.json`（权威来源；`ports.json` 由它同步生成） |
| 端口分配 | 13101 起始递增，由 `admin/core.py` 分配 |
| 账号密码 | 初始密码只在建号时显示一次，不再落盘（旧的 `initial-credentials.txt` 若还在，建议删除） |
| 管理后台 | `https://<IP>:8099/admin/`，日志 `~/admin/admin.log`，审计 `~/admin/audit.log` |
| 共享密钥 | `~/admin/.admin-token`、`~/nginx/conf/generated/`（均 600，不入库） |
| 操作手册 | 本文件 `/home/ubuntu/scripts/OPS.md` |

## 空间模型

| 角色 | 空间 | 说明 |
|------|------|------|
| 员工 | `departments/<部门>/<姓名>` | 只有自己的目录 |
| 主管 | `departments/<部门>` | 整个部门，可删部门文件 |
| admin | `dsh-files` | 整个公司（3080 实例即以此为工作区） |

**FileBrowser 的 scope 与 dsh 沙箱的挂载都由 `admin/core.py` 的 `space_for()`
推导**，不存在两套定义。改角色或改部门时两边一起更新，并重启实例让新挂载生效
（升主管会多挂一层部门目录，不重启不生效）。

后台列表的「两边同步」列拿 FileBrowser 里的**实际** scope 与定义比对。显示
「不一致」说明有人绕过后台直接改过 FileBrowser 权限，用「编辑」保存一次即可纠正，
命令行等价物是 `python3 admin/cli.py update <user> --role <当前角色>`。

## 文件上传

dsh 核心**没有**内置的任意文件上传，需要装插件，例如
`github:l541402398/dsh-file-uploads`（要求 dsh >= 0.1.0-rc.6、Node 22+、
仅 Web profile；单文件 100 MiB、目录合计 1 GiB）。装之前先确认版本：

```bash
dsh --version
```

本部署已为此做了两处配合，装上插件即可用：

- `DSH_UPLOAD_DIR` 由 `dsh-sandbox.sh` 设为 **本人工作区下的 `uploads/`**。
  插件默认落在 `$DSH_HOME/uploads`，那不在 FileBrowser 的 source 里，
  员工在 dsh 里传的文件在 `/files/` 上看不见，与「两边看到同一个空间」相矛盾。
  沙箱用了 `--clearenv`，这个变量必须显式 setenv 才能传进去。
- nginx `client_max_body_size` 提到 `256m`，给 100 MiB 单文件加 multipart
  开销留出余量，否则接近上限的文件会被 413 拦掉。

插件自身的安全模型只有 loopback/trusted-host 与 Origin 校验，作者也建议放在
带认证的反代后面——本部署的 Authelia 已经满足这一条。

未装插件时 `DSH_UPLOAD_DIR` 无人读取，留着无副作用。

## 工作区隔离

分两层，内核层是真边界，UX 层只管好看。

### 第一层（内核）：按环境择优的隔离档位

所有 dsh 实例（含 admin）都经 `dsh-runtime/dsh-sandbox.sh` 启动。它是**调度器**，
不是某一种机制：按隔离强度从强到弱逐档探测，挑第一个**在这台机器上真跑得起来**的。

```bash
/home/ubuntu/dsh-runtime/dsh-sandbox.sh --report   # 先看这个：环境形状 + 逐档为什么行/不行 + 最终选谁
/home/ubuntu/dsh-runtime/dsh-sandbox.sh --backend  # 只打印档位名
/home/ubuntu/dsh-runtime/dsh-sandbox.sh --check    # 挑得出=0，挑不出=1（fail-closed）
/home/ubuntu/scripts/preflight-sandbox.sh          # 逐项实测验收（不看配置，只看能不能读到）
```

| 档 | 机制 | 前提 | 怎么把前提补上 |
|----|------|------|--------------|
| `container` | 每实例一个独立容器 | 够得到 docker 守护进程 | `scripts/build-dsh-image.sh` 构建实例镜像；容器里跑要把宿主 socket 挂进来 |
| `bwrap` | bubblewrap 挂载命名空间 | 非特权 userns，或容器内 root + CAP_SYS_ADMIN | `scripts/install-bubblewrap.sh`；Ubuntu 24.04+ 还要 `sudo scripts/apparmor-allow-userns.sh` |
| `landlock` | 内核的非特权自我沙箱 | **只需内核 5.13+ 编进 Landlock** | **无需任何准备**，也不用求宿主配合。验一下：`python3 dsh-runtime/dsh-landlock-exec.py --selftest` |
| `uid` | 独立 OS 用户 + 文件权限 | 容器内 root，且**摸不到 docker socket** | 无需准备；部门级权限还需文件系统支持 ACL（`apt-get install acl`） |
| `none` | 无隔离，仅排障 | `DSH_ALLOW_UNCONFINED=1` | —— |

**拿不到 root、也拿不到 userns 的容器里，`landlock` 往往是唯一还活着的一档。**
它是本项目在这种环境下的默认答案——前两档都要容器外的人配合一次，它不用。

`DSH_ISOLATION=<档名>` 可以强制指定（也接受空格分隔的候选列表），默认 `auto`。

探测**不看配置也不看版本号，直接跑一次真家伙**：bwrap 真 `--unshare-all` 一次，
容器档真起一个探针容器去看挂载对不对。「装了但跑不起来」和「没装」一视同仁。

实例内可见的全部内容（三档一致）：

| 挂载 | 内容 |
|------|------|
| 只读 | `/usr /bin /sbin /lib* /etc`、`node/`（含 dsh 本体）、共享 `profiles/` |
| 读写 | 本人 `dsh-users/<user>/`、本人工作区（主管另加整个部门目录） |
| 其他 | `/proc`、`/dev`、私有 `/tmp` |

**碰不到**：`dsh-auth/`（全员明文初始密码、用户库）、`nginx/certs/`（TLS 私钥）、
`filebrowser/`（权限库）、`admin/`（后台代码与 token）、`dsh-users/registry.json`、
其他部门与其他员工的目录、`/var/run/docker.sock`。

档位之间的差别只在**文件之外**的维度，`preflight-sandbox.sh` 会如实标注：

| | container | bwrap | landlock | uid |
|---|---|---|---|---|
| 越界的表现 | 文件不存在 | 文件不存在 | 拒绝访问 | 拒绝访问 |
| 独立 pid ns（`ps` 看不到宿主进程） | ✔ | ✔ | ✘ | ✘ |
| 连不到别人的实例端口 | ✔ | 需 `DSH_NETNS=1` | ✔ TCP 端口白名单 | ✘ |
| kill 不到别人的进程 | ✔ | ✔ | ✔ ABI v6+ | ✘ |
| 资源限额 | ✔ | ✘ | ✘ | ✘ |

共享 `profiles/` 一律挂成**只读**：此前它对所有实例可写，任何员工都能改写
`clamped-picker/index.mjs` 影响全体。

#### container 档：宿主路径换算

容器里的 docker 有两种形态，`-v` 左边的写法完全不同：

- **sibling（挂宿主 socket，最常见）**：起出来的是宿主的兄弟容器，`-v` 左边必须写
  **宿主上的绝对路径**。写成容器内路径会挂到空目录——容器能起来但挂载是错的。
- **DinD（容器内自己的 dockerd）**：路径就是容器内的路径。

后端会 `docker inspect` 自省本容器的 Mounts 建出映射表，再**真起一个探针容器验一次**。
验不过就 probe 失败、拒绝启动实例。自省不出来时用环境变量显式指定：

```bash
export DSH_HOST_ROOT=/srv/dsh     # $DSH_ROOT 在宿主上的绝对路径
```

其他可调项：`DSH_IMAGE`（默认 `dsh-instance:local`）、`DSH_IMAGE_BASE`、
`DSH_CONTAINER_MEMORY` / `DSH_CONTAINER_CPUS` / `DSH_CONTAINER_PIDS`、
`DSH_PUBLISH_ADDR`（默认 `127.0.0.1`，**不要改成 0.0.0.0**，那等于把实例直接
暴露到局域网，绕过 SSO）。

#### landlock 档：它给到什么、给不到什么

这一档由 `dsh-runtime/dsh-landlock-exec.py` 实现——纯 ctypes 直调三个系统调用，
不用编译、不用装包（那种受限环境里多半也装不了东西）。进程给自己上锁后
**不可撤销、子进程继承、exec 后仍在**，所以 dsh 起的 bash、bash 起的 cat
全都带着这把锁。

按内核 ABI 逐级增强：v1+ 文件系统，v3+ 截断，**v4+ TCP bind/connect**
（封死「员工 A 直连员工 B 的实例端口」），v5+ ioctl，**v6+ scope**
（kill 不到沙箱外的进程、连不上沙箱外的抽象 unix socket）。

可调项：`DSH_LANDLOCK_CONNECT_PORTS`（默认 `443 80 22`）。
**不要把 13100-13199 加进去**——那等于把上面那条好不容易封住的路重新打开。

给不到的：没有 pid namespace（`ps` 看得到全机进程和命令行）、没有资源限额、
越界报的是「拒绝访问」而不是「不存在」（路径存在性仍会泄露一点）。
私有 `TMPDIR` 指向 `$DSH_HOME/tmp`，`/tmp` 不放行——那是全机共享的。

#### uid 档：它给不到什么

这是最后一档，只在既没有可用 docker、也开不出命名空间时才会被选中。
它**只有文件维度的强制点**：没有 pid ns（`ps` 能看到全机进程和别人的命令行）、
没有 net ns（员工 A 能直连 B 的实例端口）、`/tmp` 共享。

它还有一条硬前提：**机器上不能有可达的 docker socket**。有的话一句
`docker run -v /:/host ...` 就拿到整台宿主，UID 隔离完全作废——所以 probe 检测到
socket 会直接拒绝选用自己，让位给本来就更强的 container 档。

主管的部门级权限在这一档靠 POSIX ACL（`setfacl`）实现：部门目录里躺着各员工
自己的目录，chown 过来会抢掉他们的属主，而 DAC 的三段位也表达不了「主管看整个
部门、员工只看自己」。文件系统不支持 ACL 时这一项**给不了**，启动日志会告警。

### 降级运行（DSH_ALLOW_UNCONFINED=1）意味着什么

一档都挑不出来时可以用 `DSH_ALLOW_UNCONFINED=1` 让实例照常启动，但要清楚代价：
**这时没有任何文件系统隔离**，每个员工的 dsh 都能读写整台服务器的文件，
包括其他部门的文件、`initial-credentials.txt` 里的全员明文初始密码、TLS 私钥；
机器上若有 docker socket，它还能一句话逃到宿主 root。
FileBrowser 的 scope 与选择器钳制在这种模式下都拦不住 dsh 的 bash 工具。

也就是说：功能全通 ≠ 隔离生效。判断标准只有一条——

```bash
scripts/preflight-sandbox.sh      # 第 1 节全绿才算隔离真的在起作用
```

降级只应作为临时状态。先跑 `dsh-sandbox.sh --report`，按报告里点名的那一条补前提。

**fail-closed**：挑不出后端时 `start-all.sh` 不启动任何实例、管理后台拒绝建号。

#### 排障：`bwrap: setting up uid map: Permission denied`

bwrap 档最常见的一种失败。**本部署的服务器已实测为这种情况**
（`kernel.apparmor_restrict_unprivileged_userns = 1`），本项目的 CI 在
GitHub 的 ubuntu-24.04 runner 上也撞到过同一堵墙。原因是 Ubuntu 24.04 起
AppArmor 默认拦截非特权 user namespace。

```bash
scripts/apparmor-allow-userns.sh --status     # 先看状态，不改动任何东西
sudo scripts/apparmor-allow-userns.sh         # 推荐：只给 bwrap 开口子
sudo scripts/apparmor-allow-userns.sh --sysctl  # 备选：全局关掉该限制
```

两种做法的取舍：

| 做法 | 影响面 | 何时用 |
|------|--------|--------|
| AppArmor profile（默认） | 只有 bwrap 这一个可执行文件获得 userns 权限 | 首选 |
| 全局 sysctl | 整机所有程序都不再受该限制 | 没有 apparmor_parser，或 profile 方式失败时 |

这是**宿主机的内核设置**：服务跑在容器里而你拿不到宿主 root 的话，这两条路都
走不通——这正是本项目改成多档自适应的原因。那种环境下 `--report` 会直接告诉你
该走 container 档还是 uid 档，不必再跟这个开关较劲。

### 第二层（UX）：目录选择器钳制

插件 `~/.local/share/dsh/profiles/web/clamped-picker/index.mjs` 让选择器默认开在
根目录、面包屑不显示上层、越界返回 `directory-unreadable`。允许根来自实例进程的
`DSH_ALLOWED_ROOT`，由 `dsh-sandbox.sh` 从登记表传入。

注意这一层**只覆盖选择器的 list/createDirectory**，dsh 的 bash 和文件读写工具
完全不经过它——所以它从来不是安全边界，真正的边界是第一层。

> 允许根的来源已从 `storages/workspace.json` 改为 `dsh-users/registry.json`。
> 前者是实例自己（也就是被约束方）在写的：用户删光工作区就能让推导结果为空，
> 进而拿到不设限的实例。约束的依据不能由被约束方提供。

## 网络面：实例间可达性

沙箱默认与宿主**共享网络命名空间**（dsh 要出网调模型 API），所以实例仍能连
`127.0.0.1` 上的服务。

已封堵（靠「能连上 != 能调用」）：

| 目标 | 手段 |
|------|------|
| FileBrowser API `:18080` | 代理认证头的**名字**是随机密钥，配置在沙箱内不可见 |
| 管理后台 API `:19200` | 要求 nginx 注入的 `X-Admin-Token`，密钥文件在沙箱内不可见 |

密钥由 `scripts/init-secrets.sh` 生成（幂等，`start-all.sh` 会自动调用），
落在 `nginx/conf/generated/`（600，已 gitignore）。轮换：删掉
`admin/.admin-token` 与 `nginx/conf/generated/fb-auth.conf` 后重跑该脚本，
再 `fb-start.sh restart` + `nginx-start.sh reload`。

### DSH_NETNS=1：封掉实例间互连

默认形态下**员工 A 可直连员工 B 的 dsh 端口** `127.0.0.1:1310x`，驱动 B 的
agent 读写 B 的工作区（dsh 对入站不做身份校验，路由全靠 nginx 的 map）。

开启 `DSH_NETNS=1` 后：每实例一个独立网络命名空间，pasta 提供出网与 DNS
转发，入站改走 unix socket，**宿主回环上不再留下任何 dsh 端口**。

```bash
sudo apt-get install -y passt socat
export DSH_NETNS=1
/home/ubuntu/dsh-runtime/start-all.sh
python3 /home/ubuntu/admin/cli.py sync-nginx     # upstream 换成 unix socket
/home/ubuntu/scripts/preflight-sandbox.sh
```

实现要点：

- socket 位于 `~/dsh-sockets/<user>/dsh.sock`（目录 700，只把**本人**那个目录
  挂进沙箱，所以沙箱里看不到别人的 socket 路径）
- nginx 的 `map $user $dsh_upstream` 会由 `cli.py sync-nginx` 改写成
  `unix:/home/ubuntu/dsh-sockets/<user>/dsh.sock:` 形式；default 仍保持
  TCP 黑洞 `127.0.0.1:13100`，因为未匹配用户要的是 403 而不是 socket
  不存在导致的 502
- `pasta --no-map-gw` 断掉经网关回连宿主的路径；`-t none -u none` 不做任何
  入站端口转发
- 沙箱内 `/etc/resolv.conf` 被换成指向 pasta 的 DNS 转发器（`10.0.2.3`）

**踩过的坑**：pasta 的 `--no-splice` **不解决问题**——它仍会把命名空间的回环
连接转发到宿主回环。真正起作用的是「宿主回环上根本没有那个端口」，所以必须
走 unix socket，而不是 `pasta -t <port>` 端口转发。

**排障**：若 nginx 报 `502 ... connect() to unix:... failed (13: Permission denied)`，
是 nginx worker 与 socket 属主不是同一个用户。本部署两者同为 ubuntu，
若你改过 nginx 的 `user` 指令需要调回来。

**验收**：`tests/test_sandbox.py::NetnsIsolationTest` 每次 CI 都会真跑一遍
（用真实的 `dsh-sandbox.sh`），断言宿主回环上无 dsh 端口、员工 A 三条路都
连不到 B、nginx 经 unix socket 正常、沙箱内出网正常。

## 容器入口点

容器启动后自动执行：
```bash
/home/ubuntu/dsh-runtime/start-all.sh
```
确保所有服务（dsh/authelia/nginx/filebrowser + 每用户 dsh 实例）幂等启动。

## 界面能打开，但设置里模型/权限/预设全部加载失败（HTTP 403）

现象：dsh 页面正常渲染，设置面板里三处下拉都显示
`transport failure for /api/settings.describe: HTTP 403`。

这不是服务坏了，也不是路由问题。这套部署里 403 只有两个来源，现象可区分：

| 来源 | 现象 |
|------|------|
| 黑洞 `127.0.0.1:13100`（`map $user` 未匹配） | **整个界面都打不开** |
| dsh 实例自己拒绝（Host/Origin 校验） | **页面正常，只有 API 403** |

第二种的判据是 `--trusted-host`：**浏览器地址栏里的 host:port 不在名单里时，
静态页照发、API 一律 403**。报错只有一个 403，完全指不到成因上。

名单现在由两部分合成（`backends/common.sh`）：

- `DSH_TRUSTED_HOSTS` 显式配置的
- 本机**真实拥有**的名字与地址自动补齐（`hostname` / `hostname -f` /
  `hostname -I` 的每个 IP / localhost / 127.0.0.1），各配一份 `DSH_ENTRY_PORT`
  （默认 8099）

所以「换台机器、换张网卡、改用主机名访问」不再会撞上这个。仍然撞上的话：

```bash
bash scripts/diag-403.sh admin      # 员工账号就把 admin 换成用户名
```

它会打出实例进程**实际**带了哪些 `--trusted-host`，并绕开 nginx 直连实例、
逐个 Host 试同一个接口，看哪个被接受。

入口端口不是 8099 时要一并告诉它：`DSH_ENTRY_PORT=9443`。

**不要**为了图省事往名单里加通配符或 `0.0.0.0` —— 那会把 Host 校验变成摆设，
是真的放宽了安全边界，而不是修 bug。自动补进去的都是这台机器自己的地址，
防的是跨站与 DNS 重绑定，不是防本机。

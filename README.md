# 公司文件服务器 — FileBrowser Quantum + Authelia SSO + 每员工独立 dsh 实例

单端口公司文件服务器与 AI 工作台部署方案：

- **统一入口** `https://<IP>:8099`：`/` 为每员工独立 dsh 工作台，`/files/` 为 FileBrowser 文件服务器
- **SSO**：Authelia 单点登录，proxy auth 透传用户身份，应用零密码暴露
- **权限中心**：一个用户一个空间，FileBrowser 与 dsh 两边由同一个定义推导，不会漂移
- **多租户 dsh**：每员工一个独立进程/端口/数据目录的 DeepSeek Harness 实例，nginx 按登录名路由
- **工作区硬隔离，且跟着环境自适应**：隔离层按这台机器**实际拿得到什么**择优——
  独立容器 > bubblewrap 挂载命名空间 > 独立 OS 用户，工作区以外的路径在实例内
  根本不存在（或读不到），bash 用绝对路径也绕不过去。一档都拿不到时**拒绝启动
  实例**，不退回裸跑。见 [DESIGN.md](DESIGN.md)
- **图形化员工管理**：`/admin/` 后台完成增删改查，不用再敲命令

## 架构

```
                    ┌────────────────────────────── nginx :8099/:9091 (TLS, 唯一出口) ───────────────────┐
浏览器 ──https────▶│  auth_request──▶ Authelia :19091                                                    │
                    │  /        ──▶ map $user ──▶ admin:3080 / zhangsan:13101 / lisi:13102 / ... / 黑洞403 │
                    │  /files/  ──▶ FileBrowser :18080 (baseURL=/files, proxy auth)                       │
                    └─────────────────────────────────────────────────────────────────────────────────────┘
文件数据：~/dsh-files/departments/<部门>/<姓名>/   （FileBrowser source「公司文件」= ~/dsh-files）
```

## 目录结构

```
├── admin/                     # 员工管理后台
│   ├── core.py                # 生命周期引擎（增删改的唯一实现）
│   ├── app.py                 # JSON API + 静态托管（仅绑 127.0.0.1）
│   ├── cli.py                 # 命令行入口，与后台共用 core.py
│   ├── admin-start.sh
│   └── static/index.html      # 管理界面
├── tests/                     # 单元/接口/隔离测试（109 项）+ env-shape.sh 环境形状验收
├── scripts/
│   ├── provision-user.sh      # 建号（cli.py 的薄包装，保持原 CLI 兼容）
│   ├── deprovision-user.sh    # 离职销号（原先只有手工步骤）
│   ├── configure-root.sh      # 把配置里的部署根改到实际路径（幂等可逆）
│   ├── apparmor-allow-userns.sh # Ubuntu 24.04+ 放行 bwrap 的 userns 权限
│   ├── init-secrets.sh        # 生成 nginx 注入的共享密钥（幂等）
│   ├── init-profile.sh        # 初始化共享 profile 补丁层（clamped-picker 钳制 + 定时任务）
│   ├── install-bubblewrap.sh  # 无 root 安装 bwrap（解包 deb，同 nginx 的装法）
│   ├── build-dsh-image.sh     # 构建实例容器镜像（container 档用）
│   ├── make-fake-deploy.sh    # 搭仿真部署树（CI 各环境形状共用）
│   ├── preflight-sandbox.sh   # 隔离验收：实测工作区以外到底碰不碰得到
│   └── fb-start.sh            # FileBrowser 启动脚本
├── dsh-runtime/
│   ├── start-all.sh           # 全栈幂等启动入口（容器 entrypoint 调用）
│   ├── dsh-sandbox.sh         # 隔离调度器：探测环境 -> 择优选档 -> fail-closed
│   ├── backends/              # 各档隔离的具体实现（接口统一：probe / run）
│   │   ├── common.sh          #   挂载解析、环境变量白名单、环境形状探测
│   │   ├── container.sh       #   ① 独立容器（最强，需要够得到 dockerd）
│   │   ├── bwrap.sh           #   ② 挂载命名空间（需 userns 或 root+CAP_SYS_ADMIN）
│   │   ├── landlock.sh        #   ③ 内核自我沙箱（只需内核 5.13+，不用求任何人）
│   │   ├── uid.sh             #   ④ 独立 OS 用户 + DAC（需容器内 root，且无 docker socket）
│   │   └── none.sh            #   ⑤ 无隔离，必须显式放行，仅排障
│   ├── dsh-container-entry.sh # 实例容器内的入口（端口桥接）
│   ├── dsh-landlock-exec.py   # Landlock 上锁器（纯 ctypes，无需编译/装包）
│   ├── Dockerfile.instance    # 实例容器镜像
│   └── dsh-start.sh           # admin 主实例启动
├── dsh-auth/
│   ├── authelia-start.sh
│   └── config/
│       ├── configuration.example.yml   # Authelia 配置模板（密钥用 CHANGE_ME 占位）
│       └── users_database.example.yml  # 用户库模板（argon2 哈希占位）
├── nginx/
│   ├── nginx-start.sh
│   └── conf/
│       ├── nginx.conf                  # 含 map $user $dsh_upstream 用户路由表
│       └── sites/dsh-auth.conf         # auth_request + /files/ 代理 + SSE 配置
├── filebrowser/config.yaml             # proxy auth / sources / WebDAV
├── dsh-plugin-clamped-picker/index.mjs # 目录选择器根目录钳制插件
├── OPS.md                              # 运维手册（建号/离职/改密/WebDAV/排障）
```

## 快速开始

```bash
# 0a. 部署根不是 /home/ubuntu 时（配置里只能写绝对路径），先改根
./scripts/configure-root.sh --show        # 看当前配置里写的是哪个根
./scripts/configure-root.sh "$HOME"       # 改成实际部署路径，幂等可重复

# 0b. 首次部署：先看这台机器能拿到哪一档隔离（不猜，逐档真跑一次）
./dsh-runtime/dsh-sandbox.sh --report

#     按报告里的提示补前提，三选一即可：
./scripts/build-dsh-image.sh              # ① 有 docker：构建实例镜像，走最强的容器档
./scripts/install-bubblewrap.sh           # ② 宿主放行了 userns：无 root 装 bwrap
sudo ./scripts/apparmor-allow-userns.sh   #    Ubuntu 24.04+ 还要放行，先跑 --status 看是否必要
#                                         # ③ 内核 5.13+：landlock 档【无需任何准备】，验一下即可：
python3 dsh-runtime/dsh-landlock-exec.py --selftest
#                                         # ④ 容器内是 root 且没有 docker socket：uid 档无需准备

./scripts/preflight-sandbox.sh            # 逐项实测，全绿才算数（挑中哪一档都跑这个）

# 1. 全栈启动（幂等，可重复执行；建议加入容器 entrypoint）
./dsh-runtime/start-all.sh

# 2. 新员工建号 —— 推荐直接用管理后台 https://<IP>:8099/admin/
#    命令行等价物（与后台同一套逻辑）：
INIT_PW='初始密码' ./scripts/provision-user.sh wang_er 研发部 员工 王二
./scripts/deprovision-user.sh wang_er          # 离职（默认保留文件）

# 3. 访问
#    https://<IP>:8099/admin/          员工管理后台（仅 admin）
#    https://<IP>:8099/files/          文件服务器
#    https://<IP>:8099/                个人 dsh 工作台
#    https://<IP>:9091/                登录门户
```

## 空间模型：一个用户一个空间，两边同步

| 角色 | 可访问空间 | FileBrowser scope | dsh 沙箱挂载 |
|------|-----------|-------------------|-------------|
| 员工 | 自己的目录 | `/departments/<部门>/<姓名>` | 同一目录（读写） |
| 主管 | 整个部门 | `/departments/<部门>` | 同一目录（读写） |
| admin | 整个公司 | source 全量 | `dsh-files`（读写） |

两边**不是各写一套**，而是都从 `admin/core.py` 的 `space_for()` 推导。这条曾经漂过：
FileBrowser 给了主管部门级 scope，dsh 侧却仍钳在个人目录，同一个人在文件服务器和
工作台里看到的范围对不上。现在改角色/改部门会同时更新两边，并重启实例让新挂载生效。

管理后台列表有一列 **两边同步**：拿 FileBrowser 里的**实际** scope 与该定义比对，
有人绕过后台直接改过权限就会显示「不一致」，点「编辑」保存一次即可纠正。

> 例外通道：确有跨部门协作需要时，`Engine.set_mounts()` 可以给某人额外挂载
> `dsh-files` 之内的目录（可选只读）。默认为空，且路径要经过解析符号链接后仍在
> `dsh-files` 之内的校验——挂不进 `/etc` 或别人的 `DSH_HOME`。

## 员工管理后台

`https://<IP>:8099/admin/`，经 Authelia 鉴权，只有管理员白名单里的账号能进
（`ADMIN_USERS` 环境变量，默认 `admin`）。

- **新增**：填用户名/姓名/部门/角色，一键完成 Authelia 建号、建目录、
  FileBrowser 权限、端口分配、nginx 路由、沙箱内启动实例
- **编辑**：改姓名/部门/角色。改部门会连带迁移工作区文件、更新 FileBrowser
  scope、以新工作区重启实例
- **删除**：停实例 + 清四个子系统 + 删实例状态；工作区文件默认保留，
  可勾选一并永久删除（需输入用户名二次确认）
- **同步状态**：每行五个圆点显示该用户在
  Authelia / nginx / FileBrowser / dsh 实例 / 工作区目录 五处是否一致，
  有人手工改过配置就会变红

鉴权是两道：nginx 注入的 `X-Admin-Token` 共享密钥 + Authelia 的 `Remote-User`
必须在管理员白名单里。前者是为了防住沙箱内的 dsh——它能连上 `127.0.0.1:19200`，
但读不到宿主上的密钥文件。

## 关键实现要点（踩坑记录）

- **FileBrowser v1.5.2 proxy auth**：CLI 建的用户默认 `loginMethod=password`，必须 API 改为
  `loginMethod=proxy` 且 `api=true`，否则全部 API 返回 401
- **PUT permissions 不带 delete 字段会重置为 false**
- **SSE 过 nginx** 必须 `proxy_buffering off; proxy_cache off;`
- **nginx 用户路由必须用 http 段的 `map $user`**：site 文件里 rewrite 阶段的 if 拿不到
  `$user`（auth_request_set 在 access 阶段才赋值），懒求值只对 map 生效
- **Authelia 多域访问**：公网 IP 是云 NAT 不绑网卡时，需在 session.cookies 与
  access_control 同时追加局域网 IP / 127.0.0.1 域，否则非公网域名访问返回 400/500
- **目录选择器钳制**：dsh 的 picker 官方不支持按部署限根；`-auto` 选择器运行时晚挂载会
  覆盖 patch 服务，须禁用它并直接挂载钳制后端 + 客户端 surface 包，
  允许根由实例进程的 `DSH_ALLOWED_ROOT` 注入

## 持续集成

`.github/workflows/ci.yml`，每次 push / PR 自动跑八个 job：

| job | 内容 |
|-----|------|
| `tests` | 109 项单元与接口测试。装 bubblewrap 后**真跑沙箱**，并断言隔离测试没有被 skip——否则 CI 绿得没有意义 |
| `isolation-report` | 搭一棵仿真部署树跑 `preflight-sandbox.sh`，结果写进 Actions 的 Summary 页 |
| `shell` | 全部 `.sh` 的 `bash -n` + shellcheck |
| `nginx-config` | 按线上的 `/home/ubuntu` 绝对路径布好目录树，真跑 `nginx -t`，并断言两张路由 map、`/files` 重定向、`/admin/` 与 `/files/` 的 `auth_request` 都在 |
| `secrets-hygiene` | 仓库里不得出现私钥、真实 argon2 哈希，以及 `admin/.admin-token` / `nginx/conf/generated/` / `registry.json` 等运行数据 |
| `env-matrix` | **环境形状矩阵**：用不同的 `docker run` 参数把同一套验收丢进「非 root 容器无 docker」「root 容器」「挂了宿主 docker socket 的容器（= 现场那台）」「特权容器」几种形状里跑，断言每种形状下都挑对了档、且那一档真的隔离住了；一档都挑不出来的形状则断言它确实拒绝启动 |

本地跑全套：

```bash
sudo apt-get install -y bubblewrap     # 隔离测试需要，没装则自动跳过
python3 -m unittest discover -s tests -v
```

## 安全说明

- 所有密钥/密码哈希/明文初始密码/TLS 私钥均不入库；配置以 `.example` 模板提供
- 后端服务全部绑定 127.0.0.1，仅 nginx 监听公网端口。**注意**：dsh 自身的监听地址
  未显式指定，首次部署请用 `ss -ltnp | grep -E '3080|1310'` 确认是 `127.0.0.1` 而非
  `0.0.0.0`——若是后者，直连实例端口可完全绕过 SSO
- 用户名/姓名/部门经白名单校验后才写入 YAML、nginx 配置和文件路径

> **隔离档位由环境决定，不是写死的**，完整推理见 [DESIGN.md](DESIGN.md)。
> 第一版把一切押在 bubblewrap 上，而它要求内核放行非特权 user namespace——
> 那个开关在宿主机上、容器内改不了，与「容器内部署」的前提直接冲突，现场因此
> 一天没生效过。现在 `dsh-sandbox.sh` 会逐档真跑一次再决定用哪一档。
> 先跑 `./dsh-runtime/dsh-sandbox.sh --report` 看这台机器落在哪一档。

### 工作区隔离（两层）

| 层 | 机制 | 挡得住什么 |
|----|------|-----------|
| 内核 | 隔离调度器 `dsh-runtime/dsh-sandbox.sh` 选中的那一档（见下表） | 一切文件访问。工作区以外的路径在实例内不存在或读不到，bash 用绝对路径也绕不过去 |
| UX | 目录选择器钳制插件（`dsh-plugin-clamped-picker`） | 选择器默认开在根目录、面包屑不显示上层 |

各档按隔离强度排序，调度器挑第一个**在这台机器上真跑得起来**的：

| 档 | 机制 | 前提 |
|----|------|------|
| `container` | 每实例一个独立容器：mount/net/pid ns + 独立 UID + 资源限额 | 够得到 docker 守护进程 |
| `bwrap` | bubblewrap 挂载命名空间 | 非特权 userns，或容器内 root + CAP_SYS_ADMIN |
| `landlock` | 内核的非特权自我沙箱：文件系统 + TCP 端口 + 信号（无 pid ns） | **只需内核 5.13+，不要 root、不要 userns、不要 docker** |
| `uid` | 独立 OS 用户 + 文件权限（无 pid/net ns，如实标注） | 容器内 root，且**摸不到 docker socket** |
| `none` | 无隔离，仅排障 | 必须 `DSH_ALLOW_UNCONFINED=1` 显式放行 |

实例内可见的全部内容：系统运行时（只读）、node+dsh 程序（只读）、共享插件（只读）、
本人 DSH_HOME（读写）、本人工作区（读写）、`/proc` `/dev` 私有 `/tmp`。
`dsh-auth/`（含全员明文初始密码）、`nginx/certs/`（TLS 私钥）、`filebrowser/`
（权限库）、`admin/`（后台代码与 token）、其他部门与其他员工的目录、
以及 `/var/run/docker.sock` **均碰不到**。

一档都挑不出来时 `start-all.sh` 拒绝启动任何实例、管理后台拒绝建号——宁可服务
不可用，也不退回无隔离运行。逐项原因看 `dsh-sandbox.sh --report`；排障可用
`DSH_ALLOW_UNCONFINED=1` 显式放行（会大声告警）。

用 `./scripts/preflight-sandbox.sh` 实测验收，它不看配置写了什么，只看实际能不能读到。

### 网络隔离（可选，默认关闭）

沙箱默认与宿主共享网络命名空间（dsh 要出网调模型 API），因此能连到
`127.0.0.1` 上的服务。其中 FileBrowser 与管理后台已用密钥头挡住，
但**员工 A 可以直连员工 B 的 dsh 端口**驱动其 agent —— 这是残留风险。

`DSH_NETNS=1` 关掉这条路：每个实例跑在自己的网络命名空间里（pasta 提供出网
与 DNS 转发），入站改走 unix socket，**宿主回环上不再留下任何 dsh 端口**，
没有端口也就无从连起。

```bash
sudo apt-get install -y passt socat        # 新增依赖
export DSH_NETNS=1                         # 写进容器 entrypoint 环境
./dsh-runtime/start-all.sh
python3 admin/cli.py sync-nginx            # nginx upstream 换成 unix socket
./scripts/preflight-sandbox.sh             # 验收
```

已在 GitHub runner 上实测（`tests/test_sandbox.py::NetnsIsolationTest`，
每次 CI 都会真跑）：宿主 `ss -ltn` 中不再有 dsh 端口、员工 A 经回环 / 经宿主
网卡 / 经他人 socket 三条路都连不到 B、nginx 经 unix socket 正常代理、
沙箱内 DNS 与出网 HTTPS 均正常。

> 默认不开是因为它引入两个新依赖，且 dsh 侧的行为无法在开发环境完全验证。
> 建议先在单个员工实例上开启验证，再全量切换。

### 已知残留风险（随选中的档位而变）

| 风险 | container | bwrap（默认） | bwrap + `DSH_NETNS=1` | landlock | uid |
|------|-----------|--------------|----------------------|----------|-----|
| 员工 A 直连员工 B 的 dsh 端口驱动其 agent | 已封堵（各自独立 netns，端口只发布到宿主回环） | **未封堵** | 已封堵（宿主回环上不留 dsh 端口） | 已封堵（TCP 端口白名单，ABI v4+） | **未封堵** |
| `ps` 看到全机进程与命令行 | 已封堵 | 已封堵 | 已封堵 | **未封堵** | **未封堵** |
| 一个员工吃光内存拖垮全体 | 已封堵（`--memory`/`--cpus`/`--pids-limit`） | 未封堵 | 未封堵 | 未封堵 | 未封堵 |
| 主管的部门级权限 | 支持 | 支持 | 支持 | 支持 | 需文件系统支持 ACL |

与档位无关、已封堵的两条：

- FileBrowser API —— 代理认证头的**名字**改成了随机密钥，实例内读不到配置故拿不到
- 管理后台 API —— 要求 nginx 注入的 `X-Admin-Token`

「员工 A 直连 B」这条之所以存在，是因为 dsh 本身对入站请求不做身份校验，
路由完全靠 nginx 的 `map $user`。`preflight-sandbox.sh` 的第 5 节会把这项在
当前档位下的实际状态测出来。

详见 [OPS.md](OPS.md)。

# 隔离方案设计

## 一、先认错：判断失误在哪

第一版把整个隔离押在 **bubblewrap** 上。它要求内核允许**非特权 user
namespace**，而这个开关在宿主机上、容器内改不了。

问题不在 bwrap 不好，而在于**我选它之前没有确认这个前提成立，而这个前提恰好
与本项目「容器内部署」的基本约束相冲突**。更糟的是我在当时的
`dsh-sandbox.sh` 日志里亲手写下过「这是宿主机的内核设置，容器内改不了」——
也就是说我意识到了，却没有让它改变方案，而是继续往上加了 netns、unix socket
等一层层东西。

代价：现场部署下来隔离一天也没生效过，实例一直以 `DSH_ALLOW_UNCONFINED=1`
裸跑。功能全通掩盖了核心目标没达成。

第二版（`DESIGN.md` 上一稿）的结论是「改用独立容器」。方向对，但**仍然是同一
类错误**：拿现场那一台机器的形状，去定死一个要跑在任意容器里的项目。这一版把
它改掉。

## 二、根本约束（决定了所有方案的形状）

在**单个容器、所有 dsh 实例同为一个 OS 用户、无命名空间**这三条同时成立时，
**员工之间的隔离在数学上就不可能**：

- 文件权限（DAC）以 UID 为单位，两个同 UID 的进程在内核眼里没有区别
- 应用层限制（目录选择器钳制）挡不住 dsh 的 bash 工具，它可以用绝对路径直接读写
- 于是没有任何强制点

**能做强制点的只有三种边界**，每一种都需要一个前提：

| 边界 | 需要什么 | 对应后端 |
|------|---------|---------|
| 不同容器 | 够得到 docker 守护进程 | `container` |
| 命名空间 | 非特权 userns（宿主放行）**或** 容器内 root + CAP_SYS_ADMIN | `bwrap` |
| 不同 UID | 容器内 root（能 `useradd`）**且** 摸不到 docker socket | `uid` |

三条都拿不到就是做不到。任何声称在那种条件下实现了隔离的方案都是自欺，所以第
四档 `none` 只能显式放行、只供排障。

## 三、结论：不选一种，而是按环境探测择优

隔离层的入口仍然是那一个脚本、那一个接口：

```
dsh-runtime/dsh-sandbox.sh <username> <port> <dsh_home> <workspace>
```

但它现在是**调度器**，不是某一种机制的实现。它按隔离强度从强到弱逐档探测，
挑第一个**在这台机器上真的能跑起来**的：

```
dsh-runtime/
├── dsh-sandbox.sh            调度器：探测 + 择优 + fail-closed
├── dsh-container-entry.sh    容器内入口（端口桥接）
├── dsh-netns-entry.sh        bwrap netns 模式的容器内入口
├── Dockerfile.instance       实例镜像
└── backends/
    ├── common.sh             挂载解析、环境变量白名单、形状探测（共用）
    ├── container.sh          ① 独立容器
    ├── bwrap.sh              ② 挂载命名空间（userns / privileged 两种形态）
    ├── uid.sh                ③ 独立 OS 用户 + DAC
    └── none.sh               ④ 无隔离，仅排障
```

探测**不看配置、不看版本号，直接跑一次真家伙**：bwrap 真 `--unshare-all` 一
次，容器后端真起一个探针容器去看挂载对不对。「装了但跑不起来」和「没装」在选
择器眼里一视同仁——第一版正是因为只判 `-x`，让「存在但坏」走进沙箱分支反复失
败，运维只能把 bwrap 改名骗过检测。

`DSH_ISOLATION` 可以强制指定某一档（`container` / `bwrap` / `uid` / `none`，
也接受空格分隔的候选列表），默认 `auto`。

`dsh-sandbox.sh --report` 打印完整的能力报告：这台机器是不是容器、当前 uid、
userns 通不通、有没有 CAP_SYS_ADMIN、docker 够不够得着、每一档为什么可用或不
可用、最终选了哪一档。**运维不该读代码才知道为什么。**

### 各档给到什么、给不到什么

| | container | bwrap | uid | none |
|---|---|---|---|---|
| 工作区外的文件读不到 | ✔ 挂载隔离 | ✔ 挂载隔离 | ✔ DAC | ✘ |
| 员工之间互不可见 | ✔ | ✔ | ✔ | ✘ |
| 独立 pid ns（ps 看不到别人） | ✔ | ✔ | ✘ | ✘ |
| 独立 net ns（连不到别人的实例） | ✔ | 需 `DSH_NETNS=1` | ✘ | ✘ |
| 资源限额（内存/CPU/进程数） | ✔ | ✘ | ✘ | ✘ |
| docker socket 逃逸 | ✔ 不挂进去 | ✔ 不挂 `/var` | ✘ **一票否决** | ✘ |
| 主管的部门级权限 | ✔ 多挂一个卷 | ✔ 多挂一个 bind | 需文件系统支持 ACL | — |
| 前提 | 够得到 dockerd | userns 或 root+CAP_SYS_ADMIN | 容器内 root 且无 docker socket | 显式放行 |

`uid` 档那一行的 ✘ 是决定性的：容器里有 docker socket、员工的 dsh 又有 shell，
够得到就是一句话逃逸——

```bash
docker run -v /:/host alpine cat /host/etc/shadow
```

所以 `backends/uid.sh` 的 probe **检测到 docker socket 就拒绝选用自己**，让位
给本来就更强的 container 档。UID 机制是为「互相协作的用户」设计的，不是为
「互相敌对、且每人手握 shell 的租户」设计的——本项目每个 dsh 都属于后者。

### 现场那台机器落在哪一档

已实测确认：`/.dockerenv` 存在（在容器里）、`ubuntu ∈ docker(994)`（够得到
socket）、`sudo` 需密码、`apparmor_restrict_unprivileged_userns=1`。逐档过一遍：

- container：docker 可达 → **可用，选它**
- bwrap：userns 被宿主拦住，容器内改不了 → 不可用
- uid：非 root，且有 docker socket → 双重不可用
- none：当前正是这一档在跑，**所以现在每个员工的 dsh 都能逃到宿主 root**

**这台机器上，实例应当先停掉，等 container 档就位再拉起。**

### 容器后端落地时第一个会踩的坑：volume 路径

容器里的 docker 有两种形态，`-v` 左边的写法完全不同：

- **sibling（挂宿主 socket，最常见）**：起出来的是**宿主的兄弟容器**，`-v`
  左边必须是**宿主上的绝对路径**。写当前容器内的路径会挂到空目录——容器能起
  来但挂载是错的，比起不来更难查。
- **DinD（容器内自己的 dockerd）**：路径就是容器内的路径，不用换算。

`backends/container.sh` 不靠猜：先 `docker inspect` 自省本容器的 Mounts 建出
「容器内路径 → 宿主路径」映射表（`DSH_HOST_ROOT` 可显式覆盖），再**真起一个
探针容器去看标记文件在不在**。验不过就 probe 失败，绝不带着错误的映射启动实
例。映射表按最长前缀匹配，匹配不上直接失败，不会悄悄回落成恒等映射。

## 四、怎么验：不在一台机器上验，在一组形状上验

`.github/workflows/ci.yml` 的 `env-matrix` 用不同的 `docker run` 参数把同一套
验收脚本（`tests/env-shape.sh`）丢进几种真实会遇到的形状里跑：

| 形状 | 怎么造出来 | 期望 |
|------|-----------|------|
| 容器·非 root·无命名空间·无 docker | `--user <uid>`，不挂 socket | **拒绝启动**（fail-closed） |
| 容器·root·无命名空间·无 docker | root，不挂 socket | 选 `uid`，隔离验收全过 |
| 容器·非 root·挂了宿主 docker socket | `-v /var/run/docker.sock:...`（= 现场那台） | 选 `container`，隔离验收全过 |
| 容器·root·特权 | `--privileged` | 选 `bwrap`（privileged 形态） |
| 宿主·userns 放开 | runner 本机 + `sysctl=0` | 选 `bwrap`（userns 形态），99+ 项单测 |

每个形状都跑完整的 `preflight-sandbox.sh`：**真去 cat 那些不该读到的文件**
（全员明文初始密码、Authelia 用户库、TLS 私钥、FileBrowser 权限库、管理后台
token、其他部门与同部门同事的文件），读到了就红。不看配置写了什么。

仓库刻意挂到容器里的**另一个路径**（`$PWD` → `/deploy`），逼容器后端自己算出
宿主路径；路径同构的话这段逻辑就白写了。

## 五、这次改动的边界

| 动作 | 内容 |
|------|------|
| 新增 | `dsh-sandbox.sh` 改为调度器；`backends/` 四个后端 + `common.sh`；`dsh-container-entry.sh`；`Dockerfile.instance`；`scripts/build-dsh-image.sh`；`scripts/make-fake-deploy.sh`；`tests/env-shape.sh`；CI `env-matrix` |
| 改 | `preflight-sandbox.sh` 改为按后端分档判定（uid 档没有 pid ns，如实标注为 info 而不是伪装成通过）；启动脚本与管理后台横幅显示当前档位 |
| 不动 | nginx 路由、空间模型 `space_for()`、建号引擎、管理后台 API、密钥头机制、`core.py` 与隔离层的接口 |

`core.py` 与隔离层的耦合仍然只有那一行 `dsh-sandbox.sh <user> <port> <home>
<ws>`，加上新增的 `--backend` 查询。当初把它做成一个独立脚本而不是散落各处，
这次换成四个后端时上层一行没动。

## 六、与隔离机制无关、但现在就该做的

- 删掉 `dsh-auth/initial-credentials.txt`（全员明文初始密码）。管理后台已改为
  「建号时显示一次、不落盘」，这个历史文件没有存在必要
- TLS 私钥考虑移到容器外由宿主 nginx 持有
- 保留 FileBrowser 与管理后台的密钥头机制（现网已验证能挡住伪造 admin）
- `preflight-sandbox.sh` 是唯一判据：**功能全通 ≠ 隔离生效**

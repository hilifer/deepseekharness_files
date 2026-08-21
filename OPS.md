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

### 3. 手工修复（后台不可用时的兜底）

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

## 工作区隔离

分两层，内核层是真边界，UX 层只管好看。

### 第一层（内核）：bubblewrap 挂载命名空间

所有 dsh 实例（含 admin）都经 `dsh-runtime/dsh-sandbox.sh` 启动。工作区以外的路径
**在实例内根本不存在**——不是「没权限」，是那个 inode 不在这个 mount namespace 里，
所以 dsh 的 bash 工具用绝对路径也读不到。

沙箱内可见的全部内容：

| 挂载 | 内容 |
|------|------|
| 只读 | `/usr /bin /sbin /lib* /etc`、`node/`（含 dsh 本体）、共享 `profiles/` |
| 读写 | 本人 `dsh-users/<user>/`、本人工作区 |
| 其他 | `/proc`、`/dev`、私有 `/tmp` |

**不存在**：`dsh-auth/`（全员明文初始密码、用户库）、`nginx/certs/`（TLS 私钥）、
`filebrowser/`（权限库）、`admin/`（后台代码与 token）、`dsh-users/registry.json`、
其他部门与其他员工的目录。另外 `--unshare-pid` 使实例内 `ps` 看不到宿主进程，
顺带堵住了 `authelia crypto hash --password` 在命令行上短暂暴露密码的问题。

共享 `profiles/` 挂成**只读**：此前它对所有实例可写，任何员工都能改写
`clamped-picker/index.mjs` 影响全体。

```bash
/home/ubuntu/scripts/install-bubblewrap.sh    # 无 root 安装（解包 deb）
/home/ubuntu/dsh-runtime/dsh-sandbox.sh --check
/home/ubuntu/scripts/preflight-sandbox.sh     # 逐项实测验收
```

**fail-closed**：沙箱不可用时 `start-all.sh` 不启动任何实例、管理后台拒绝建号。
排障可用 `DSH_ALLOW_UNCONFINED=1` 显式放行，会打出醒目告警。

#### 排障：`bwrap: setting up uid map: Permission denied`

最常见的一种失败，本项目的 CI 在 GitHub 的 ubuntu-24.04 runner 上实际撞到过。
原因是 **Ubuntu 24.04 起 AppArmor 默认拦截非特权 user namespace**：

```bash
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns   # 为 1 即被拦
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0            # 临时
echo 'kernel.apparmor_restrict_unprivileged_userns=0' \
  | sudo tee /etc/sysctl.d/60-dsh-userns.conf && sudo sysctl --system    # 永久
```

**注意这个 sysctl 在容器内改不了，必须在宿主机上设置**——本部署跑在 rootless
容器里，如果宿主是 Ubuntu 24.04+ 且你拿不到宿主的 root，这条路走不通。
那种情况下的替代方案是给每个员工建独立的 OS 账号，靠文件系统属主+700 权限
做隔离（同样需要 root，但只需一次性配置）。

`dsh-sandbox.sh --check` 会自动判别是这条还是别的原因，并打出对应的处理命令。

### 第二层（UX）：目录选择器钳制

插件 `~/.local/share/dsh/profiles/web/clamped-picker/index.mjs` 让选择器默认开在
根目录、面包屑不显示上层、越界返回 `directory-unreadable`。允许根来自实例进程的
`DSH_ALLOWED_ROOT`，由 `dsh-sandbox.sh` 从登记表传入。

注意这一层**只覆盖选择器的 list/createDirectory**，dsh 的 bash 和文件读写工具
完全不经过它——所以它从来不是安全边界，真正的边界是第一层。

> 允许根的来源已从 `storages/workspace.json` 改为 `dsh-users/registry.json`。
> 前者是实例自己（也就是被约束方）在写的：用户删光工作区就能让推导结果为空，
> 进而拿到不设限的实例。约束的依据不能由被约束方提供。

## 残留风险：实例间的网络可达性

沙箱与宿主**共享网络命名空间**（dsh 要出网调模型 API），所以实例仍能连
`127.0.0.1` 上的服务。

已封堵（靠「能连上 ≠ 能调用」）：

| 目标 | 手段 |
|------|------|
| FileBrowser API `:18080` | 代理认证头的**名字**是随机密钥，配置在沙箱内不可见 |
| 管理后台 API `:19200` | 要求 nginx 注入的 `X-Admin-Token`，密钥文件在沙箱内不可见 |

密钥由 `scripts/init-secrets.sh` 生成（幂等，`start-all.sh` 会自动调用），
落在 `nginx/conf/generated/`（600，已 gitignore）。轮换：删掉
`admin/.admin-token` 和 `nginx/conf/generated/fb-auth.conf` 后重跑该脚本，
再 `fb-start.sh restart` + `nginx-start.sh reload`。

**未封堵**：员工 A 的实例可直连员工 B 的 dsh 端口 `127.0.0.1:1310x`，驱动 B 的
agent 读写 B 的工作区。dsh 对入站请求不做身份校验，路由完全靠 nginx 的 `map $user`。

完整修复需要给每个实例独立网络命名空间：`--unshare-net` 后用 `pasta`（passt 包）
提供出网 + 入站端口转发，并加 `--no-map-gw` 断掉经网关回连宿主的路径。
本仓库没有默认启用，因为它无法在开发环境验证，贸然上线会让全部实例起不来。
上线前请先在单个实例上验证 dsh 的出网和 nginx 的入站都正常。
`preflight-sandbox.sh` 第 4 节会把这项的实际状态测出来。

## 容器入口点

容器启动后自动执行：
```bash
/home/ubuntu/dsh-runtime/start-all.sh
```
确保所有服务（dsh/authelia/nginx/filebrowser + 每用户 dsh 实例）幂等启动。
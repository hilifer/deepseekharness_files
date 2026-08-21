# 公司文件服务器 — 运维操作手册

## 系统架构

```
https://192.168.1.225:8099/           ← 局域网/本机入口（dsh 工作台 / + 文件服务器 /files/）
https://127.0.0.1:8099/               ← 仅服务器本机可用
https://218.17.143.249:8099/          ← 公网入口（需云安全组放行 8099/9091 并 NAT 转发到 192.168.1.225）
https://192.168.1.225:9091/           ← Authelia 登录门户
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

### 2. 新员工入职
```bash
# 用法：provision-user.sh <拼音用户名> <中文名> <部门> <角色>
# 角色：主管=可删部门文件，员工=不可删除
/home/ubuntu/scripts/provision-user.sh wang_er 王二 研发部 员工
# 输出：dsh 端口、初始密码（见 initial-credentials.txt）
```

### 3. 员工离职（禁用账号）
```bash
# 方式 A：停用 dsh 实例
pkill -f "dsh web --port <端口>"
# 方式 B：在 Authelia 中删除账号
# 编辑 /home/ubuntu/dsh-auth/config/users_database.yml，删除对应行
# 重启 authelia: /home/ubuntu/dsh-auth/authelia-start.sh restart
# 同时更新 /home/ubuntu/dsh-runtime/start-all.sh 或 ports.json 移除该用户
```

### 4. 密码重置
```bash
# 生成 argon2 哈希
/home/ubuntu/dsh-auth/authelia crypto hash generate argon2 --password '新密码'
# 编辑 users_database.yml，替换对应行的 password 字段
# 验证配置
/home/ubuntu/dsh-auth/authelia --config /home/ubuntu/dsh-auth/config/configuration.yml validate-config
# 重启（注意：会清空所有已登录会话）
/home/ubuntu/dsh-auth/authelia-start.sh restart
```

### 5. 检查服务状态
```bash
# 各端口健康检查
for port in 3080 9091 8099 18080 13101 13102 13103; do
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
| 端口分配 | `/home/ubuntu/dsh-users/ports.json`（13101 起始递增） |
| 账号密码 | `/home/ubuntu/dsh-auth/initial-credentials.txt`（600 权限） |
| 操作手册 | 本文件 `/home/ubuntu/scripts/OPS.md` |

## 目录选择器钳制（多租户隔离）

dsh 的「新建工作区」目录选择器默认可浏览整个文件系统。本部署通过自定义插件
`~/.local/share/dsh/profiles/web/clamped-picker/index.mjs` 将其钳制到每实例自己的根目录：

- 机制：patch 层禁用 stock `-auto` 选择器，挂载 `BrowseDirectoryPicker` 子类；
  允许根目录来自实例进程的 `DSH_ALLOWED_ROOT` 环境变量（start-all.sh 从各用户
  `storages/workspace.json` 的首个工作区路径自动推导；dsh-start.sh 为 admin 固定
  注入 `~/dsh-files`；provision-user.sh 为新用户注入其个人目录）。
- 效果：选择器默认打开即根目录、面包屑不显示根目录之上层级、越界路径返回
  `directory-unreadable` 错误。
- 边界：这是 UX 层钳制。若需内核级强制（防 API 直调 `workspace.create`），
  需另行启用 dsh 的 bash/fs 沙箱（bwrap/Landlock），当前未启用。
- 注意：profiles 目录为全体实例共享，改动 patch 文件影响所有实例；改后需重启实例生效。

## 容器入口点

容器启动后自动执行：
```bash
/home/ubuntu/dsh-runtime/start-all.sh
```
确保所有服务（dsh/authelia/nginx/filebrowser + 每用户 dsh 实例）幂等启动。
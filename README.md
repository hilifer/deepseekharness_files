# 公司文件服务器 — FileBrowser Quantum + Authelia SSO + 每员工独立 dsh 实例

单端口公司文件服务器与 AI 工作台部署方案：

- **统一入口** `https://<IP>:8099`：`/` 为每员工独立 dsh 工作台，`/files/` 为 FileBrowser 文件服务器
- **SSO**：Authelia 单点登录，proxy auth 透传用户身份，应用零密码暴露
- **权限中心**：FileBrowser 按 scope 隔离部门/个人目录；主管可删本部门文件，员工只读+上传
- **多租户 dsh**：每员工一个独立进程/端口/数据目录的 DeepSeek Harness 实例，nginx 按登录名路由
- **目录选择器钳制**：自定义 cordis 插件把「新建工作区」限制在本人根目录内

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
├── scripts/
│   ├── provision-user.sh      # 一键建号（Authelia+目录+FileBrowser+dsh 实例+nginx 路由）
│   └── fb-start.sh            # FileBrowser 启动脚本
├── dsh-runtime/
│   ├── start-all.sh           # 全栈幂等启动入口（容器 entrypoint 调用）
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
# 1. 全栈启动（幂等，可重复执行；建议加入容器 entrypoint）
./dsh-runtime/start-all.sh

# 2. 新员工建号（自动完成 Authelia 建号、目录创建、FileBrowser 权限、
#    端口分配、nginx 路由、dsh 实例启动）
INIT_PW='初始密码' ./scripts/provision-user.sh wang_er 研发部 员工 王二

# 3. 访问
#    https://<IP>:8099/files/          文件服务器
#    https://<IP>:8099/                个人 dsh 工作台
#    https://<IP>:9091/                登录门户
```

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

## 安全说明

- 所有密钥/密码哈希/明文初始密码/TLS 私钥均不入库；配置以 `.example` 模板提供
- 后端服务全部绑定 127.0.0.1，仅 nginx 监听公网端口
- 目录选择器钳制是 UX 层隔离；如需内核级强制请启用 dsh 的 bash/fs 沙箱（bwrap/Landlock）

详见 [OPS.md](OPS.md)。

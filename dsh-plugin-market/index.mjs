export const name = "plugin-market";
export const inject = [];

export function apply(_ctx) {
  // 服务端无逻辑：插件市场的安装/卸载/白名单全部在 admin 后台（core.py），
  // 客户端经 nginx 的 /plugin-market/ 路由直连 admin 后台。这里只提供空
  // apply，让 bundle 的 cordis.patch.yml insert 能被 loader 正常加载。
}

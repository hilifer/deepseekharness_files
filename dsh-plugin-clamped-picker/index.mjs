// Clamped directory picker for multi-tenant dsh deployments.
//
// Replaces the stock BrowseDirectoryPicker service so that BOTH the listing
// and the create-directory primitives are fenced under ONE allowed root taken
// from the DSH_ALLOWED_ROOT env var of the instance process. When the env var
// is unset/empty the class degrades to exact stock behavior (whole filesystem).
//
// UX fencing (not a kernel security boundary): listings outside the root fail
// with DirectoryPickerError('directory-unreadable'), and breadcrumb ancestors
// above the root are trimmed from every listing so the dialog cannot even
// display jump targets above it. The default listing target (client opens the
// dialog without a path) becomes the ROOT itself instead of the OS homedir.
import { realpathSync } from 'node:fs'
import { resolve, sep } from 'node:path'

// 路径随部署根而变，由 dsh-sandbox.sh 通过 DSH_PKGS 注入；
// 未注入时回退到默认部署位置。
const DSH_PKGS =
  process.env.DSH_PKGS ||
  `${process.env.DSH_NODE_ROOT || '/home/ubuntu/node'}/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai`

const { DirectoryPickerError } = await import(
  `file://${DSH_PKGS}/dsh-host-directory-picker/lib/index.js`
)
const BrowseDirectoryPicker = (
  await import(`file://${DSH_PKGS}/dsh-host-directory-picker-browse/lib/index.js`)
).default

// 允许根可以有多个：本人工作区，外加主管的部门目录、管理员配置的共享空间。
// DSH_ALLOWED_ROOTS 每行一条；没有它时回退到单个 DSH_ALLOWED_ROOT。
const rawRoots = (
  process.env.DSH_ALLOWED_ROOTS || process.env.DSH_ALLOWED_ROOT || ''
)
  .split('\n')
  .map((r) => r.trim())
  .filter(Boolean)

const ROOTS = []
for (const r of rawRoots) {
  try {
    ROOTS.push(realpathSync(r))
  } catch {
    console.error(`[clamped-picker] allowed root "${r}" does not exist; ignored`)
  }
}
if (rawRoots.length > 0 && ROOTS.length === 0) {
  console.error('[clamped-picker] no allowed root resolved; picker runs UNCLAMPED')
}
// 主根用于「客户端没给路径时打开哪儿」，取第一个（core.py 保证是本人工作区）
const ROOT = ROOTS.length > 0 ? ROOTS[0] : null

const under = (abs) => ROOTS.some((r) => abs === r || abs.startsWith(r + sep))

class ClampedDirectoryPicker extends BrowseDirectoryPicker {
  #clamp(p) {
    const abs = resolve(p)
    if (!under(abs)) {
      throw new DirectoryPickerError(
        'directory-unreadable',
        abs,
        `"${abs}" is outside the allowed roots: ${ROOTS.join(', ')}`
      )
    }
    return abs
  }

  async list(path, signal) {
    if (ROOT === null) return super.list(path, signal)
    const target = path === undefined || path === '' ? ROOT : this.#clamp(path)
    const listing = await super.list(target, signal)
    // 面包屑只保留落在某个允许根内的层级，越过根的祖先不显示
    listing.crumbs = listing.crumbs.filter((c) => under(c.path))
    return listing
  }

  async createDirectory(path, name) {
    if (ROOT === null) return super.createDirectory(path, name)
    return super.createDirectory(this.#clamp(path), name)
  }
}

export default ClampedDirectoryPicker

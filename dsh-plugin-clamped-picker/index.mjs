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

const DSH_PKGS = '/home/ubuntu/node/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai'

const { DirectoryPickerError } = await import(
  `file://${DSH_PKGS}/dsh-host-directory-picker/lib/index.js`
)
const BrowseDirectoryPicker = (
  await import(`file://${DSH_PKGS}/dsh-host-directory-picker-browse/lib/index.js`)
).default

let ROOT = null
if (process.env.DSH_ALLOWED_ROOT && process.env.DSH_ALLOWED_ROOT !== '') {
  try {
    ROOT = realpathSync(process.env.DSH_ALLOWED_ROOT)
  } catch {
    console.error(
      `[clamped-picker] DSH_ALLOWED_ROOT="${process.env.DSH_ALLOWED_ROOT}" does not exist; picker runs UNCLAMPED`
    )
  }
}

class ClampedDirectoryPicker extends BrowseDirectoryPicker {
  #clamp(p) {
    const abs = resolve(p)
    if (abs !== ROOT && !abs.startsWith(ROOT + sep)) {
      throw new DirectoryPickerError(
        'directory-unreadable',
        abs,
        `"${abs}" is outside the allowed root "${ROOT}"`
      )
    }
    return abs
  }

  async list(path, signal) {
    if (ROOT === null) return super.list(path, signal)
    const target = path === undefined || path === '' ? ROOT : this.#clamp(path)
    const listing = await super.list(target, signal)
    listing.crumbs = listing.crumbs.filter(
      (c) => c.path === ROOT || c.path.startsWith(ROOT + sep)
    )
    return listing
  }

  async createDirectory(path, name) {
    if (ROOT === null) return super.createDirectory(path, name)
    return super.createDirectory(this.#clamp(path), name)
  }
}

export default ClampedDirectoryPicker

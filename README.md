# NTFS Mac

Read/write NTFS drives on macOS (Apple Silicon), without kernel extensions and with SIP enabled.

- **Driver:** open-source [ntfs-3g](https://github.com/tuxera/ntfs-3g) (GPL) built against
  [FUSE-T](https://github.com/macos-fuse-t/fuse-t) (kext-less FUSE over a local NFS server).
- **`ntfsmac`**: CLI to list / mount / unmount / fix NTFS volumes.
- **`NTFS Mac.app`**: a Finder-style window (sidebar of drives, icon/list views, path bar, Quick Look,
  drag and drop) plus a menu-bar item. It wraps the CLI and asks for your admin password when needed.

macOS mounts NTFS read-only by itself. `ntfsmac mount` unmounts that read-only mount, mounts the
volume read-write via ntfs-3g, and on `unmount` hands it back to macOS.

**📖 Full instructions: [docs/GUIDE.md](docs/GUIDE.md)**: installing on a new Mac, first launch,
everyday use, automatic mounting, using drives with Windows, troubleshooting, updating, uninstalling.

## Quick start

Requires an Apple Silicon Mac with macOS 13+.

```sh
xcode-select --install                          # Apple's Command Line Tools (once)
# Homebrew (once): https://brew.sh
brew install --cask macos-fuse-t/cask/fuse-t   # FUSE-T, no kernel extension
git clone https://github.com/shukla-surendra/ntfs-mac.git && cd ntfs-mac
scripts/build-driver.sh                         # builds ntfs-3g into build/prefix
scripts/package-app.sh                          # -> dist/NTFS Mac.app
cp -R "dist/NTFS Mac.app" /Applications/ && open "/Applications/NTFS Mac.app"
```

Then select your drive in the sidebar and click **Mount Read-Write**, or tick **Mount drives
automatically** so drives become writable whenever you plug them in.

Optional: `swift build && scripts/selftest-root.sh` runs an end-to-end test on a throwaway disk image.
To use the app on another Mac, copy it there and install FUSE-T on that Mac
([details](docs/GUIDE.md#4-install-on-another-mac-copy-the-app)).

## CLI

```sh
.build/debug/ntfsmac doctor
.build/debug/ntfsmac list
sudo .build/debug/ntfsmac mount disk4s1
sudo .build/debug/ntfsmac unmount disk4s1 [--eject]
sudo .build/debug/ntfsmac fix disk4s1         # clear the dirty flag
```

Mount/unmount need root because raw disk devices (`/dev/diskXsY`) are root-only and ntfs-3g
refuses block devices as a normal user with an external FUSE library. Files you create are owned
by your user (uid/gid are passed through from `sudo`/the app).

## Using the window

It works like a Finder window on the selected drive ([more](docs/GUIDE.md#6-using-an-ntfs-drive)):

| Action | How |
|---|---|
| Switch drive / eject | Sidebar (⏏ button), or ⌘E |
| Icon or list view | Toolbar, or ⌘1 / ⌘2. Click column headers to sort; ▸ expands folders |
| Back / forward / up | ⌘[ / ⌘] / ⌘↑; or click a folder in the path bar |
| Open | Double-click, or ⌘↓ / ⌘O |
| Rename | Return (Esc cancels) |
| Quick Look | Space, or ⌘Y |
| New folder / duplicate | ⇧⌘N / ⌘D |
| Copy in or out | ⌘C / ⌘V, or drag to/from Finder; drags inside the drive move files |
| Delete | Delete key or ⌘⌫. NTFS has no Trash, so this is permanent (you're asked first) |
| Filter this folder | ⌘F |

## Automatic mounting (like the paid NTFS drivers)

Tick **"Mount drives automatically"** at the bottom of the app's sidebar (or the menu-bar item),
or run once:

```sh
sudo "/Applications/NTFS Mac.app/Contents/MacOS/ntfsmac" install-helper
```

This installs, with one admin-password prompt:

- a LaunchDaemon (`/Library/LaunchDaemons/dev.local.ntfsmac.automount.plist`) running
  `ntfsmac watch`, which mounts each newly plugged-in NTFS drive read-write for the logged-in user
  and opens it in Finder. A drive you unmount stays unmounted until you replug it. Log:
  `/var/log/ntfsmac.log`.
- a root-owned copy of the app in `/Library/Application Support/NTFSMac/` (the daemon never runs
  the user-writable copy in /Applications), and
- `/etc/sudoers.d/ntfsmac`, letting only your user run that copy's `mount`/`unmount` without a
  password, so the app's Mount/Unmount/Eject buttons stop prompting.

After updating the app, re-run `install-helper` to refresh the root-owned copy. Remove it all with
`sudo ntfsmac uninstall-helper` (or untick the box). Don't run another NTFS driver (EaseUS,
Paragon, Tuxera…) at the same time; they will fight over the disk.

## Safety notes

- Only **external** disks are listed; the boot disk is never touched.
- Windows **Fast Startup/hibernation** leaves NTFS in a state that is unsafe to write. ntfs-3g
  refuses to mount it; shut Windows down fully, or use `--force` (discards the hibernation file).
- `windows_names` is enabled so you can't create file names Windows can't open.
- Always unmount (or eject) before unplugging. ntfs-3g is solid but not a journal-replay-grade
  replacement for Windows `chkdsk`; keep backups of important data.
- Not code-signed with a Developer ID: the packaged app is ad-hoc signed. A copy built on the same
  Mac opens normally; a copy brought from another Mac must be allowed in System Settings ▸ Privacy &
  Security ▸ **Open Anyway** ([details](docs/GUIDE.md#4-install-on-another-mac-copy-the-app)).

## Layout

```
Sources/NTFSKit      discovery (diskutil), mount/unmount logic
Sources/ntfsmac      CLI
Sources/NTFSMacApp   window (Browser, Sidebar, FileViews, MainView) + menu-bar item
scripts/             build-driver, package-app, selftest-root
docs/GUIDE.md        install & user guide
```

## Licensing

ntfs-3g is GPL-2.0+ (driver) / LGPL-2.0+ (library). If you distribute the packaged app, you must
offer the ntfs-3g source and keep its license files. FUSE-T is installed separately by the user.

# NTFS Mac

Read/write NTFS drives on macOS (Apple Silicon), without kernel extensions and with SIP enabled.

- **Driver:** open-source [ntfs-3g](https://github.com/tuxera/ntfs-3g) (GPL) built against
  [FUSE-T](https://github.com/macos-fuse-t/fuse-t) (kext-less FUSE over a local NFS server).
- **`ntfsmac`**: CLI to list / mount / unmount / fix NTFS volumes.
- **`NTFS Mac.app`**: menu-bar app that wraps the CLI and asks for your admin password when needed.

macOS mounts NTFS read-only by itself. `ntfsmac mount` unmounts that read-only mount, mounts the
volume read-write via ntfs-3g, and on `unmount` hands it back to macOS.

## Setup

```sh
brew install --cask macos-fuse-t/cask/fuse-t   # one-time; approve in System Settings if asked
scripts/build-driver.sh                         # builds ntfs-3g into build/prefix
swift build                                     # CLI + app
scripts/selftest-root.sh                        # safe end-to-end test with a fake disk
scripts/package-app.sh                          # -> dist/NTFS Mac.app
```

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

## Safety notes

- Only **external** disks are listed; the boot disk is never touched.
- Windows **Fast Startup/hibernation** leaves NTFS in a state that is unsafe to write. ntfs-3g
  refuses to mount it; shut Windows down fully, or use `--force` (discards the hibernation file).
- `windows_names` is enabled so you can't create file names Windows can't open.
- Always unmount (or eject) before unplugging. ntfs-3g is solid but not a journal-replay-grade
  replacement for Windows `chkdsk`; keep backups of important data.
- Not code-signed with a Developer ID: the packaged app is ad-hoc signed. First launch may need
  right-click → Open.

## Layout

```
Sources/NTFSKit      discovery (diskutil), mount/unmount logic
Sources/ntfsmac      CLI
Sources/NTFSMacApp   menu-bar app
scripts/             build-driver, package-app, selftest-root
```

## Licensing

ntfs-3g is GPL-2.0+ (driver) / LGPL-2.0+ (library). If you distribute the packaged app, you must
offer the ntfs-3g source and keep its license files. FUSE-T is installed separately by the user.

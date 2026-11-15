# NTFS Mac — Install & User Guide

This guide takes you from a brand-new Mac to reading **and writing** Windows (NTFS) drives, and
explains how to use them day to day.

- [1. Background: why NTFS is read-only on a Mac](#1-background-why-ntfs-is-read-only-on-a-mac)
- [2. Requirements](#2-requirements)
- [3. Install on a new Mac (build from source)](#3-install-on-a-new-mac-build-from-source)
- [4. Install on another Mac (copy the app)](#4-install-on-another-mac-copy-the-app)
- [5. First launch](#5-first-launch)
- [6. Using an NTFS drive](#6-using-an-ntfs-drive)
- [7. Automatic mounting](#7-automatic-mounting)
- [8. Unplugging safely](#8-unplugging-safely)
- [9. Using the same drive with Windows](#9-using-the-same-drive-with-windows)
- [10. Command line](#10-command-line)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Updating](#12-updating)
- [13. Uninstalling](#13-uninstalling)

---

## 1. Background: why NTFS is read-only on a Mac

NTFS is the file system Windows uses. macOS can **read** NTFS drives by itself, but it can't
**write** to them: you can open and copy files *from* the drive, but you can't save, rename or delete.

NTFS Mac adds writing using two free, open-source parts:

| Part | What it does |
|---|---|
| **FUSE-T** | Lets file systems run as normal apps instead of kernel extensions. No need to lower Mac security (SIP stays on, no "Reduced Security" mode). |
| **ntfs-3g** | The well-known open-source NTFS driver (used by Linux for years). Bundled inside the app. |

When you mount a drive "read-write", NTFS Mac takes over the drive from macOS's built-in read-only
driver, mounts it with ntfs-3g, and gives it back to macOS when you unmount.

> **Which drives need this?** Only drives formatted as **NTFS**. Drives formatted as exFAT or
> FAT32 (MS-DOS) already work read-write on a Mac, so you don't need NTFS Mac for them. To check a
> drive's format, select it in Finder and choose **File ▸ Get Info**; NTFS drives show
> "Format: Windows NT File System (NTFS)".

---

## 2. Requirements

| | |
|---|---|
| Mac | Apple Silicon (M1 or later). The build targets the Mac it is built on. |
| macOS | 13 Ventura or later |
| Disk space | About 1 GB while building (Command Line Tools + sources) |
| Internet | Needed once, to download tools and the ntfs-3g source |
| Admin account | Needed to install FUSE-T and to mount drives |

---

## 3. Install on a new Mac (build from source)

Do these steps once, in **Terminal** (Applications ▸ Utilities ▸ Terminal). Paste each command,
press Return, and wait for it to finish before running the next.

### Step 1: Install Apple's Command Line Tools

These give you `git`, the Swift compiler and other build tools.

```sh
xcode-select --install
```

A window appears. Click **Install** and accept the license. It takes a few minutes. (If it says
the tools are *already installed*, go to the next step.)

### Step 2: Install Homebrew

Homebrew is the standard package manager for the Mac. Skip this step if `brew --version`
already works.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

At the end, the installer prints **"Next steps"** with two or three commands that add `brew` to
your PATH. **Run them**, then check:

```sh
brew --version
```

### Step 3: Install FUSE-T

```sh
brew install --cask macos-fuse-t/cask/fuse-t
```

Enter your Mac password if asked. FUSE-T has no kernel extension, so you don't need to restart or
change any security settings. If macOS shows a prompt about FUSE-T, allow it.

### Step 4: Get the NTFS Mac source

```sh
cd ~
git clone https://github.com/shukla-surendra/ntfs-mac.git
cd ntfs-mac
```

### Step 5: Build the NTFS driver (ntfs-3g)

```sh
scripts/build-driver.sh
```

This automatically installs a few build tools with Homebrew (`autoconf`, `automake`, `libtool`,
`gettext`), downloads the ntfs-3g source, and builds it into `build/prefix/`. It takes a few
minutes. It finishes with `ntfs-3g installed in …/build/prefix`.

### Step 6: Build the app

```sh
scripts/package-app.sh
```

This finishes with `Built: …/dist/NTFS Mac.app`.

*Optional but recommended:* run the self-test. It creates a small fake NTFS disk in a temporary
file, mounts it, writes to it and cleans up. It never touches your real drives. It asks for your
password once.

```sh
swift build && scripts/selftest-root.sh     # should end with PASS
```

### Step 7: Move the app to Applications

```sh
cp -R "dist/NTFS Mac.app" /Applications/
open "/Applications/NTFS Mac.app"
```

Continue with [First launch](#5-first-launch).

---

## 4. Install on another Mac (copy the app)

You can build once and copy `NTFS Mac.app` to other Apple Silicon Macs (AirDrop, USB stick, …).
The other Mac does **not** need Homebrew, the Command Line Tools or the source. Everything the app
needs is inside it, **except FUSE-T**.

1. **Install FUSE-T** on that Mac, either with Homebrew (Step 3 above) or by downloading the
   installer package (`.pkg`) from the FUSE-T releases page:
   <https://github.com/macos-fuse-t/fuse-t/releases> and double-clicking it.
2. Copy `NTFS Mac.app` into **Applications**.
3. The app is not signed with an Apple Developer ID, so macOS blocks it the first time
   ("cannot be opened" or "is damaged"). To allow it:
   - Try to open it once and dismiss the warning.
   - Open **System Settings ▸ Privacy & Security**, scroll down to the message about
     *NTFS Mac*, click **Open Anyway**, and enter your password.

   Or, in Terminal:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/NTFS Mac.app"
   ```

   (Right-click ▸ Open no longer bypasses this on recent macOS versions.)

---

## 5. First launch

When NTFS Mac starts you get:

- **A window**, which looks and works like a Finder window.
- **A menu-bar icon** (a drive with a check mark) at the top-right of the screen. Closing the
  window does **not** quit the app; click the menu-bar icon ▸ *Open NTFS Mac Window* to get it
  back, or choose *Quit NTFS Mac*.

Check that everything is installed: in Terminal,

```sh
"/Applications/NTFS Mac.app/Contents/MacOS/ntfsmac" doctor
```

```
FUSE-T:    installed
ntfs-3g:   /Applications/NTFS Mac.app/Contents/Resources/ntfs-3g/bin/ntfs-3g
root:      no (mount/unmount need sudo)
auto-mount: off (sudo ntfsmac install-helper)
```

If FUSE-T shows **MISSING**, go back to [Step 3](#step-3-install-fuse-t). The app's window shows
the same message, with a button that copies the install command.

**Recommended:** turn on [automatic mounting](#7-automatic-mounting). Drives then become
writable as soon as you plug them in, and you stop getting password prompts.

> **Start at login (optional).** Add the app to **System Settings ▸ General ▸ Login Items ▸
> Open at Login** to have the menu-bar icon available all the time. With automatic mounting turned
> on, you don't need the app running for drives to mount.

---

## 6. Using an NTFS drive

### Mount a drive read-write

1. Plug in the drive. macOS mounts it **read-only** first, as usual.
2. In NTFS Mac, select the drive in the sidebar under **NTFS Drives**. A lock icon means it is
   currently read-only.
3. Click **Mount Read-Write** and enter your Mac password.
4. The drive's files appear in the window. The drive is now also writable **in Finder and in
   every other app**: save documents to it, copy files onto it, and so on.

The drive appears in Finder under its usual name (in `/Volumes/<drive name>`).

You can also mount from the menu-bar icon: *drive name ▸ Mount Read-Write…*

### The NTFS Mac window

The window works like Finder:

| Area | |
|---|---|
| **Sidebar** | Your NTFS drives. Click one to show its files; ⏏ ejects it. "Mount drives automatically" is at the bottom. |
| **Toolbar** | Back / Forward, folder name, Icons / List view, New Folder, Delete, ⋯ (drive actions), Search |
| **Path bar** (bottom) | Where you are on the drive. Click any folder in it to go there |
| **Status bar** (bottom) | Number of items and free space on the drive |

In **List view**, click a column header (Name, Date Modified, Size, Kind) to sort, and click ▸ to
expand a folder in place. Right-click files for more options.

### Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Icons / List view | ⌘1 / ⌘2 |
| Open selected item | Double-click, ⌘O or ⌘↓ |
| Back / Forward | ⌘[ / ⌘] |
| Enclosing folder | ⌘↑ |
| Rename | Return (Esc cancels) |
| Quick Look (preview) | Space or ⌘Y |
| New folder | ⇧⌘N |
| Duplicate | ⌘D |
| Copy / Paste files | ⌘C / ⌘V |
| Delete (permanent) | Delete or ⌘⌫ |
| Search in this folder | ⌘F |
| Show in Finder | ⌥⌘R |
| Eject drive | ⌘E |
| Mount / Unmount current drive | ⇧⌘M / ⇧⌘U |
| Show / hide sidebar | ⌃⌘S |

### Copying and moving files

- **Onto the drive:** drag files from Finder into the window (or onto a folder in it), or copy them
  in Finder (⌘C) and paste in NTFS Mac (⌘V). You can also just use Finder directly once the drive
  is mounted read-write.
- **Off the drive:** drag files from the window to Finder or the Desktop.
- **Within the drive:** dragging a file onto a folder **moves** it.

If a file with the same name already exists, the copy is named "name 2", "name 3", and so on.
Nothing is overwritten.

### Deleting

**NTFS drives have no Trash.** Deleting from NTFS Mac (or from Finder on an NTFS drive) removes
files **permanently**. NTFS Mac always asks first. In that dialog, Return means **Cancel**, so a
stray key press can't delete anything.

### File names

Windows doesn't allow some characters in file names (`\ / : * ? " < > |`) or names ending in a
space or dot, and reserves names like `CON`, `PRN`, `AUX`, `NUL`, `COM1`. NTFS Mac enforces the same
rules so that every file you create also opens on Windows. If saving or copying a file fails with
an error, check its name for those characters.

---

## 7. Automatic mounting

Turn this on to make NTFS drives behave like normal Mac drives:

- They mount read-write **automatically when plugged in** (and open in Finder).
- Mount / Unmount / Eject in the app **no longer ask for your password**.
- This works **even when the NTFS Mac app is not running**.

**Turn on:** tick **Mount drives automatically** at the bottom of the sidebar (or menu-bar icon
▸ *Mount Automatically When Plugged In*) and enter your password once.

**Turn off:** untick the same box.

What it installs (turning it off removes everything except the log):

| File | Purpose |
|---|---|
| `/Library/LaunchDaemons/dev.local.ntfsmac.automount.plist` | Background service that watches for NTFS drives |
| `/Library/Application Support/NTFSMac/` | A protected copy of the app that the service runs |
| `/etc/sudoers.d/ntfsmac` | Lets **only your user** mount/unmount NTFS drives without a password |
| `/var/log/ntfsmac.log` | Log of what the service did |

Notes:

- A drive you unmount by hand stays unmounted until you unplug it and plug it back in.
- Drives are mounted for whoever is logged in at the screen. Nothing happens at the login window.
- **After updating the app**, turn the option off and on again (or run `install-helper` again)
  so the background service uses the new version.

---

## 8. Unplugging safely

**Always eject before unplugging.** Click ⏏ next to the drive in the sidebar (or ⌘E, or eject it
in Finder), wait until it disappears, then unplug.

Pulling the cable out while the drive is mounted read-write can leave it marked as "dirty".
Windows will then want to check it, and NTFS Mac may refuse to mount it until it is fixed (see
[Troubleshooting](#11-troubleshooting)). In the worst case, files being written are lost.

**Unmount** (without ejecting) hands the drive back to macOS read-only and leaves it connected.

---

## 9. Using the same drive with Windows

- **Shut Windows down fully.** Windows "Fast Startup" (on by default) and Hibernate leave the
  drive in a half-open state. Writing to it then could corrupt it, so NTFS Mac refuses with a
  message about hibernation. Fix it on the Windows PC:
  - Hold **Shift** while clicking **Shut down**, or
  - Turn Fast Startup off permanently: run `powercfg /h off` in an *Administrator* Command Prompt.

  If you can't get back to that Windows PC, use **Discard Hibernation & Mount…**. This deletes
  Windows' saved session (anything left open in Windows is lost), then mounts read-write.
- **Hidden Mac files.** macOS stores extra information in hidden files named `._something` and
  `.DS_Store` on non-Mac drives. Windows shows them if hidden files are visible. They are
  harmless. To remove them before taking the drive to Windows:

  ```sh
  dot_clean "/Volumes/<drive name>"
  ```

- **BitLocker-encrypted drives** are not supported. Turn off BitLocker on Windows first.

---

## 10. Command line

The app includes a command-line tool. Use the copy inside the app:

```sh
NTFSMAC="/Applications/NTFS Mac.app/Contents/MacOS/ntfsmac"

"$NTFSMAC" doctor                          # check installation
"$NTFSMAC" list                            # list NTFS drives and their state
sudo "$NTFSMAC" mount disk4s2              # mount read-write
sudo "$NTFSMAC" mount disk4s2 --force      # …discarding Windows hibernation data
sudo "$NTFSMAC" unmount disk4s2            # back to read-only
sudo "$NTFSMAC" unmount disk4s2 --eject    # unmount and eject the whole disk
sudo "$NTFSMAC" fix disk4s2                # clear the "dirty" flag (see Troubleshooting)
sudo "$NTFSMAC" install-helper             # turn on automatic mounting
sudo "$NTFSMAC" uninstall-helper           # turn it off
```

`disk4s2` is an example. Use the identifier that `list` prints for your drive (it can change each
time you plug the drive in).

---

## 11. Troubleshooting

**The drive doesn't appear in NTFS Mac.**
- Check it is really NTFS (Finder ▸ Get Info, see [section 1](#1-background-why-ntfs-is-read-only-on-a-mac)).
- Check macOS sees it: Terminal ▸ `diskutil list external`. If it's not listed, try another cable
  or port. Large hard drives may need their own power supply or a powered hub.
- Only **external** drives are shown. Internal disks are never touched, by design.

**"FUSE-T is not installed".** Install it ([Step 3](#step-3-install-fuse-t)), then quit and reopen
the app.

**"Windows left this disk hibernated (Fast Startup)".** See [section 9](#9-using-the-same-drive-with-windows).

**"The volume was not cleanly unmounted".** The drive was unplugged without ejecting, or Windows
crashed. Best fix: plug it into Windows and run *chkdsk* (Explorer ▸ right-click the drive ▸
Properties ▸ Tools ▸ Check). If no Windows PC is available, `sudo "$NTFSMAC" fix diskXsY` clears
the flag so you can mount it, but it repairs less than chkdsk does.

**"Could not unmount … (files in use?)".** An app still has a file open on the drive. Close
documents or apps using the drive (including Terminal windows `cd`'d into it), then try again.

**"NTFS Mac is damaged and can't be opened".** That's Gatekeeper, not damage. See
[section 4](#4-install-on-another-mac-copy-the-app), step 3.

**Automatic mounting doesn't mount my drive.** Look at the log:

```sh
tail -20 /var/log/ntfsmac.log
```

It records each drive it mounted or why it couldn't. Check the drive was unmounted by hand earlier
(replug it), and that the service is installed: `"$NTFSMAC" doctor` should say *auto-mount: enabled*.

**Writing is slower than on Windows.** FUSE-T runs the driver as an app instead of in the kernel,
so large copies are slower than a native driver. Copying many small files is the slowest case.

**Another NTFS product is installed** (Paragon, Tuxera, EaseUS, iBoysoft, …). Don't run two NTFS
drivers at once; they fight over the drive. Disable or uninstall the other one.

**Still stuck?** Collect this and open an issue:

```sh
"$NTFSMAC" doctor; "$NTFSMAC" list; diskutil list external; tail -50 /var/log/ntfsmac.log
```

---

## 12. Updating

```sh
cd ~/ntfs-mac
git pull
scripts/package-app.sh
```

Quit NTFS Mac (menu-bar icon ▸ Quit), then replace the app:

```sh
rm -rf "/Applications/NTFS Mac.app" && cp -R "dist/NTFS Mac.app" /Applications/
```

If automatic mounting is on, refresh it so the background service uses the new version:

```sh
sudo "/Applications/NTFS Mac.app/Contents/MacOS/ntfsmac" install-helper
```

---

## 13. Uninstalling

1. Eject all NTFS drives.
2. Turn off automatic mounting:
   ```sh
   sudo "/Applications/NTFS Mac.app/Contents/MacOS/ntfsmac" uninstall-helper
   ```
3. Quit the app (menu-bar icon ▸ Quit) and delete it:
   ```sh
   rm -rf "/Applications/NTFS Mac.app"
   defaults delete dev.local.ntfsmac 2>/dev/null   # window/view preferences
   ```
4. Optional: remove FUSE-T (only if no other app uses it) and the source folder:
   ```sh
   brew uninstall --cask macos-fuse-t/cask/fuse-t
   rm -rf ~/ntfs-mac
   ```

Your NTFS drives go back to being read-only on this Mac. Their contents are not affected.

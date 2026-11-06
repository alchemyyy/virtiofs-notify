# virtiofs-notify

Change notifications for virtiofs shares on Proxmox VE.

virtio-fs has no way to tell a guest that a file changed on the host: the Linux driver has no notification queue, and the 2021 remote-inotify RFC was never merged (virtiofsd issue #203 is still open). Programs in a VM that watch a share with inotify, such as Jellyfin's real-time monitoring, never hear about changes made on the host or by another VM.

virtiofs-notify fills that gap. virtiofsd, QEMU and the guest kernel stay stock:

- A host service watches the filesystems behind the shares with fanotify.
- It sends each change over vsock to a small service in the VM.
- That service fires the change as a real inotify event through the `inotify_trigger` kernel module.

```
 host                                               VM
 a change made by the host, Samba,                  ┌─────────────────────────────┐
 or another VM's virtiofsd                          │ virtiofs-notify-guest       │
        │                                           │   tag "video" → /mnt/video  │
        ▼                                           │   → /proc/inotify_trigger   │
 ┌──────────────────────────────┐  vsock, port 7380 │     (inotify_trigger.ko)    │
 │ virtiofs-notify-host         │ ───────────────>  │            │                │
 │   one fanotify mark per      │  video 0x100      │            ▼                │
 │   filesystem                 │  /Movies\tX.mkv   │   inotify watchers          │
 └──────────────────────────────┘                   │   (Jellyfin, …)             │
                                                    └─────────────────────────────┘
```

## How it works

1. **Discovery.** The host service reads `/etc/pve/qemu-server/*.conf`.
   - A VM takes part if its `args` contain a `vhost-vsock-pci` device with a `guest-cid` and it has `virtiofsN:` shares.
   - Share IDs are resolved to host paths through `/etc/pve/mapping/directory.cfg`, using the entries for this node (its short hostname).
   - The configuration is re-read every 60 s. When it changes, the service re-executes itself.
2. **Watching.** Each filesystem behind a share gets one fanotify mark (`FAN_MARK_FILESYSTEM`, reporting the directory handle and the entry name).
   - That covers the whole dataset without a single per-directory watch.
   - It sees changes from every process: a shell on the host, Samba, other VMs' virtiofsd.
   - A share that is a bind mount, such as `/srv/virtiofs/music`, is mapped back to its path in the filesystem (`/primary/cauldron/Music`).
3. **Routing.** Each change goes to every VM with a share containing that directory, with the path relative to the share. A VM isn't sent changes it made itself through that share:
   - Its virtiofsd runs in the VM's cgroup (`/qemu.slice/<vmid>.scope`) with `--shared-dir=<share path>`.
   - fanotify reports which process made each change, so the service can skip that VM.
4. **Delivery.** The host keeps one vsock connection per VM, to port 7380 in the guest. It only ever sends.
5. **Replay.** The guest service maps the share tag to the share's mount point, then writes the event to `/proc/inotify_trigger`:
   - Create, delete and move are fired on the directory, with the entry name.
   - Modify, attrib and close-write are fired on the file itself, so watchers of its directory get the name. If the file is already gone, they fall back to the directory form.

### Events

| fanotify on the host | inotify in the guest |
|---|---|
| `FAN_CREATE` | `IN_CREATE` |
| `FAN_MOVED_FROM`, `FAN_MOVED_TO` | `IN_MOVED_FROM`, `IN_MOVED_TO` (cookie 0) |
| `FAN_CLOSE_WRITE` | `IN_MODIFY`, then `IN_CLOSE_WRITE` |
| `FAN_ATTRIB` | `IN_ATTRIB` |
| `FAN_DELETE` | `IN_DELETE` |
| `FAN_ONDIR` | adds `IN_ISDIR` |

### Protocol

A line-based vsock stream from the host to the guest:

```
<share tag> <inotify mask, hex> <directory relative to the share>\t<name>\n
```

For example, `video 0x40000100 /Movies\tNew Movie (2026)` is CREATE|ISDIR.

- Lines starting with `#` are messages that the guest logs, for example about dropped events.
- An empty line is a keepalive, sent after 60 s without events.
- Entry names or directories containing a tab or a newline are skipped.

## Requirements

- **Host:**
  - Proxmox VE, with the shares defined as directory mappings and attached to the VM as `virtiofsN:`.
  - fanotify with directory-handle reporting, which needs Linux 5.9 or newer.
  - A filesystem that supports file handles, such as ZFS, ext4, XFS or Btrfs.
  - Tested on PVE 9.2 (kernel 7.0.14) with ZFS 2.4.4.
- **Guest:**
  - Linux 5.14 or newer, which `inotify_trigger` needs.
  - Debian on amd64 for the package, which depends on `dkms` and `linux-headers-amd64`.
  - Each share mounted whole by its tag (`mount -t virtiofs <tag> <dir>`). Proxmox uses the mapping ID as the tag.
  - Tested on Debian 13 with kernel 6.12.
- **Both:** Python 3, standard library only. Tested with 3.13.

## Build

```sh
./build-debs.sh            # dist/virtiofs-notify-host_<version>_all.deb, dist/virtiofs-notify-guest_<version>_all.deb
./build-debs.sh /tmp/out   # other output directory
```

This needs `dpkg-deb`, so run it on a Debian-based machine.

- Package versions live in `debian/<package>/control`. Bump the version before rebuilding so `apt` treats the result as an upgrade.
- The DKMS name and version `inotify-trigger/1.0` appear in four places, so change them together:
  - `guest/inotify_trigger/dkms.conf`
  - `debian/guest/postinst`
  - `debian/guest/prerm`
  - `build-debs.sh`

## Install

On the host:

```sh
apt install ./virtiofs-notify-host_1.0_all.deb
```

This enables and starts `virtiofs-notify-host.service`. Until a VM qualifies, it logs `no VM with a vsock device and virtiofs shares`.

For each VM:

1. Give the VM a vsock device. The CID must be unique on the host and at least 3; the VM ID is a convenient choice. If the VM already has `args`, add the device to them instead of replacing them.
   ```sh
   qm set <vmid> --args "-device vhost-vsock-pci,guest-cid=<vmid>"
   ```
2. Inside the VM, install the guest package. It builds `inotify_trigger` with DKMS, which rebuilds it for new kernels, and enables `virtiofs-notify-guest.service`. The service loads the module before it starts.
   ```sh
   apt install ./virtiofs-notify-guest_1.1_all.deb
   ```
3. Fully stop and start the VM so QEMU gets the new device. A reboot from inside the guest isn't enough.
   ```sh
   qm shutdown <vmid> && qm start <vmid>
   ```
4. Within a minute, the host logs `VM <vmid> (cid <cid>): connected`.

## Check it

On the host, `journalctl -u virtiofs-notify-host` should show each share, the watched filesystems and the connections:

```
VM 103 (cid 103): share video (/primary/cauldron/Video)
VM 103 (cid 103): share music (/srv/virtiofs/music = /primary/cauldron/Music)
watching the filesystem mounted at /primary/cauldron
VM 103 (cid 103): connected
```

In the guest, `journalctl -u virtiofs-notify-guest` should show `listening on vsock port 7380` and then `host connected`.

To test end to end:

1. In the guest, watch the mount, e.g. `inotifywait -m /mnt/video` from the `inotify-tools` package.
2. On the host, run `touch /primary/cauldron/Video/test; sleep 1; rm /primary/cauldron/Video/test`. Without the pause, the file can be gone before the guest replays its events, and they arrive without the name.
3. The guest should see CREATE, MODIFY, CLOSE_WRITE, ATTRIB and DELETE events for `test`.

## Behaviour and limits

- **No rename cookie.** fanotify doesn't provide one, so a move arrives as MOVED_FROM plus MOVED_TO with cookie 0. Most watchers treat that as a delete plus a create.
- **MODIFY comes at close time.** It is derived from close-after-write, not sent once per write.
- **Duplicates are collapsed.** Identical events for the same VM within 1 s count once. This keeps a downloader that reopens the same file over and over from flooding the guests.
- **Events can be lost.** Watchers that need a complete picture should still rescan now and then, as Jellyfin's scheduled library scan does. Events are lost when:
  - The guest service isn't connected. Nothing is queued for later.
  - More than 4 MiB is waiting for one VM. The guest then logs `host: N events dropped: queue full`.
  - The kernel's fanotify queue overflows. This is logged on the host and in every guest.
  - The directory is gone by the time the host resolves it, or by the time the guest replays the event.
- **Guest restarts are noticed late.** After the guest service restarts, the host notices at its next write, which is at most 60 s away.
- **Own changes are suppressed per share.** A VM with two overlapping shares would get its own change through the other share.
- **Some shares are skipped:**
  - A share on a filesystem that isn't also mounted whole somewhere on the host. ZFS datasets always are.
  - A share under `/home`, `/root` or `/run/user`, because the unit sets `ProtectHome=yes`.
- **Nested filesystems are untested.** Filesystems mounted inside a share are watched too, but that path hasn't been tested.
- **Overhead is small.** With three VMs connected and qBittorrent downloading, the host service used 0.07 % of one CPU and 14 MB of memory.

## Security

- **virtiofsd is untouched.** It stays the distribution build, with its stock privileges.
- **Host service:**
  - It runs as root, but its capabilities are bounded to `CAP_SYS_ADMIN` (for fanotify filesystem marks) and `CAP_DAC_READ_SEARCH` (for `open_by_handle_at`).
  - It sets `NoNewPrivileges`, sees the filesystem read-only (`ProtectSystem=strict`) and can only open Unix and vsock sockets.
  - It opens directories only by handle with `O_PATH`, to resolve their paths, and never reads file contents.
  - It never reads anything a guest sends.
- **Guest service:**
  - It accepts connections only from the host (CID 2).
  - It rejects entry names containing `/` and directories with `..` components.
  - Besides its log, its only output goes to `/proc/inotify_trigger`, which is root-only (mode 0200).
  - It runs with `NoNewPrivileges`, `ProtectSystem=strict` and only Unix and vsock sockets.
- **Names leak within a VM's own shares.** A VM learns the names of entries created, changed or removed anywhere inside its own shares, including in directories it has no permission to list.

## Uninstall

1. In each VM, run `apt purge virtiofs-notify-guest`. This stops the service, unloads the module and removes it from DKMS.
2. On the host, run `apt purge virtiofs-notify-host`.
3. Remove the `vhost-vsock-pci` device from each VM's `args`, then fully stop and start the VM.

## Files

| Path | What |
|---|---|
| `host/virtiofs-notify-host` | Host service |
| `host/virtiofs-notify-host.service` | Its systemd unit |
| `guest/virtiofs-notify-guest` | Guest service |
| `guest/virtiofs-notify-guest.service` | Its systemd unit; loads the module first |
| `guest/inotify_trigger/` | Kernel module source, built by DKMS in the guest |
| `debian/host/`, `debian/guest/` | Package metadata and maintainer scripts |
| `build-debs.sh` | Builds both packages |

`guest/inotify_trigger/` is the `inotify_trigger` module from `smb_changenotify_to_inotify_translator`, unchanged. It is GPL-2.0; see its SPDX header.

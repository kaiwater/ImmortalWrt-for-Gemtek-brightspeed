# OpenWrt XR1710G build environment on a QNAP iSCSI LUN (macOS + Lima)

How the XR1710G firmware builds are run on an Apple Silicon Mac with the
`build_dir` living on a QNAP iSCSI LUN, including dm-multipath, the directory
layout, and the measured throughput. Set up 2026-11-16.

Keywords: OpenWrt, ImmortalWrt, XR1710G, Gemtek, AN7581, QNAP, iSCSI, LUN,
dm-multipath, open-iscsi, Lima, Apple Virtualization, arm64, macOS, build_dir.

## 1. Why

The XR1710G tree plus `build_dir` is ~43 GB and grows with every package.
Keeping it on the Mac internal SSD works and is fastest, but this setup moves
the whole workspace to the NAS so several projects can share one 308 GB LUN
and the internal disk stays free.

SMB was measured first and rejected: 19-31 MB/s and 42 s to create 3000 small
files. A sparse disk image on SMB improved that to ~10 s but still failed to
extract the kernel tarball reliably. iSCSI + ext4 in a Linux VM is the working
configuration.

## 2. Virtual machine

```
Lima instance   qnap-test
Backend         Apple Virtualization (vz), aarch64
Resources       8 vCPU, 8 GiB RAM, 20 GiB local disk (system only)
Access          limactl shell qnap-test
                limactl shell qnap-test sudo bash
Lifecycle       limactl start|stop qnap-test, limactl list
Networking      guest 192.168.5.15/24, host 192.168.5.2 (Lima user-mode NAT)
```

Proxy note: inside the guest the macOS host is `192.168.5.2`, not
`127.0.0.1`. The build needs no proxy when `dl/` is populated.

## 3. iSCSI target and multipath

```
Target IQN   iqn.2004-04.com.qnap:tvs-951n:iscsi.target-0.51a02b
Portal 1     192.168.2.142:3260   (QNAP eth4, 5G)
Portal 2     192.168.2.141:3260   (QNAP eth0, 5G)
Auth         CHAP, session level only; discovery needs no CHAP
LUN          /dev/sda + /dev/sdb -> /dev/mapper/mpatha (dm-0, 308 GB)
Filesystem   ext4, mounted at /mnt/qnap
```

CHAP credentials are stored in `/etc/iscsi/nodes` inside the VM and are
deliberately not committed to this repository.

Multipath state:

```
mpatha (36e843b6ac592fe5dfd8bd47b1d88e1d3) dm-0 QNAP,iSCSI Storage
size=308G features='0' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active   0:0:0:0 sda
`-+- policy='service-time 0' prio=50 status=enabled  1:0:0:0 sdb
```

Persistent configuration:

- `/etc/fstab`:
  `/dev/mapper/mpatha /mnt/qnap ext4 defaults,noatime,nodiratime,_netdev,nofail,x-systemd.requires=multipathd.service 0 0`
- `multipathd` and `open-iscsi` are enabled;
- both nodes have `node.startup = automatic`.

## 4. Directory layout on the LUN

```
/mnt/qnap/
├── README.md                            # operational notes for other sessions
├── dl/                                  # shared source cache (projects symlink here)
├── toolchains/
│   ├── go-bootstrap/                    # go1.24.13 linux-arm64
│   └── node22/                          # Node 22.11 (smartdns-ui webui)
└── projects/
    └── xr1710g/
        └── pbodq2-base/                 # full OpenWrt tree, ~43 GB
            └── dl -> /mnt/qnap/dl
```

`/opt/go-bootstrap` and `/opt/node22` are symlinks into `/mnt/qnap/toolchains`.
`CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="/opt/go-bootstrap"` in the tree's
`.config` relies on this.

## 5. Daily use

```sh
limactl shell qnap-test
/usr/local/bin/op-env.sh xr1710g/pbodq2-base
cd /build/pbodq2
PATH=/opt/node22/bin:$PATH make -j8 world
```

`op-env.sh` bind-mounts the project at the path the tree was built with:

| project | bind mount target |
|---|---|
| `xr1710g/pbodq2-base` | `/build/pbodq2` |
| `xr1710g/naoki66-base` | `/build/openwrt` |

Add `--also-workdir` to also expose the same tree at `/workdir/openwrt` for
CI YAML that hardcodes that path:

```sh
/usr/local/bin/op-env.sh xr1710g/pbodq2-base --also-workdir
```

Do not change the bind mount target: incremental build artifacts are keyed to
`/build/pbodq2`.

## 6. Measured performance

LUN on HDD RAID (WD HC530), QNAP 32 GB RAM used as block cache. fio with
`--direct=1`, 1 GiB working set.

| Metric | SMB share | single path, write-back | multipath, write-back | multipath, write-through |
|---|---|---|---|---|
| Sequential write | 19-31 MB/s | 110 MB/s | 120 MB/s | **179 MB/s** |
| Sequential read | — | 187 MB/s | 190 MB/s | **196 MB/s** |
| 4K random write (4 jobs, qd32) | — | 3.8k IOPS | 5.6k IOPS | 5.3k IOPS |
| 4K random read | — | 28.5k IOPS | 30.4k IOPS | 30.4k IOPS |
| 1000 files, 1 KB, fsync each | — | — | 2.45 s | **2.25 s** |

Notes:

- "write-through" is QNAP's *Report volatile write cache* option turned **off**.
  The LUN only holds rebuildable data, so the extra speed is worth it.
- Multipath gives +50% on 4K random writes but no bandwidth aggregation: the
  guest has a single virtual NIC, so both sessions share one physical uplink.
  Real aggregation needs a second bridged NIC and an SSD-backed LUN.
- Expect a full `make world` to be roughly 1.5-2x slower than on the internal
  SSD; sequential 179 MB/s is the ceiling for large writes.

## 7. Constraints

1. Only one host may mount the LUN read-write. Do not mount it from the Docker
   VM or a second machine; iSCSI is a block device and concurrent mounts
   corrupt ext4.
2. `dl/` is shared. Run only one project's download/build at a time; parallel
   `make download` across trees can write the same tarball concurrently.
3. The QNAP target has no ALUA path preference tuning beyond `service-time`;
   failover works, aggregation does not.
4. `naoki66-base` is not on the LUN yet. Clone it to
   `/mnt/qnap/projects/xr1710g/naoki66-base` and `op-env.sh` will mount it at
   `/build/openwrt`.

## 8. Troubleshooting

Sessions disappeared or mount is stale:

```sh
limactl shell qnap-test sudo bash -c '
  umount -l /mnt/qnap
  T=iqn.2004-04.com.qnap:tvs-951n:iscsi.target-0.51a02b
  iscsiadm -m node -T $T -p 192.168.2.142:3260 --login
  iscsiadm -m node -T $T -p 192.168.2.141:3260 --login
  multipath -ll
  mount /mnt/qnap'
```

Helper environment facts:

- `iscsiadm -m session` needs root, otherwise it prints nothing;
- `cache_type` is visible at `/sys/block/sda/device/scsi_disk/*/cache_type`
  (`write through` with the QNAP option off);
- the LUN is `303 GiB` with ~260 GiB free after the pbodq2 tree.

## 9. Backup

Container filesystem export taken before moving the workspace:

```
/Volumes/HC530-3/Mac_Openwrt_buildroot/iwrt-build-20261116.tar.zst   13 GB
```

Restore with `zstd -dc ... | docker import - iwrt-build:20261116`.

## 10. Future work: dual-NIC bridged multipath (not attempted)

The Mac already has two wired ports on the same L2 segment (`en8` at 2.5GbE
and `en21` at 5GbE) and the QNAP target is bound to two 5G ports (`eth0` and
`eth4`). The idea is to give the guest two bridged NICs, one per host port, so
each iSCSI portal leaves through a different physical link:

```
client en8  -- bridge1 -- guest nic1 -- portal 192.168.2.142 (QNAP eth4)
client en21 -- bridge2 -- guest nic2 -- portal 192.168.2.141 (QNAP eth0)
```

Verification on the guest:

```sh
ip route get 192.168.2.142   # expect src/dev of nic1
ip route get 192.168.2.141   # expect src/dev of nic2
iscsiadm -m session -P 3 | grep -E "Portal|Iface"
```

Caveats before investing time:

1. **Lima's vz backend only offers user-mode NAT.** Bridged interfaces need
   the QEMU backend plus `socket_vmnet`, or UTM with two bridged adapters.
2. **The storage is the current bottleneck.** This LUN writes at 179 MB/s;
   two links could carry ~590 MB/s, so aggregation only pays off after the LUN
   moves to SSD-backed storage.
3. If both sessions still transit one 1GbE/2.5GbE uplink (switch side), the
   combined throughput stays capped by that port regardless of the guest NICs.
4. Even when throughput does not improve, two bridged paths are useful as
   failover: one link down keeps the LUN reachable.

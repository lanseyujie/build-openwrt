# build-openwrt

使用 GitHub Actions + OpenWrt ImageBuilder 快速构建自定义固件。

## 当前默认构建参数

- OpenWrt: 未设置时自动取官方最新稳定版
- Target: `x86/64`
- Profile: `generic`
- Extra image name: `custom`
- Rootfs part size: `512 MiB`

## 可用环境变量覆盖

- `OPENWRT_VERSION`
- `TARGET`
- `SUBTARGET`
- `PROFILE`
- `EXTRA_IMAGE_NAME`
- `ROOTFS_PARTSIZE`
- `BASE_PACKAGES`
- `DEFAULT_EXTRA_PACKAGES`

# build-openwrt

使用 GitHub Actions + OpenWrt ImageBuilder 快速构建自定义固件。

## 当前默认构建参数

- OpenWrt: 未设置时自动取官方最新稳定版
- Target: `x86/64`
- Profile: `generic`
- Extra image name: `custom`
- Rootfs part size: `512 MiB`
- 默认存储/加密支持：`cryptsetup`、`kmod-dm`、`kmod-fs-btrfs`、`block-mount`

## 可用环境变量覆盖

- `OPENWRT_VERSION`
- `TARGET`
- `SUBTARGET`
- `PROFILE`
- `EXTRA_IMAGE_NAME`
- `ROOTFS_PARTSIZE`
- `BASE_PACKAGES`
- `DEFAULT_EXTRA_PACKAGES`
- `APK_FEEDS`

## 添加 APK 软件源

`APK_FEEDS` 是多行配置；每行格式为
`源名称|公钥 URL|公钥文件名|软件源 URL[,软件源 URL...]`。软件源 URL 中可使用
`@release@` 和 `@arch@` 占位符，构建时会替换为 OpenWrt 主版本和目标包架构。

构建脚本会对每条配置依次执行两步：`add_apk_key` 添加密钥，再由
`add_apk_repositories` 添加软件源；两者都会同时配置 ImageBuilder 和最终固件。

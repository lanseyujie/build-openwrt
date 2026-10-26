#!/bin/sh
set -eu

OPENWRT_VERSION="${OPENWRT_VERSION:-}"
TARGET="${TARGET:-x86}"
SUBTARGET="${SUBTARGET:-64}"
PROFILE="${PROFILE:-generic}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-custom}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-512}"
# One entry per line: name|public-key URL|public-key filename|repository URL[,repository URL...]
# Repository URLs may use @release@ (OpenWrt major version) and @arch@ (package architecture).
APK_FEEDS="${APK_FEEDS:-
passwall|https://sourceforge.net/projects/openwrt-passwall-build/files/apk.pub|passwall.pub|https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-@release@/@arch@/passwall_packages/packages.adb,https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-@release@/@arch@/passwall_luci/packages.adb,https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-@release@/@arch@/passwall2/packages.adb
}"

SOURCE_FILES_DIR="${SOURCE_FILES_DIR:-$PWD/files}"
FILES_DIR="${FILES_DIR:-$PWD/.build-files}"
BIN_DIR="${BIN_DIR:-$PWD/out}"

BASE_PACKAGES="${BASE_PACKAGES:-"
dnsmasq-full
-dnsmasq
luci
luci-ssl
grub2
grub2-efi
owut
ucode-mod-uclient
openssh-sftp-server
ip-full
-ip-tiny
parted
losetup
resize2fs
usbip-server
usbip-client
kmod-usb-net-asix-ax88179
kmod-nft-socket
kmod-nft-tproxy
kmod-nft-nat
"}"
DEFAULT_EXTRA_PACKAGES="${DEFAULT_EXTRA_PACKAGES:-"
block-mount
cryptsetup
kmod-dm
kmod-fs-btrfs
luci-app-passwall2
podman
syncthing
luci-app-wol
luci-i18n-wol-zh-cn
luci-app-uhttpd
luci-i18n-uhttpd-zh-cn
luci-app-acme
luci-i18n-acme-zh-cn
acme-acmesh-dnsapi
luci-app-attendedsysupgrade
luci-i18n-attendedsysupgrade-zh-cn
luci-app-samba4
luci-i18n-samba4-zh-cn
wsdd2
luci-proto-wireguard
luci-i18n-base-zh-cn
luci-i18n-package-manager-zh-cn
luci-i18n-firewall-zh-cn
luci-app-ddns
luci-i18n-ddns-zh-cn
ddns-scripts-cloudflare
luci-app-cloudflared
luci-i18n-cloudflared-zh-cn
"}"

ALL_PACKAGES="$(printf '%s %s' "$BASE_PACKAGES" "$DEFAULT_EXTRA_PACKAGES" | xargs)"

detect_openwrt_version() {
	if [ -n "$OPENWRT_VERSION" ]; then
		return
	fi

	if ! type curl >/dev/null 2>&1; then
		echo "curl is required to detect the latest stable OpenWrt version" >&2
		exit 1
	fi

	if ! type jq >/dev/null 2>&1; then
		echo "jq is required to detect the latest stable OpenWrt version" >&2
		exit 1
	fi

	OPENWRT_VERSION="$(curl -fsSL https://downloads.openwrt.org/.versions.json | jq -r '.stable_version')"

	if [ -z "$OPENWRT_VERSION" ] || [ "$OPENWRT_VERSION" = "null" ]; then
		echo "Failed to detect the latest stable OpenWrt version" >&2
		exit 1
	fi
}

download() {
	URL="$1"
	OUT="$2"

	if type curl >/dev/null 2>&1; then
		curl -fL "$URL" -o "$OUT"
		return
	fi

	if type wget >/dev/null 2>&1; then
		wget -O "$OUT" "$URL"
		return
	fi

	echo "Neither curl nor wget is available for downloading: $URL" >&2
	exit 1
}

ensure_imagebuilder() {
	HOST_ARCHIVE_SUFFIX="Linux-x86_64"
	IB_NAME="openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET}-${SUBTARGET}.${HOST_ARCHIVE_SUFFIX}"
	IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.zst"
	IB_DIR="$PWD/${IB_NAME}"

	if [ -d "$IB_DIR" ]; then
		return
	fi

	ARCHIVE_PATH="$PWD/${IB_NAME}.tar.zst"
	SHA_URL="${IB_URL%/*}/sha256sums"

	echo "ImageBuilder not found, downloading official archive..."
	download "$IB_URL" "$ARCHIVE_PATH"

	if type sha256sum >/dev/null 2>&1; then
		SHA_FILE="$PWD/sha256sums-${OPENWRT_VERSION}-${TARGET}-${SUBTARGET}"
		download "$SHA_URL" "$SHA_FILE"
		EXPECTED_LINE="$(awk -v filename="$IB_NAME.tar.zst" '$2 == filename || $2 == "*" filename { print; exit }' "$SHA_FILE" || true)"
		if [ -n "$EXPECTED_LINE" ]; then
			(
				cd "$PWD"
				printf '%s\n' "$EXPECTED_LINE" | sha256sum -c -
			)
		else
			echo "Warning: checksum entry for ${IB_NAME}.tar.zst not found in $SHA_URL" >&2
		fi
	fi

	if type tar >/dev/null 2>&1; then
		tar --zstd -xf "$ARCHIVE_PATH"
	else
		echo "tar is required to extract $ARCHIVE_PATH" >&2
		exit 1
	fi
}

prepare_files_dir() {
	rm -rf "$FILES_DIR"
	mkdir -p "$FILES_DIR"
	rsync -a "$SOURCE_FILES_DIR"/ "$FILES_DIR"/
}

add_apk_key() {
	APK_KEY_URL="$1"
	APK_KEY_NAME="$2"
	APK_KEY_FILE="$FILES_DIR/etc/apk/keys/$APK_KEY_NAME"

	mkdir -p "$IB_DIR/keys" "$(dirname "$APK_KEY_FILE")"
	download "$APK_KEY_URL" "$IB_DIR/keys/$APK_KEY_NAME"
	cp "$IB_DIR/keys/$APK_KEY_NAME" "$APK_KEY_FILE"
}

add_apk_repositories() {
	APK_REPOSITORY_NAME="$1"
	shift
	APK_REPOSITORIES_FILE="$FILES_DIR/etc/apk/repositories.d/$APK_REPOSITORY_NAME.list"

	mkdir -p "$(dirname "$APK_REPOSITORIES_FILE")"
	printf '%s\n' "$@" > "$APK_REPOSITORIES_FILE"

	for APK_REPOSITORY_URL in "$@"; do
		grep -Fqx "$APK_REPOSITORY_URL" "$IB_DIR/repositories" ||
			printf '%s\n' "$APK_REPOSITORY_URL" >> "$IB_DIR/repositories"
	done
}

prepare_apk_feeds() {
	if [ ! -f "$IB_DIR/repositories" ]; then
		echo "Configured APK feeds require an APK-based OpenWrt ImageBuilder; OpenWrt ${OPENWRT_VERSION} does not provide one." >&2
		exit 1
	fi

	APK_FEED_ARCH="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "$IB_DIR/.config")"
	if [ -z "$APK_FEED_ARCH" ]; then
		echo "Could not determine the ImageBuilder package architecture for APK feeds." >&2
		exit 1
	fi

	APK_FEED_RELEASE="${OPENWRT_VERSION%.*}"
	printf '%s\n' "$APK_FEEDS" | while IFS='|' read -r APK_FEED_NAME APK_FEED_KEY_URL APK_FEED_KEY_NAME APK_FEED_URLS; do
		[ -z "$APK_FEED_NAME" ] && continue
		if [ -z "$APK_FEED_KEY_URL" ] || [ -z "$APK_FEED_KEY_NAME" ] || [ -z "$APK_FEED_URLS" ]; then
			echo "Invalid APK_FEEDS entry for $APK_FEED_NAME." >&2
			exit 1
		fi

		APK_FEED_URLS="$(printf '%s' "$APK_FEED_URLS" | sed \
			-e "s|@release@|$APK_FEED_RELEASE|g" \
			-e "s|@arch@|$APK_FEED_ARCH|g")"
		APK_FEED_OLD_IFS="$IFS"
		IFS=,
		set -f
		set -- $APK_FEED_URLS
		set +f
		IFS="$APK_FEED_OLD_IFS"

		add_apk_key "$APK_FEED_KEY_URL" "$APK_FEED_KEY_NAME"
		add_apk_repositories "$APK_FEED_NAME" "$@"
	done
}

detect_openwrt_version
ensure_imagebuilder
prepare_files_dir
prepare_apk_feeds

echo "Using ImageBuilder: $IB_DIR"
echo "Using source files: $SOURCE_FILES_DIR"
echo "Using build files : $FILES_DIR"
echo "Output directory  : $BIN_DIR"
echo "Rootfs part size  : $ROOTFS_PARTSIZE MiB"
echo "Packages          : $ALL_PACKAGES"

make -C "$IB_DIR" image \
	"PROFILE=$PROFILE" \
	"PACKAGES=$ALL_PACKAGES" \
	"FILES=$FILES_DIR" \
	"BIN_DIR=$BIN_DIR" \
	"EXTRA_IMAGE_NAME=$EXTRA_IMAGE_NAME" \
	"ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"

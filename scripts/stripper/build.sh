#!/bin/sh
set -eu

STRIPPER_COMMIT="2a08843241f1858d0727a91fa9dcb2382526f8cb"
METAMOD_COMMIT="2667e8e5947237c4cb7ea45cec3913ad6a44757c"
LINUX_PACKAGE_SHA256="3c3914c2ac8e5c1cab8b1367854c77cb07af9df45c42ecc070d53c2bc72cc630"
WINDOWS_PACKAGE_SHA256="bafe1c6727c1a59c83770a71c6438ea222763ff1a4aa689ca7f96a9f4149d755"
BUILD_IMAGE="debian:bookworm-slim"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work_dir=$(mktemp -d /tmp/competitive-with-anne-stripper.XXXXXX)

"$script_dir/test_repository_policy.sh"

cleanup()
{
	case "$work_dir" in
		/tmp/competitive-with-anne-stripper.*) rm -rf -- "$work_dir" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

for command in curl docker git tar unzip; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "Missing required command: $command" >&2
		exit 1
	}
done

sha256_file()
{
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

fetch_commit()
{
	repository=$1
	commit=$2
	destination=$3
	git init -q "$destination"
	git -C "$destination" remote add origin "$repository"
	git -C "$destination" fetch -q --depth 1 origin "$commit"
	git -C "$destination" checkout -q --detach FETCH_HEAD
}

stripper_source="$work_dir/stripper-source"
metamod_source="$work_dir/metamod-source"
fetch_commit "https://github.com/alliedmodders/stripper-source.git" "$STRIPPER_COMMIT" "$stripper_source"
fetch_commit "https://github.com/alliedmodders/metamod-source.git" "$METAMOD_COMMIT" "$metamod_source"
git -C "$stripper_source" apply "$script_dir/conditional-map-filters.patch"

host_uid=$(id -u)
host_gid=$(id -g)
docker run --rm --platform linux/amd64 \
	-v "$stripper_source:/src" \
	-v "$metamod_source:/mms" \
	-v "$script_dir:/project:ro" \
	-w /src \
	-e HOST_UID="$host_uid" \
	-e HOST_GID="$host_gid" \
	"$BUILD_IMAGE" sh -lc '
		set -eu
		apt-get update >/dev/null
		DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
			g++-multilib g++-mingw-w64-i686 make >/dev/null

		mkdir -p build/linux build/windows
		common_linux="-m32 -std=c++14 -O2 -DNDEBUG -D_LINUX -Dstricmp=strcasecmp \
			-D_stricmp=strcasecmp -D_snprintf=snprintf -D_vsnprintf=vsnprintf \
			-DHAVE_STDINT_H -DGNUC -fPIC -fno-exceptions -fno-rtti \
			-fno-threadsafe-statics -fno-strict-aliasing -Wno-delete-non-virtual-dtor \
			-I. -Ipcre -I/mms/core/sourcehook"
		g++ $common_linux -c parser.cpp -o build/linux/parser.o
		g++ $common_linux -c support.cpp -o build/linux/support.o
		g++ -m32 -shared -static-libgcc build/linux/parser.o build/linux/support.o \
			pcre/libpcre-linux.a -ldl -lm -Wl,--build-id=sha1 \
			-Wl,--version-script=/project/exports.map -o build/linux/stripper.core.so
		nm -D --defined-only build/linux/stripper.core.so | grep -q " LoadStripper$"

		cp -a pcre build/windows/pcre
		cd build/windows/pcre
		./configure --build=x86_64-pc-linux-gnu --host=i686-w64-mingw32 \
			--disable-shared --enable-static --disable-cpp >/dev/null
		# A fresh Git checkout gives the old Automake inputs newer timestamps than
		# its checked-in generated files. Keep make from trying to regenerate them.
		touch aclocal.m4 configure Makefile.in config.h.in
		make -j2 libpcre.la >/dev/null
		cd /src
		common_windows="-std=c++14 -O2 -DNDEBUG -DWIN32 -D_WIN32 \
			-D_CRT_SECURE_NO_DEPRECATE -fno-exceptions -fno-rtti \
			-fno-threadsafe-statics -fno-strict-aliasing \
			-I. -Ipcre -I/mms/core/sourcehook"
		i686-w64-mingw32-g++ $common_windows -c parser.cpp -o build/windows/parser.o
		i686-w64-mingw32-g++ $common_windows -c support.cpp -o build/windows/support.o
		i686-w64-mingw32-g++ -shared -static-libgcc -static-libstdc++ \
			build/windows/parser.o build/windows/support.o \
			build/windows/pcre/.libs/libpcre.a \
			-Wl,--kill-at,--no-insert-timestamp,--subsystem,windows \
			-o build/windows/stripper.core.dll
		i686-w64-mingw32-objdump -p build/windows/stripper.core.dll | grep -q "LoadStripper"

		g++ -m32 -std=c++14 -O2 -I/src /project/test_conditional_filters.cpp \
			-ldl -o build/linux/test_conditional_filters
		build/linux/test_conditional_filters build/linux/stripper.core.so
		chown -R "$HOST_UID:$HOST_GID" build
	'

linux_package="$work_dir/stripper-linux.tar.gz"
windows_package="$work_dir/stripper-windows.zip"
curl -fsSL "https://www.bailopan.net/stripper/snapshots/1.2/stripper-1.2.2-git141-linux.tar.gz" \
	-o "$linux_package"
curl -fsSL "https://www.bailopan.net/stripper/snapshots/1.2/stripper-1.2.2-git141-windows.zip" \
	-o "$windows_package"
[ "$(sha256_file "$linux_package")" = "$LINUX_PACKAGE_SHA256" ] || {
	echo "Linux Stripper package checksum mismatch" >&2
	exit 1
}
[ "$(sha256_file "$windows_package")" = "$WINDOWS_PACKAGE_SHA256" ] || {
	echo "Windows Stripper package checksum mismatch" >&2
	exit 1
}

mkdir -p "$work_dir/package-linux" "$work_dir/package-windows"
tar -xzf "$linux_package" -C "$work_dir/package-linux"
unzip -q "$windows_package" -d "$work_dir/package-windows"

bin_dir="$repo_root/addons/stripper/bin"
cp "$work_dir/package-linux/addons/stripper/bin/stripper.16.l4d2.so" "$bin_dir/"
cp "$work_dir/package-linux/addons/stripper/bin/stripper_mm_i486.so" "$bin_dir/"
cp "$stripper_source/build/linux/stripper.core.so" "$bin_dir/"
cp "$work_dir/package-windows/addons/stripper/bin/stripper.16.l4d2.dll" "$bin_dir/"
cp "$work_dir/package-windows/addons/stripper/bin/stripper_mm.dll" "$bin_dir/"
cp "$stripper_source/build/windows/stripper.core.dll" "$bin_dir/"

echo "Installed conditional Stripper binaries in $bin_dir"

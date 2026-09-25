#!/bin/zsh
set -euo pipefail

# Builds a relocatable OwnTone runtime for arm64 from pinned upstream sources.
#
# OwnTone is GPL-2.0-or-later. This project does not vendor its source, and does
# not ship source inside the product: the sources are fetched here at build time
# against recorded checksums, and the corresponding-source archive this script
# can emit is a build artifact under dist/, which is gitignored. See the README
# section "配布する OwnTone をビルドする" for how that satisfies GPL §3 without
# putting a byte of third-party source in the repository or the installer.
#
# Every dependency is built as a shared library. That is deliberate: several of
# them are LGPL, and dynamic linking is what lets a user replace one with their
# own build, which is the obligation LGPL §6 imposes. Static linking would drag
# in an object-file distribution requirement instead.
#
# Nothing here is installed onto this Mac, and nothing is signed. The output is
# a self-contained prefix whose load commands are all @rpath-relative.

script_dir="${0:A:h}"
project_root="${script_dir:h}"
build_root="${project_root}/.build/owntone-runtime"
output_dir="${project_root}/dist/owntone-runtime"
lock_file="${script_dir}/owntone-sources.lock"
patch_dir="${project_root}/patches/OwnTone-29.3"

release_architecture="arm64"
deployment_target="14.0"

update_lock=0
keep_build=0
fresh=0
emit_source_archive=0
only_component=""

# Pinned upstream versions. Checksums live in Scripts/owntone-sources.lock so a
# version bump is one edit here plus `--update-lock`, and a silently changed
# upstream tarball fails the build instead of shipping.
typeset -A component_version component_url component_archive
typeset -a component_order

define_component() {
  local name="$1" version="$2" url="$3"
  component_order+=("${name}")
  component_version[${name}]="${version}"
  component_url[${name}]="${url}"
  component_archive[${name}]="${url:t}"
}

#                  name               version         url
define_component gmp               6.3.0           "https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz"
define_component libgpg-error      1.61            "https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.61.tar.bz2"
define_component libgcrypt         1.12.3          "https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.12.3.tar.bz2"
define_component libunistring      1.4.2           "https://ftp.gnu.org/gnu/libunistring/libunistring-1.4.2.tar.xz"
define_component libtasn1          4.21.0          "https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.21.0.tar.gz"
define_component nettle            3.10.2          "https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz"
define_component gnutls            3.8.13          "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz"
define_component libevent          2.1.13-stable   "https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/libevent-2.1.13-stable.tar.gz"
define_component sqlite            3530400         "https://sqlite.org/2026/sqlite-autoconf-3530400.tar.gz"
define_component libconfuse        3.4             "https://github.com/libconfuse/libconfuse/releases/download/v3.4/confuse-3.4.tar.xz"
define_component libsodium         1.0.22          "https://github.com/jedisct1/libsodium/releases/download/1.0.22-RELEASE/libsodium-1.0.22.tar.gz"
define_component json-c            0.19            "https://github.com/json-c/json-c/releases/download/json-c-0.19-20260627/json-c-0.19.tar.gz"
define_component libplist          2.7.0           "https://github.com/libimobiledevice/libplist/releases/download/2.7.0/libplist-2.7.0.tar.bz2"
define_component protobuf-c        1.5.2           "https://github.com/protobuf-c/protobuf-c/releases/download/v1.5.2/protobuf-c-1.5.2.tar.gz"
define_component libinotify        20240724        "https://github.com/libinotify-kqueue/libinotify-kqueue/releases/download/20240724/libinotify-20240724.tar.gz"
define_component libopus           1.5.2           "https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2.tar.gz"
define_component ffmpeg            7.1.5           "https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz"
define_component owntone           29.3            "https://github.com/owntone/owntone-server/releases/download/29.3/owntone-29.3.tar.xz"

usage() {
  print -r -- "Usage: ./Scripts/build-owntone-runtime.sh [options]"
  print -r -- ""
  print -r -- "Builds a relocatable OwnTone runtime for ${release_architecture} from pinned sources."
  print -r -- "Dependencies are built as shared libraries and the result is @rpath-relative."
  print -r -- ""
  print -r -- "Options:"
  print -r -- "  --output <absolute path>  Output prefix (default: ${output_dir})"
  print -r -- "  --update-lock             Fetch every source and rewrite the checksum lock"
  print -r -- "  --emit-source-archive     Also write the corresponding-source archive to dist/"
  print -r -- "  --only <component>        Build a single component, then stop"
  print -r -- "  --fresh                   Ignore build stamps and rebuild everything"
  print -r -- "  --keep-build              Keep the intermediate build tree"
  print -r -- "  --help                    Show this help"
  print -r -- ""
  print -r -- "Components, in build order:"
  print -r -- "  ${component_order}"
}

fail() {
  print -r -u2 -- "$1"
  exit "${2:-1}"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      [[ "$#" -ge 2 ]] || fail "--output requires an absolute path." 64
      output_dir="$2"; shift 2 ;;
    --only)
      [[ "$#" -ge 2 ]] || fail "--only requires a component name." 64
      only_component="$2"; shift 2 ;;
    --update-lock) update_lock=1; shift ;;
    --emit-source-archive) emit_source_archive=1; shift ;;
    --fresh) fresh=1; shift ;;
    --keep-build) keep_build=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ "${output_dir}" == /* ]] || fail "--output must be an absolute path." 64
if [[ -n "${only_component}" && ${component_order[(Ie)${only_component}]} -eq 0 ]]; then
  fail "Unknown component: ${only_component}. Known: ${component_order}" 64
fi

host_architecture="$(/usr/bin/uname -m)"
if [[ "${host_architecture}" != "${release_architecture}" ]]; then
  fail "This script builds ${release_architecture} on an ${release_architecture} Mac; this one is ${host_architecture}." 78
fi

for tool in curl shasum git make clang tar patch pkg-config cmake autoreconf automake glibtoolize m4 gperf; do
  command -v "${tool}" >/dev/null 2>&1 \
    || fail "Missing required build tool: ${tool}. Install it (for example: brew install autoconf automake libtool pkg-config cmake gperf)." 69
done

prefix="${build_root}/prefix"
# Where the installer puts this runtime. OwnTone compiles its web-root default
# from pkgdatadir, and building against the build tree shipped a path that
# existed only on the build machine: every other Mac got "Could not stat() web
# root directory" and no OwnTone at all. The path also carried the builder's
# home directory into a binary sent to customers.
#
# It cannot simply be passed as --prefix. It contains a space, and automake's
# install rules word-split on it. So the prefix stays inside the build tree and
# only the compile-time definition is overridden, through the array below.
runtime_install_prefix="/Library/Application Support/SoundFerry/OwnToneRuntime"
typeset -ga configure_make_overrides=()
sources="${build_root}/sources"
archives="${build_root}/archives"
stamps="${build_root}/stamps"

(( fresh )) && /bin/rm -rf -- "${build_root}"
/bin/mkdir -p "${prefix}/lib/pkgconfig" "${sources}" "${archives}" "${stamps}"

export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
export PATH="${prefix}/bin:${PATH}"
common_cflags="-arch ${release_architecture} -mmacosx-version-min=${deployment_target} -O2"
common_ldflags="-arch ${release_architecture} -mmacosx-version-min=${deployment_target} -L${prefix}/lib -Wl,-headerpad_max_install_names"
common_cppflags="-I${prefix}/include"

# --------------------------------------------------------------------------
# System libraries
#
# zlib, libcurl and libxml2 ship with macOS, so the GPL's system-library
# exception covers them: they are neither embedded nor a source obligation.
# OwnTone finds them through pkg-config, and the only .pc files for them on a
# Mac belong to Homebrew's shim directory. Writing our own into the private
# prefix removes that hidden dependency on how the build host is set up.
# --------------------------------------------------------------------------
write_system_pkgconfig() {
  local name="$1" version="$2" libs="$3"
  /bin/cat > "${prefix}/lib/pkgconfig/${name}.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib

Name: ${name}
Description: macOS system ${name}
Version: ${version}
Libs: ${libs}
Cflags:
EOF
}

write_system_pkgconfig zlib 1.2.12 "-lz"
write_system_pkgconfig libcurl 8.7.1 "-lcurl"
write_system_pkgconfig libxml-2.0 2.9.13 "-lxml2"

# --------------------------------------------------------------------------
# Fetching
# --------------------------------------------------------------------------
lock_sha256_for() {
  local name="$1"
  [[ -f "${lock_file}" ]] || return 1
  /usr/bin/awk -v want="${name}" '$1 == want { print $3; found = 1 } END { exit !found }' "${lock_file}"
}

fetch_component() {
  local name="$1"
  local url="${component_url[${name}]}"
  local archive="${archives}/${component_archive[${name}]}"
  local expected actual

  if [[ ! -f "${archive}" ]]; then
    print -r -- "    fetching ${url}"
    /usr/bin/curl --fail --location --silent --show-error --retry 2 --output "${archive}.partial" "${url}"
    /bin/mv -f "${archive}.partial" "${archive}"
  fi
  actual="$(/usr/bin/shasum -a 256 "${archive}" | /usr/bin/awk '{ print $1 }')"

  if (( update_lock )); then
    printf '%s\t%s\t%s\t%s\n' "${name}" "${component_version[${name}]}" "${actual}" "${url}" >> "${lock_file}.new"
    return 0
  fi

  if ! expected="$(lock_sha256_for "${name}")"; then
    fail "No checksum recorded for ${name}. Run: ./Scripts/build-owntone-runtime.sh --update-lock" 65
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    fail "Checksum mismatch for ${name}. Expected ${expected}, got ${actual}. Refusing to build a source nobody vouched for." 65
  fi
}

extract_component() {
  local name="$1"
  local archive="${archives}/${component_archive[${name}]}"
  local marker="${sources}/.extracted-${name}"

  [[ -f "${marker}" ]] && return 0
  # bsdtar detects gz/bz2/xz on extract, so one form covers every archive here.
  /usr/bin/tar -xf "${archive}" -C "${sources}"
  : > "${marker}"
}

# The extracted directory name does not always follow the archive name.
source_dir_for() {
  local name="$1"
  local candidate
  case "${name}" in
    sqlite)    candidate="${sources}/sqlite-autoconf-${component_version[${name}]}" ;;
    libconfuse) candidate="${sources}/confuse-${component_version[${name}]}" ;;
    libopus)   candidate="${sources}/opus-${component_version[${name}]}" ;;
    libinotify) candidate="${sources}/libinotify-${component_version[${name}]}" ;;
    libevent)  candidate="${sources}/libevent-${component_version[${name}]}" ;;
    *)         candidate="${sources}/${name}-${component_version[${name}]}" ;;
  esac
  [[ -d "${candidate}" ]] || fail "Extracted source directory not found for ${name}: ${candidate}" 65
  print -r -- "${candidate}"
}

# --------------------------------------------------------------------------
# Build recipes
#
# Every one of these disables static archives, documentation and test suites.
# The first shrinks the closure to exactly the dylibs that ship; the other two
# only cost build time.
# --------------------------------------------------------------------------
configure_and_make() {
  local dir="$1"; shift
  # source_dir_for runs inside a command substitution, so the fail() in it ends
  # that subshell and nothing else. Without this check an unresolved source
  # directory reached patch and configure as the empty string, which meant
  # patching whatever directory the build happened to be standing in.
  [[ -n "${dir}" && -d "${dir}" ]] \
    || fail "No source directory to build. This usually means an extracted tree is missing." 65
  (
    cd "${dir}"
    # CXXFLAGS matters even though nothing here is a C++ project: libplist
    # builds a C++ API layer, and without it those objects are compiled against
    # the SDK's own deployment target rather than ours.
    # GNU libtool probes kern.argmax on macOS. Sandboxed build hosts can deny
    # that sysctl, leaving max_cmd_len empty; libtool then emits a partial-link
    # chain that drops hidden internal symbols. 196608 is the conservative
    # three-quarter ARG_MAX value used by libtool on macOS.
    lt_cv_sys_max_cmd_len=196608 ./configure --prefix="${prefix}" "$@" \
      CC="/usr/bin/clang" \
      CXX="/usr/bin/clang++" \
      CPPFLAGS="${common_cppflags}" \
      CFLAGS="${common_cflags}" \
      CXXFLAGS="${common_cflags}" \
      LDFLAGS="${common_ldflags}" \
      >/dev/null
    # Overrides apply to the compile only. `make install` runs without them, so
    # the tree still lands under the build prefix that the relocation walk
    # below expects, while the binary carries the paths it will really have.
    /usr/bin/make -j"$(/usr/sbin/sysctl -n hw.ncpu)" "${configure_make_overrides[@]}" >/dev/null
    /usr/bin/make install >/dev/null
  )
}

build_gmp() {
  configure_and_make "$(source_dir_for gmp)" --enable-shared --disable-static --with-pic
}

build_libgpg-error() {
  configure_and_make "$(source_dir_for libgpg-error)" \
    --enable-shared --disable-static --disable-doc --disable-tests --enable-install-gpg-error-config
}

build_libgcrypt() {
  # --disable-asm: libgcrypt's aarch64 MPI assembly emits CFI directives that
  # clang's integrated assembler rejects with "Unfinished frame!". The C
  # fallbacks are correct, and this build uses libgcrypt only for AirPlay
  # authentication, where the speed difference is not measurable.
  configure_and_make "$(source_dir_for libgcrypt)" \
    --enable-shared --disable-static --disable-doc --disable-asm \
    --with-libgpg-error-prefix="${prefix}"
}

build_libunistring() {
  configure_and_make "$(source_dir_for libunistring)" --enable-shared --disable-static
}

build_libtasn1() {
  configure_and_make "$(source_dir_for libtasn1)" --enable-shared --disable-static --disable-doc
}

build_nettle() {
  configure_and_make "$(source_dir_for nettle)" \
    --enable-shared --disable-static --disable-documentation --disable-openssl \
    --with-lib-path="${prefix}/lib" --with-include-path="${prefix}/include"
}

build_gnutls() {
  # p11-kit, IDN and the tools each add a dependency subtree that nothing in
  # this product reaches. Chromecast needs the TLS client and nothing else.
  #
  # The three compression options default to autodetection, which found
  # Homebrew's brotli and zstd and linked them into every binary downstream of
  # gnutls. They exist for TLS certificate compression, which a Cast control
  # channel never negotiates.
  configure_and_make "$(source_dir_for gnutls)" \
    --enable-shared --disable-static \
    --disable-doc --disable-tools --disable-cxx --disable-tests --disable-guile \
    --without-p11-kit --without-idn --without-tpm --without-tpm2 \
    --without-brotli --without-zstd \
    --disable-libdane --disable-nls
}

build_libevent() {
  configure_and_make "$(source_dir_for libevent)" \
    --enable-shared --disable-static --disable-openssl --disable-samples --disable-libevent-regress
}

build_sqlite() {
  # OwnTone requires unlock-notify, which Apple's system sqlite3 does not
  # export; that is the whole reason this component is here rather than taken
  # from /usr/lib. Column metadata is what its smart-playlist queries need.
  (
    cd "$(source_dir_for sqlite)"
    ./configure --prefix="${prefix}" --enable-shared --disable-static --disable-readline \
      CC="/usr/bin/clang" \
      CPPFLAGS="${common_cppflags} -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_COLUMN_METADATA=1" \
      CFLAGS="${common_cflags}" \
      LDFLAGS="${common_ldflags}" \
      >/dev/null
    /usr/bin/make -j"$(/usr/sbin/sysctl -n hw.ncpu)" >/dev/null
    /usr/bin/make install >/dev/null
  )
}

build_libconfuse() {
  configure_and_make "$(source_dir_for libconfuse)" --enable-shared --disable-static --disable-examples
}

build_libsodium() {
  configure_and_make "$(source_dir_for libsodium)" --enable-shared --disable-static
}

build_json-c() {
  local dir="$(source_dir_for json-c)"
  (
    cd "${dir}"
    /bin/rm -rf build && /bin/mkdir build && cd build
    cmake .. \
      -DCMAKE_INSTALL_PREFIX="${prefix}" \
      -DCMAKE_OSX_ARCHITECTURES="${release_architecture}" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="${deployment_target}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_STATIC_LIBS=OFF \
      -DBUILD_TESTING=OFF \
      -DDISABLE_WERROR=ON \
      >/dev/null
    cmake --build . --parallel "$(/usr/sbin/sysctl -n hw.ncpu)" >/dev/null
    cmake --install . >/dev/null
  )
}

build_libplist() {
  configure_and_make "$(source_dir_for libplist)" --enable-shared --disable-static --without-cython
}

build_protobuf-c() {
  # Only the runtime library is wanted. Building protoc-c would pull in the C++
  # protobuf compiler, and OwnTone ships its generated Cast sources already.
  configure_and_make "$(source_dir_for protobuf-c)" --enable-shared --disable-static --disable-protoc
}

build_libinotify() {
  # fdclosedir() exists in the current SDK but is marked as introduced in a
  # macOS far newer than this project targets, and libinotify calls it
  # unconditionally, so the availability warning becomes an error. Telling
  # configure the function is absent is not a workaround: it selects the
  # READDIR_DOES_OPENDIR path the project already maintains for exactly this
  # case, which uses closedir(). Silencing the warning instead would emit a
  # call that does not exist on macOS 14.
  configure_and_make "$(source_dir_for libinotify)" \
    --enable-shared --disable-static ac_cv_func_fdclosedir=no
}

build_libopus() {
  # OwnTone hands the Opus encoder S16 samples and says so in a comment:
  # "Only libopus support". ffmpeg's native Opus encoder accepts only fltp, so
  # without this component avcodec_open2() fails and Chromecast output does not
  # work at all. BSD-3-Clause, so it adds attribution and nothing else.
  configure_and_make "$(source_dir_for libopus)" \
    --enable-shared --disable-static --disable-doc --disable-extra-programs
}

build_ffmpeg() {
  # Deliberately neither --enable-gpl nor --enable-nonfree: staying on plain
  # LGPL keeps ffmpeg's own obligations to the same shape as the other LGPL
  # dependencies here.
  #
  # --disable-everything strips ffmpeg to the handful of pieces this route
  # touches: ALAC and Opus encoders for the two outputs, PCM for the app's
  # pipe, the "data" muxer both output profiles ask for, and the audio filter
  # graph. Everything removed - every video and image codec, every container
  # demuxer, every network protocol - is where nearly all of ffmpeg's CVEs
  # live, and none of it is reachable from a PCM pipe feeding AirPlay and
  # Chromecast. Fewer components is less to track for the life of the product.
  #
  # This is only safe because the capability assertions below check what the
  # built libraries can actually do. Note the trade: DAAP/iTunes streaming,
  # which transcodes to MP4/ALAC and MP3, no longer works. This app does not
  # use it and the web interface is off.
  #
  # --disable-autodetect is the other load-bearing flag. Without it ffmpeg links
  # whatever it finds on the build machine, which on a Mac with Homebrew meant
  # X11, xcb, brotli and zstd were pulled into the shipped closure: unpinned,
  # unverified, absent from the source manifest, and different on every build
  # host. Everything OwnTone decodes has a native ffmpeg decoder, so nothing is
  # lost by requiring external libraries to be asked for by name.
  (
    cd "$(source_dir_for ffmpeg)"
    ./configure \
      --prefix="${prefix}" \
      --arch="${release_architecture}" \
      --enable-shared --disable-static \
      --disable-autodetect \
      --disable-programs --disable-doc --disable-debug \
      --disable-avdevice --disable-postproc \
      --disable-everything \
      --enable-libopus \
      --enable-encoder=alac,libopus,pcm_s16le,pcm_s32le \
      --enable-decoder=alac,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f64le \
      --enable-muxer=data,pcm_s16le,pcm_s32le \
      --enable-demuxer=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f64le,wav \
      --enable-parser=opus \
      --enable-filter=abuffer,abuffersink,aformat,aresample,anull \
      --enable-protocol=file,pipe \
      --extra-cflags="-mmacosx-version-min=${deployment_target}" \
      --extra-ldflags="-mmacosx-version-min=${deployment_target} -Wl,-headerpad_max_install_names" \
      >/dev/null
    /usr/bin/make -j"$(/usr/sbin/sysctl -n hw.ncpu)" >/dev/null
    /usr/bin/make install >/dev/null
  )
}

build_owntone() {
  local dir="$(source_dir_for owntone)"
  local patch_file

  [[ -n "${dir}" && -d "${dir}" ]] \
    || fail "OwnTone's extracted source tree is missing; refusing to apply patches without it." 65

  # The three local patches are GPL derivative works of OwnTone and live in
  # ThirdPartyPatches/. They are applied here so the built binary matches the
  # corresponding source this build can emit.
  if [[ ! -f "${dir}/.patched" ]]; then
    for patch_file in "${patch_dir}"/*.patch; do
      print -r -- "    applying ${patch_file:t}"
      (cd "${dir}" && /usr/bin/patch -p1 --forward --silent < "${patch_file}")
    done
    : > "${dir}/.patched"
  fi

  # The app speaks to exactly four JSON endpoints and writes into a pipe, so
  # every optional subsystem is off. Chromecast is the one thing switched on,
  # and it is the reason gnutls and protobuf-c are in the closure at all.
  # DATADIR is compiled in as -DDATADIR=\"$(pkgdatadir)\", and httpd stat()s
  # DATADIR/htdocs at startup - with the web interface disabled too, because
  # the JSON API is served by the same httpd. Point it at the installed
  # location so the runtime starts wherever the pkg puts it, with no -w needed.
  # sysconfdir and localstatedir are compiled in the same way and name the
  # build tree too. Nothing reads them - the app passes -c and a state
  # directory - but they carried the builder's home into the binary. pkglibdir
  # PKGLIBDIR is the path OwnTone dlopens its SQLite extension from. The app
  # passes -s, so it was not load-bearing either, but leaving it wrong meant
  # the runtime worked only because something else compensated - which is the
  # shape of the web-root bug, not a difference from it.
  #
  # The space needs escaping, and only here. These values land in a recipe as
  # -DDATADIR=\"$(pkgdatadir)\", where the quotes are backslash-escaped rather
  # than shell quotes, so an unescaped space splits the compiler argument in
  # two. A backslash in the value survives make and is removed by the shell,
  # leaving one argument with the space intact.
  local escaped_prefix="${runtime_install_prefix// /\\ }"
  configure_make_overrides=(
    "pkgdatadir=${escaped_prefix}/share/owntone"
    "sysconfdir=${escaped_prefix}/etc"
    "localstatedir=${escaped_prefix}/var"
    "pkglibdir=${escaped_prefix}/lib/owntone"
  )
  configure_and_make "${dir}" \
    --enable-chromecast \
    --disable-webinterface \
    --disable-spotify \
    --disable-mpd \
    --disable-lastfm \
    --disable-install-user \
    --disable-install-conf-file \
    --disable-install-systemd \
    --without-avahi \
    --without-alsa \
    --without-pulseaudio \
    --without-libwebsockets
  configure_make_overrides=()
}

# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------
build_component() {
  local name="$1"
  local stamp="${stamps}/${name}"

  if [[ -f "${stamp}" ]]; then
    print -r -- "==> ${name} ${component_version[${name}]} (already built)"
    return 0
  fi
  print -r -- "==> ${name} ${component_version[${name}]}"
  extract_component "${name}"
  "build_${name}"
  : > "${stamp}"
}

if (( update_lock )); then
  /bin/rm -f -- "${lock_file}.new"
  {
    print -r -- "# Pinned upstream sources for Scripts/build-owntone-runtime.sh."
    print -r -- "# Regenerate with --update-lock. Columns: name, version, sha256, url."
  } > "${lock_file}.new"
fi

print -r -- "==> Fetching sources"
for name in "${component_order[@]}"; do
  fetch_component "${name}"
done

if (( update_lock )); then
  /bin/mv -f "${lock_file}.new" "${lock_file}"
  print -r -- "Wrote ${lock_file}"
  exit 0
fi

if [[ -n "${only_component}" ]]; then
  build_component "${only_component}"
  print -r -- "Built only: ${only_component}"
  exit 0
fi

for name in "${component_order[@]}"; do
  build_component "${name}"
done

# --------------------------------------------------------------------------
# Relocation
#
# The prefix above has absolute install names pointing into .build. The shipped
# tree must not, so every dylib is given an @rpath id and every load command is
# rewritten to match, exactly as Scripts/build-app.sh does for airptpd.
# --------------------------------------------------------------------------
print -r -- "==> Producing a relocatable tree"
/bin/rm -rf -- "${output_dir}"
/bin/mkdir -p "${output_dir}/sbin" "${output_dir}/lib"

[[ -x "${prefix}/sbin/owntone" ]] || fail "OwnTone was not installed at ${prefix}/sbin/owntone" 65
/usr/bin/install -m 755 "${prefix}/sbin/owntone" "${output_dir}/sbin/owntone"

is_system_dylib() {
  case "$1" in
    /usr/lib/*|/System/Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

macho_dependencies() {
  /usr/bin/otool -L "$1" | /usr/bin/awk 'NR > 1 { print $1 }'
}

typeset -A collected
typeset -a pending
pending=("${output_dir}/sbin/owntone")

while (( ${#pending} > 0 )); do
  current="${pending[1]}"
  shift pending
  while IFS= read -r dependency; do
    [[ -z "${dependency}" ]] && continue
    is_system_dylib "${dependency}" && continue
    # A library built by cmake already carries an @rpath id, so its load command
    # names no directory. Resolving those against the build prefix is what makes
    # them collectable: skipping them left libjson-c out of the tree entirely
    # and the binary would not start.
    if [[ "${dependency}" == @rpath/* ]]; then
      dependency="${prefix}/lib/${dependency#@rpath/}"
    elif [[ "${dependency}" == @* ]]; then
      fail "${current:t} has a load-path-relative dependency this build cannot resolve: ${dependency}" 65
    fi
    if [[ ! -f "${dependency}" ]]; then
      fail "Missing dependency for ${current}: ${dependency}" 66
    fi
    # Anything not built here and not a system library came off the build
    # machine — a Homebrew prefix, most likely — and would ship unpinned,
    # unverified and absent from the source manifest. ffmpeg's autodetection
    # dragged X11 in exactly this way once; make it a build failure rather than
    # something to notice later in an otool listing.
    if [[ "${dependency}" != "${prefix}/"* ]]; then
      fail "${current:t} depends on a library this build did not produce: ${dependency}. Pin it as a component or disable whatever pulled it in." 65
    fi
    library_basename="${dependency:t}"
    if [[ -n "${collected[${library_basename}]:-}" ]]; then
      [[ "${collected[${library_basename}]}" == "${dependency}" ]] \
        || fail "Two different libraries claim the basename ${library_basename}" 65
      continue
    fi
    collected[${library_basename}]="${dependency}"
    /usr/bin/install -m 755 "${dependency}" "${output_dir}/lib/${library_basename}"
    pending+=("${output_dir}/lib/${library_basename}")
  done < <(macho_dependencies "${current}")
done

# OwnTone's httpd stat()s a web root at startup and dies if it is missing,
# even with --disable-webinterface: the JSON API is served by the same httpd.
# The path it falls back to is the build prefix, compiled into the binary, so a
# runtime moved anywhere else refuses to start. install-local-owntone-agent.sh
# passes -w when it finds this directory beside the executable, so shipping it -
# empty - is what makes the runtime relocatable.
/bin/mkdir -p "${output_dir}/share/owntone/htdocs"
/bin/cat > "${output_dir}/share/owntone/htdocs/README.txt" <<'WEBROOT'
Intentionally empty.

OwnTone's HTTP server refuses to start when its web root does not exist, and
the compiled-in default points at the machine this runtime was built on. The
web interface itself is disabled; only the JSON API is used. This directory
exists so the server has something to stat().
WEBROOT

# The sqlite extension OwnTone dlopens is not a load-command dependency, so it
# is carried over explicitly along with any runtime data the build produced.
if [[ -f "${prefix}/lib/owntone/owntone-sqlext.so" ]]; then
  /bin/mkdir -p "${output_dir}/lib/owntone"
  /usr/bin/install -m 755 "${prefix}/lib/owntone/owntone-sqlext.so" "${output_dir}/lib/owntone/owntone-sqlext.so"
fi

for library in "${output_dir}"/lib/*.dylib(N) "${output_dir}"/lib/owntone/*.so(N); do
  /usr/bin/install_name_tool -id "@rpath/${library:t}" "${library}" 2>/dev/null || true
  /usr/bin/install_name_tool -add_rpath "@loader_path" "${library}" 2>/dev/null || true
done
/usr/bin/install_name_tool -add_rpath "@executable_path/../lib" "${output_dir}/sbin/owntone"

for target in "${output_dir}/sbin/owntone" "${output_dir}"/lib/*.dylib(N) "${output_dir}"/lib/owntone/*.so(N); do
  while IFS= read -r dependency; do
    is_system_dylib "${dependency}" && continue
    [[ "${dependency}" == @* ]] && continue
    /usr/bin/install_name_tool -change "${dependency}" "@rpath/${dependency:t}" "${target}"
  done < <(macho_dependencies "${target}")
done

# --------------------------------------------------------------------------
# Capability assertions
#
# Trimming ffmpeg and picking encoders by configure flag is exactly the kind of
# change that builds cleanly and then fails at the first Chromecast connection.
# It already happened once: without libopus the only Opus encoder was ffmpeg's
# native one, which accepts fltp while OwnTone hands it S16, so Chromecast
# output could not have worked. Nothing in the build said so.
#
# Ask the built libraries what they can actually do, and fail here instead.
print -r -- "==> Asserting the codecs OwnTone needs"
capability_probe="${build_root}/capability-probe"
/bin/cat > "${capability_probe}.c" <<'PROBE'
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavformat/avformat.h>
#include <stdio.h>

static int failures;

static void require_encoder(enum AVCodecID id, enum AVSampleFormat wanted, const char *why)
{
  const AVCodec *codec = avcodec_find_encoder(id);
  const enum AVSampleFormat *formats = NULL;
  int count = 0;

  if (!codec)
    {
      printf("  MISSING encoder for %s (%s)\n", avcodec_get_name(id), why);
      failures++;
      return;
    }
  if (avcodec_get_supported_config(NULL, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0,
                                   (const void **)&formats, &count) < 0 || !formats)
    {
      printf("  CANNOT QUERY sample formats for %s (%s)\n", codec->name, why);
      failures++;
      return;
    }
  for (int i = 0; i < count; i++)
    if (formats[i] == wanted)
      {
        printf("  ok  %-12s %-4s  %s\n", codec->name, av_get_sample_fmt_name(wanted), why);
        return;
      }
  printf("  %s does not accept %s, which %s needs\n", codec->name, av_get_sample_fmt_name(wanted), why);
  failures++;
}

static void require_decoder(enum AVCodecID id, const char *why)
{
  if (avcodec_find_decoder(id))
    printf("  ok  %-12s       %s\n", avcodec_get_name(id), why);
  else
    {
      printf("  MISSING decoder for %s (%s)\n", avcodec_get_name(id), why);
      failures++;
    }
}

static void require_muxer(const char *name, const char *why)
{
  if (av_guess_format(name, NULL, NULL))
    printf("  ok  %-12s       %s\n", name, why);
  else
    {
      printf("  MISSING muxer %s (%s)\n", name, why);
      failures++;
    }
}

static void require_filter(const char *name, const char *why)
{
  if (avfilter_get_by_name(name))
    printf("  ok  %-12s       %s\n", name, why);
  else
    {
      printf("  MISSING filter %s (%s)\n", name, why);
      failures++;
    }
}

int main(void)
{
  // outputs/airplay.c and outputs/raop.c both ask for MEDIA_FORMAT_ALAC.
  require_encoder(AV_CODEC_ID_ALAC, AV_SAMPLE_FMT_S16P, "AirPlay 1 and 2");
  // outputs/cast.c asks for MEDIA_FORMAT_OPUS, and transcode.c sets S16 with
  // the comment "Only libopus support".
  require_encoder(AV_CODEC_ID_OPUS, AV_SAMPLE_FMT_S16, "Chromecast");
  // The pipe this app writes into is raw 16-bit stereo PCM.
  require_decoder(AV_CODEC_ID_PCM_S16LE, "the app's PCM pipe");
  if (!av_find_input_format("s16le"))
    {
      printf("  MISSING demuxer s16le (the app's PCM pipe)\n");
      failures++;
    }
  else
    printf("  ok  %-12s       %s\n", "s16le", "the app's PCM pipe");
  // Both output profiles set format = "data", which passes the raw encoder
  // packet through unmuxed. Without it neither output can start.
  require_muxer("data", "AirPlay and Chromecast packet output");
  // transcode.c builds its resampling graph from these by name.
  require_filter("abuffer", "transcode input");
  require_filter("abuffersink", "transcode output");
  require_filter("aformat", "sample format conversion");
  require_filter("aresample", "sample rate conversion");
  return failures ? 1 : 0;
}
PROBE
/usr/bin/clang "${capability_probe}.c" \
  -I"${prefix}/include" -L"${prefix}/lib" -lavcodec -lavfilter -lavformat -lavutil \
  -Wl,-rpath,"${prefix}/lib" -o "${capability_probe}" \
  ${=common_cflags} >/dev/null
if ! "${capability_probe}"; then
  fail "The built ffmpeg cannot do what OwnTone asks of it. Fix the configure flags above before shipping this runtime." 65
fi

# --------------------------------------------------------------------------
# No build machine in the shipped tree
#
# A load command can be rewritten after the fact; a string the compiler baked
# into a binary cannot. That is how a runtime shipped whose web root pointed at
# a directory under the builder's home: it worked on the machine that made it
# and nowhere else, and every check up to this point passed because on that
# machine the directory was still there.
#
# So refuse any shipped file that names the build tree, and require the web
# root to be the location the installer actually uses.
# --------------------------------------------------------------------------
print -r -- "==> Checking that nothing names the build machine"
# Only one of these paths decides whether the runtime starts, so only that one
# is fatal. The rest are reported because they are worth knowing about: ffmpeg
# records its whole configure line in libavutil by design, and gnutls keeps a
# config path it never finds. Both are harmless to run and both put a
# directory from the build machine into a binary sent to customers.
build_root_references="$(/usr/bin/grep -rlF -- "${build_root}" "${output_dir}" 2>/dev/null || true)"
if [[ -n "${build_root_references}" ]]; then
  print -r -- "    note: these still carry a build-tree path, none of it load-bearing:"
  print -rl -- ${(f)build_root_references} | /usr/bin/sed 's|^|      |; s|.*/||'
fi
expected_web_root="${runtime_install_prefix}/share/owntone/htdocs"
# No -q: it stops reading on the first match, strings dies of SIGPIPE, and
# under pipefail the pipeline reports failure even though the match succeeded.
# A check that fails when it passes is worse than no check at all.
if ! /usr/bin/strings -a "${output_dir}/sbin/owntone" | /usr/bin/grep -xF -- "${expected_web_root}" >/dev/null; then
  print -r -u2 -- "owntone does not carry the installed web root: ${expected_web_root}"
  print -r -u2 -- "Its httpd stat()s that path at startup and quits when it is missing, so a wrong one means no OwnTone anywhere but here."
  exit 65
fi
print -r -- "    web root ${expected_web_root}"

print -r -- "==> Verifying the relocatable tree"
for target in "${output_dir}/sbin/owntone" "${output_dir}"/lib/*.dylib(N) "${output_dir}"/lib/owntone/*.so(N); do
  architectures="$(/usr/bin/lipo -archs "${target}")"
  [[ "${architectures}" == "${release_architecture}" ]] \
    || fail "${target:t} has architectures '${architectures}', expected '${release_architecture}'." 65
  while IFS= read -r dependency; do
    is_system_dylib "${dependency}" && continue
    [[ "${dependency}" == @rpath/* ]] && continue
    fail "${target:t} still refers to a build-tree path: ${dependency}" 65
  done < <(macho_dependencies "${target}")
done

# --------------------------------------------------------------------------
# Relocation smoke test
#
# The assertions above ask the libraries what they can do. They cannot catch a
# path compiled into the binary, because during a build that path still exists.
# That is exactly how a runtime shipped once that could not start anywhere but
# the machine it was built on: OwnTone's httpd stat()s a web root, the default
# is the build prefix, and every check passed while the build tree was still
# there.
#
# So run it somewhere else. Copy the tree to a temporary directory, give it a
# throwaway configuration, and require the JSON API to answer.
# --------------------------------------------------------------------------
print -r -- "==> Starting the runtime outside the build tree"
relocation_root="$(mktemp -d "${TMPDIR:-/private/tmp}/owntone-relocation.XXXXXX")"
relocation_port=3699
relocation_pid=""
cleanup_relocation() {
  # Every step tolerated: the process may exit between the check and the
  # signal, and under set -e a kill that finds nothing would fail the build
  # after the test it was cleaning up had already passed.
  if [[ -n "${relocation_pid}" ]]; then
    kill "${relocation_pid}" 2>/dev/null || true
    sleep 1
    kill -9 "${relocation_pid}" 2>/dev/null || true
  fi
  /bin/rm -rf -- "${relocation_root}" || true
}
trap cleanup_relocation EXIT HUP INT TERM

/usr/bin/ditto "${output_dir}" "${relocation_root}/runtime"
/bin/mkdir -p "${relocation_root}/state/media" "${relocation_root}/state/cache" "${relocation_root}/state/logs"
/usr/bin/mkfifo -m 600 "${relocation_root}/state/media/probe.pcm"
/bin/cat > "${relocation_root}/state/owntone.conf" <<EOF
general {
  uid = "$(/usr/bin/id -un)"
  db_path = "${relocation_root}/state/owntone.db"
  cache_dir = "${relocation_root}/state/cache"
  logfile = "${relocation_root}/state/owntone.log"
  loglevel = info
  trusted_networks = { "localhost" }
}
library {
  name = "relocation probe"
  port = ${relocation_port}
  directories = { "${relocation_root}/state/media" }
  pipe_autostart = false
}
audio {
  type = "disabled"
}
EOF

"${relocation_root}/runtime/sbin/owntone" -f --mdns-no-cname \
  -c "${relocation_root}/state/owntone.conf" \
  -s "${relocation_root}/runtime/lib/owntone/owntone-sqlext.so" \
  -w "${relocation_root}/runtime/share/owntone/htdocs" \
  > "${relocation_root}/state/stdout.log" 2>&1 &
relocation_pid=$!

relocation_ready=0
for _ in {1..30}; do
  if /usr/bin/curl --silent --max-time 2 "http://127.0.0.1:${relocation_port}/api/config" >/dev/null 2>&1; then
    relocation_ready=1
    break
  fi
  kill -0 "${relocation_pid}" 2>/dev/null || break
  sleep 1
done

if (( relocation_ready == 0 )); then
  print -r -u2 -- "The runtime did not answer its API when run outside the build tree."
  print -r -u2 -- "This is what a path compiled into the binary looks like. Last output:"
  /usr/bin/tail -20 "${relocation_root}/state/stdout.log" >&2 2>/dev/null || true
  exit 65
fi
print -r -- "    the JSON API answered from ${relocation_root}/runtime"
cleanup_relocation
trap - EXIT HUP INT TERM

{
  print -r -- "OwnTone runtime for AirPlay Controller"
  print -r -- "architecture: ${release_architecture}"
  print -r -- "deployment target: macOS ${deployment_target}"
  print -r -- ""
  print -r -- "Built from the pinned sources recorded in Scripts/owntone-sources.lock."
  print -r -- "OwnTone is GPL-2.0-or-later and carries the three patches in"
  print -r -- "ThirdPartyPatches/OwnTone-29.3, which are GPL-2.0-or-later derivative works."
  print -r -- "Corresponding source: ./Scripts/build-owntone-runtime.sh --emit-source-archive"
  print -r -- ""
  print -r -- "Components:"
  for name in "${component_order[@]}"; do
    print -r -- "  ${name} ${component_version[${name}]} — ${component_url[${name}]}"
  done
  print -r -- ""
  print -r -- "Taken from macOS instead of built (GPL system library exception):"
  print -r -- "  zlib, libcurl, libxml2"
} > "${output_dir}/SOURCES.txt"

if (( emit_source_archive )); then
  print -r -- "==> Writing the corresponding-source archive"
  archive_root="${build_root}/corresponding-source"
  archive_name="owntone-corresponding-source-${component_version[owntone]}"
  /bin/rm -rf -- "${archive_root}"
  /bin/mkdir -p "${archive_root}/${archive_name}"
  # Complete corresponding source means actual bytes, not a script that fetches
  # them: an upstream that retires a release must not make the obligation
  # impossible to honour. The build recipe and the local patches go in too,
  # because they are the scripts used to control compilation.
  /bin/cp -R "${archives}"/*(N) "${archive_root}/${archive_name}/"
  /bin/cp "${script_dir}/build-owntone-runtime.sh" "${lock_file}" "${archive_root}/${archive_name}/"
  /bin/cp -R "${patch_dir}" "${archive_root}/${archive_name}/patches"
  (cd "${archive_root}" && /usr/bin/tar -czf "${project_root}/dist/${archive_name}.tar.gz" "${archive_name}")
  print -r -- "Corresponding source: ${project_root}/dist/${archive_name}.tar.gz"
fi

if (( keep_build == 0 )); then
  /bin/rm -rf -- "${build_root}"
fi

print -r -- "Built: ${output_dir}/sbin/owntone"
print -r -- "Libraries: $(print -rl -- "${output_dir}"/lib/*.dylib(N) | wc -l | tr -d ' ')"
print -r -- "Manifest: ${output_dir}/SOURCES.txt"

#!/usr/bin/env bash
# MoonRay dependency presence matrix, run inside a candidate base image.
#
# Prints one PRESENT/MISSING/FIXER line per dependency and always exits 0
# unless STRICT=1, which fails on any MISSING line. FIXER lines (ispc,
# git-lfs) are not failures: fixers 03 and 01 provide them.
#
#   bash probe/presence_check.sh            # report only
#   STRICT=1 bash probe/presence_check.sh   # fail on MISSING
set -u
fail=0

chk() {
    local name="$1" test_expr="$2" kind="${3:-MISSING}"
    if bash -c "${test_expr}" >/dev/null 2>&1; then
        echo "PRESENT ${name}"
    elif [ "${kind}" = "FIXER" ]; then
        echo "FIXER ${name}"
    else
        echo "MISSING ${name}"
        fail=1
    fi
}

# --- MoonRay-only libraries (ASWF conan packages; ci-vfxall does not ship
# --- these, ci-moonray does; locations cover /usr/local deploy + system paths)
chk jsoncpp          '[ -e /usr/local/include/jsoncpp/json/json.h ] && compgen -G "/usr/local/lib*/libjsoncpp*"'
chk glfw             '[ -e /usr/local/include/GLFW/glfw3.h ] && compgen -G "/usr/local/lib*/libglfw*"'
chk lua              '( compgen -G "/usr/local/include/lua.h" || compgen -G "/usr/local/include/lua*/lua.h" ) && compgen -G "/usr/local/lib*/liblua*"'
chk libmicrohttpd    '[ -e /usr/local/include/microhttpd.h ] && compgen -G "/usr/local/lib*/libmicrohttpd*"'
chk libcgroup        'compgen -G "/usr/local/include/libcgroup*" && compgen -G "/usr/local/lib*/libcgroup*"'
chk random123        'compgen -G "/usr/local/include/Random123*" || compgen -G "/usr/local/include/random123*"'
chk openimagedenoise '[ -e /usr/local/include/OpenImageDenoise ] && compgen -G "/usr/local/lib*/libOpenImageDenoise*"'

# --- present in ci-vfxall for other reasons (USD/OIIO/OpenUSD deps) — checked
# --- so a surprise absence is visible before the build fails on it
chk freetype  '( [ -e /usr/local/include/freetype2 ] || [ -e /usr/include/freetype2 ] ) && ( compgen -G "/usr/local/lib*/libfreetype*" || compgen -G "/usr/lib64/libfreetype*" )'
chk libjpeg   '( compgen -G "/usr/local/include/jpeglib.h" || compgen -G "/usr/include/jpeglib.h" ) && ( compgen -G "/usr/local/lib*/libjpeg*" || compgen -G "/usr/lib64/libjpeg*" )'
chk embree    'compgen -G "/usr/local/lib*/libembree4*" && [ -e /usr/local/include/embree4/rtcore.h ]'
chk log4cplus '[ -e /usr/local/include/log4cplus ] && compgen -G "/usr/local/lib*/liblog4cplus*"'
chk cppunit   '[ -e /usr/local/include/cppunit ] && compgen -G "/usr/local/lib*/libcppunit*"'
chk openssl   'compgen -G "/usr/local/include/openssl/ssl.h" || compgen -G "/usr/include/openssl/ssl.h"'
chk zlib      'compgen -G "/usr/local/include/zlib.h" || compgen -G "/usr/include/zlib.h"'
chk opengl    'compgen -G "/usr/local/include/GL/gl.h" || compgen -G "/usr/include/GL/gl.h"'

# --- provided by our own fixers, never a provisioning item
chk ispc    'command -v ispc'    FIXER
chk git-lfs 'command -v git-lfs' FIXER

if [ "${STRICT:-0}" = "1" ] && [ "${fail}" -ne 0 ]; then
    echo "STRICT: missing dependencies remain"
    exit 1
fi
exit 0

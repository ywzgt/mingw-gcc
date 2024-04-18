#!/bin/bash

set -e
source envars.sh

case "$1" in
	aarch64|armv7|i686|x86_64)
		TRIPLE="$1-w64-mingw32"
		ARCH=$1; shift
		;;
	*)
		ARCH=x86_64; TRIPLE="$ARCH-w64-mingw32"
		;;
esac

GCC_VER=$(gcc -dumpversion)
BINUTILS_VER=$(ld.bfd -v|sed 's/[a-zA-Z]\|(\|)\|\s//g')
MINGW_VER=9b17c3374aa9eb809938bbcf7cf37093e842a4a7  # Apr 17
PKG="$PWD/DEST"
PREFIX="/usr/${TRIPLE}"
MINGW_URL="https://github.com/mingw-w64/mingw-w64"
URL="https://mirrors.kernel.org/gnu"

getsrc_gnu() {
	local pkg=$1
	local ver=$2
	local suffix=${3:-xz}
	[[ ! -d ${pkg} ]] || return 0
	if [[ ${pkg} = gcc ]]; then
		wget -nv -c ${URL}/${pkg}/${pkg}-${ver}/${pkg}-${ver}.tar.${suffix}
	else
		wget -nv -c ${URL}/${pkg}/${pkg}-${ver}.tar.${suffix}
	fi

	tar xf ${pkg}-${ver}.tar.${suffix}
	ln -sv ${pkg}{-${ver},}
	install -d ${pkg}/build
}

prepare_src() {
	if [ ! -d mingw-w64 ]; then
		git clone --no-checkout ${MINGW_URL}
		cd mingw-w64
		git checkout ${MINGW_VER}
		cd ..
	fi

	getsrc_gnu gcc ${GCC_VER}
	getsrc_gnu binutils ${BINUTILS_VER}
}

build_binutils() {
	cd binutils/build
	../configure --prefix=/usr \
		--disable-{werror,libctf,gprof,gprofng} \
		--target=${TRIPLE} --with-system-zlib
	make
	make DESTDIR=$PWD/pkg install

	rm -f pkg/usr/lib/*.{a,la,so*}
	rm -rf pkg/usr/{include,lib/bfd-plugins,share/{info,locale}}
	rm -rf pkg/usr/$(gcc -dumpmachine)
	strip -s pkg/usr/{,${TRIPLE}/}bin/*
	cp -a pkg/usr/* /usr/
	install -d "${PKG}/usr"
	cp -a pkg/usr/* "${PKG}/usr"

	cd ../..
}

build_gcc() {
	local arg gcc_flags
	if [[ ${ARCH} == i686 ]]; then
		arg="--disable-sjlj-exceptions --with-dwarf2"
	fi

	if [[ $1 == bootstrap ]]; then
		gcc_flags=(
			--with-newlib
			--with-sysroot=${PREFIX}
			--without-headers
			--disable-{nls,shared,threads}
			--disable-lib{atomic,gomp,quadmath,vtv,stdcxx}
		)
	elif [[ -n ${THREADS} && ${THREADS} != win32 ]]; then
		[[ ${THREADS} != mcf ]] || build_mcfgthread
		arg+=" --enable-threads=${THREADS}"
	fi

	cd gcc/build
	find -depth -delete

	../configure --prefix=/usr \
		--target=${TRIPLE} \
		--disable-{bootstrap,multilib} $arg \
		--enable-languages=c,c++ \
		--with-system-zlib "${gcc_flags[@]}"
	make
	make DESTDIR=$PWD/pkg install

	rm -f pkg/usr/lib/libcc1.*
	rm -rf pkg/usr/share
	rm -f pkg${PREFIX}/lib/*.py
	strip -s pkg/usr/libexec/gcc/${TRIPLE}/${GCC_VER}/{cc1*,collect2,lto*}
	strip -s pkg/usr/bin/*
	ln -s ${TRIPLE}-gcc "pkg/usr/bin/${TRIPLE}-cc"
	if [[ -n $(find pkg${PREFIX}/lib -name \*.dll 2>/dev/null) ]]; then
		install -d pkg${PREFIX}/bin
		mv pkg${PREFIX}/lib/*.dll "pkg${PREFIX}/bin"
	fi
	cp -a pkg/usr/* /usr/
	install -d "${PKG}/usr"
	cp -a pkg/usr/* "${PKG}/usr"

	cd ../..
}

build_mcfgthread() {
	local url=https://github.com/lhmouse/mcfgthread
	local branch=$(git ls-remote $url|grep 'refs/heads/releases/'|awk '{print$2}'|sort -uV|sed 's/^refs\/heads\///'|tail -1)
	if [ ! -d mcfgthread ]; then
		git clone --depth 1 ${url} -b ${branch}
	fi

	echo 'int main(){}' | ${TRIPLE}-c++ -x c++ - 2>/dev/null || { THREADS=posix; return; }
	cd mcfgthread; rm -rf build
	sed -i '/^exe_wrapper/d' meson.cross.${ARCH}-w64-mingw32

	meson setup build \
		--prefix=${PREFIX} \
		--buildtype=release \
		--cross-file=meson.cross.${ARCH}-w64-mingw32
	ninja -C build
	ninja -C build install
	DESTDIR=${PKG} ninja -C build install >& /dev/null
	cd ..
}

build_mingw() {
	cd mingw-w64/mingw-w64-headers
	# https://learn.microsoft.com/zh-cn/cpp/porting/modifying-winver-and-win32-winnt?view=msvc-170
	rm -rf build && mkdir build && cd build
	../configure --prefix=${PREFIX} \
		--with-default-win32-winnt=0x0601 \
		--with-default-msvcrt=ucrt
	make install DESTDIR=${PWD}/pkg
	if [[ -f ${PREFIX}/include/pthread.h ]]; then
		rm -f pkg/${PREFIX}/include/pthread_{signal,time,unistd}.h  # Drop the dummy pthread headers
	fi
	cp -a pkg/* /; cp -a pkg/* ${PKG}
	[[ $1 != headers ]] || { cd ../../..; return; }

	local FLAGS
	cd ../../mingw-w64-crt
	case "${TRIPLE}" in
		i686-*)
			FLAGS="--enable-lib32 --disable-lib64"
			;;
		x86_64-*)
			FLAGS="--disable-lib32 --enable-lib64"
			;;
	esac
	rm -rf build && mkdir build && cd build
	../configure --prefix=${PREFIX} --host=${TRIPLE} $FLAGS
	make
	make install
	make install DESTDIR=${PKG} >/dev/null

	 if [[ ! -f ${PKG}${PREFIX}/lib/libssp.a ]]; then
		# Create empty dummy archives, to avoid failing when the compiler
		# driver adds "-lssp -lssh_nonshared" when linking.
		install -d ${PKG}${PREFIX}/lib
		${TRIPLE}-ar rcs ${PKG}${PREFIX}/lib/libssp.a
		${TRIPLE}-ar rcs ${PKG}${PREFIX}/lib/libssp_nonshared.a
	fi

	cd ../../mingw-w64-libraries
	cd winpthreads
	rm -rf build && mkdir build && cd build
	../configure --prefix=${PREFIX} --host=${TRIPLE}
	make
	make install
	make install DESTDIR=${PKG} >/dev/null
	cd ../../../..
}

cleanup() {
	tidy() {
		${TRIPLE}-strip -s ${PKG}${PREFIX}/bin/*.dll
		find ${PKG} -type f -name \*.exe -exec ${TRIPLE}-strip -s {} \;
		find ${PKG} -type f -name \*.la -delete
		find ${PKG} -type d -empty -delete
		chmod -x  ${PKG}${PREFIX}/lib/*.a
		rm -rf ${PKG}${PREFIX}/share
	}

	if [[ $1 == tidy ]]; then
		tidy; return
	fi

	if [[ -n $(ls -A ${PKG}${PREFIX}/lib 2>/dev/null) ]]; then
		rm -rf ${PREFIX}
		rm -rf /usr/lib{,exec}/gcc/${TRIPLE}/${GCC_VER}
		tidy
		cp -a ${PKG}/usr/* /usr
		rm -rf ${PKG}/*
		cp -a binutils/build/pkg/usr ${PKG}

		cat >/Description<<-EOF
			BINUTILS: ${BINUTILS_VER}
			GCC: ${GCC_VER}
			HOST: $(ldd --version|head -1|sed 's/^ldd\s\+//')
			MINGW: ${MINGW_VER::7}
		EOF
		echo "PKG=rootfs${PKG}" >/ENV
		if [[ -n ${THREADS} && ${THREADS} != win32 ]]; then
			echo "gcc_ver=${GCC_VER}-${THREADS}" >>/ENV
		else
			echo "gcc_ver=${GCC_VER}" >>/ENV
		fi
	fi
}

if [[ $1 == bootstrap ]]; then
	prepare_src
	build_binutils
	build_mingw headers
	build_gcc bootstrap
	build_mingw
	build_gcc
elif [[ $1 == test ]]; then
	shift
	source test_build.sh
	t_build $*
else
	cleanup
	build_gcc
	build_mingw
	cleanup tidy
fi

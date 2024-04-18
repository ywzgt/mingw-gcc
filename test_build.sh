#!/bin/bash

_binutils() {
	getsrc_gnu binutils ${BINUTILS_VER}
	cd binutils/build
	../configure --prefix=${PREFIX} \
		--host=${TRIPLE} \
		--disable-{werror,libctf,gprof,gprofng}
	make
	make DESTDIR=${PKG} install tooldir=${PREFIX}
	rm -f ${PKG}${PREFIX}/lib/lib{bfd,sframe,opcodes}.a
	cd ../..
}

_ffmpeg() {
	local url=https://github.com/FFmpeg/FFmpeg
	local branch=$(git ls-remote $url|grep 'refs/heads/release/'|awk '{print$2}'|sort -uV|sed 's/^refs\/heads\///'|tail -1)

	if [ ! -d ffmpeg ]; then
		git clone --depth 1 ${url} -b ${branch} ffmpeg
	fi

	local _arch=${ARCH}
	case "${_arch}" in
		i686|x86_64)
			_yasm
			[[ $_arch != i686 ]] || _arch=x86
			;;
	esac

	cd ffmpeg
	./configure --prefix=${PREFIX} \
		--cross-prefix=${TRIPLE}- \
		--target-os=mingw32 --arch=$_arch \
		--enable-{gpl,version3,nonfree}
	make
	make DESTDIR=${PKG} install
	cd ..
}

_gcc() {
	getsrc_gnu gcc ${GCC_VER}
	getsrc_gnu gmp 6.3.0
	getsrc_gnu mpfr 4.2.1
	getsrc_gnu mpc 1.3.1 gz
	ln -srf gmp mpfr mpc gcc

	local arg
	if [[ ${ARCH} == i686 ]]; then
		arg="--disable-sjlj-exceptions --with-dwarf2"
	fi

	if [[ -n ${THREADS} && ${THREADS} != win32 ]]; then
		[[ ${THREADS} != mcf ]] || build_mcfgthread
		arg+=" --enable-threads=${THREADS}"
	fi

	cd gcc/build
	../configure --prefix=${PREFIX} \
		--host=${TRIPLE} \
		--disable-{bootstrap,multilib,lib{gcc,stdcxx}} $arg \
		--enable-languages=c,c++
	make
	make DESTDIR=${PKG} install
	ln ${PKG}${PREFIX}/bin/{g,}cc.exe
	cd ../..

	cp -an ${PREFIX}/{include,lib} "${PKG}${PREFIX}" || true
	cp -n /usr/lib/gcc/${TRIPLE}/${GCC_VER}/libgcc*.a \
		"${PKG}${PREFIX}/lib/gcc/${TRIPLE}/${GCC_VER}/" || true
	install -Dt "${PKG}${PREFIX}/bin" ${PREFIX}/bin/*.dll
	if [[ ${THREADS} == mcf ]]; then
		ln ${PKG}${PREFIX}/bin/libmcfgthread-*.dll "${PKG}${PREFIX}/libexec/gcc/${TRIPLE}/${GCC_VER}/"
	elif [[ ${THREADS} == posix ]]; then
		ln ${PKG}${PREFIX}/bin/libwinpthread-*.dll "${PKG}${PREFIX}/libexec/gcc/${TRIPLE}/${GCC_VER}/"
	fi
}

_make() {
	local MAKE_VER=$(make -v|sed -n 's/GNU Make \(.*\)/\1/p')
	getsrc_gnu make ${MAKE_VER} gz
	cd make

	./configure --prefix=${PREFIX} --host=${TRIPLE}
	make
	make DESTDIR=${PKG} install
	cd ..
}

_openssl() {
	local flags
	if [ ! -d openssl ]; then
		git clone --depth 1 https://github.com/openssl/openssl
	fi
	cd openssl

	./Configure --prefix=${PREFIX} \
		--cross-compile-prefix=${TRIPLE}- \
		--libdir=lib no-docs "mingw${ARCH:4}"
	make
	make DESTDIR=${PKG} install
	cd ..
}

_yasm() {
	local src=yasm-1.3.0.tar.gz
	wget -nv https://www.tortall.net/projects/yasm/releases/$src
	tar xf $src
	cd ${src%.tar*}
	sed -i 's#) ytasm.*#)#' Makefile.in
	./configure --prefix=/usr
	make
	make install
	cd ..
}

_zstd() {
	local url=https://github.com/facebook/zstd
	local branch=$(git ls-remote $url|grep 'refs/tags/v.*[0-9]$'|awk '{print$2}'|sort -uV|sed 's/^refs\/tags\///'|tail -1)

	if [ ! -d zstd ]; then
		git clone --depth 1 ${url} -b ${branch}
	fi

	cd zstd
	cmake -B build -S build/cmake \
		-DCMAKE_INSTALL_PREFIX=${PREFIX} \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSTEM_NAME=Windows \
		-DCMAKE_C_COMPILER=${TRIPLE}-cc \
		-DCMAKE_CXX_COMPILER=${TRIPLE}-c++ \
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
		-DZSTD_PROGRAMS_LINK_SHARED=ON -GNinja -Wno-dev
	cmake --build build
	cmake --install build
	cd ..
}

t_build() {
	local target
	for target; do
		case "${target}" in
			ffmpeg)
				_ffmpeg
				;;
			gcc)
				_zstd; _binutils; _make
				_gcc
				cleanup tidy
				;;
			openssl)
				_openssl
				;;
			c|C)
				_ffmpeg
				_openssl
				;;
		esac
	done
	if [[ -n $(ls -A $PKG 2>/dev/null) ]]; then
		echo "PKG=rootfs$PKG/usr" >> /ENV
		[ "$1" = gcc ] || return 0
		if [[ -n ${THREADS} && ${THREADS} != win32 ]]; then
				echo "pkgver=-${GCC_VER}-${THREADS}" >> /ENV
		else
			echo "pkgver=-${GCC_VER}" >> /ENV
		fi
	fi
}

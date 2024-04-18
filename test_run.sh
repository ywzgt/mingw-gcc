#!/bin/bash

set -e

wget -q "https://api.github.com/repos/$GITHUB_REPOSITORY/releases"
wget -nv $(grep browser_download_url releases | grep '/artifacts/' | cut -d: -f2-9 | sed 's/"\|\s//g')

if [[ -n $(find -maxdepth 1 -name \*.zip) ]]; then
	find -maxdepth 1 -name \*.zip | xargs unzip -q
fi

if [[ -n $(find -name \*-i686.tar.xz -o -iname \*-x86_64.tar.xz) ]]; then
	find -name \*-i686.tar.xz -o -iname \*-x86_64.tar.xz | xargs unxz
fi

for f in $(find -maxdepth 1 -name \*.tar); do
	if [[ $f == *-nightly-* ]]; then
		args="-ousr/nightly"
	elif [[ $f == *-mcf-* ]]; then
		args="-ousr/mcf"
	elif [[ $f == *-posix-* ]]; then
		args="-ousr/posix"
	else
		args="-ousr"
	fi
	7z x -y -snl -snh $f ${args}
done

_exec() {
	set -x
	$*
	set +x
}

while read -r EXE; do
	case "$(basename ${EXE})" in
		as.exe)
			_exec "${EXE}" --version
			;;
		gcc.exe|ld.exe|make.exe)
			_exec "${EXE}" -v
			;;
		ffmpeg.exe)
			_exec "${EXE}" -hwaccels
			;;
		openssl.exe)
			_exec "${EXE}" version
			_exec "${EXE}"
			;;
	esac
done < <(find usr -name \*.exe)

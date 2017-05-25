#!/bin/bash
#
# Ubuntu + LinuxTV.org media tree custom kernel package builder
#  This script produces installable kernel packages from
#    - Ubuntu kernel sources for a specific release
#    - Latest upstream LinuxTV media tree drivers
#    - Minimal patches to get the above to build
#    - Additional patches to enable HW and/or
#        optimizations not yet upstreamed
#
# This script also:
#    - A full patch series for reproduction
#    - Generate latest LinuxTV driver patch set on demand
#
#   Copyright (C) 2017 Brad Love <brad at nextdimension dot cc>
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR #PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with this program.
# If not, see http://www.gnu.org/licenses/.
#
################################################

if [ -f ".user_env_file" ] ; then
	. .user_env_file
fi

################################################

[ -z "${U_FULLNAME}" ] && U_FULLNAME="`git config --global user.name`"

[ -z "${U_EMAIL}" ] && U_EMAIL="`git config --global user.email`"

[ -z "${KERNEL_ABI_TAG}" ] && KERNEL_ABI_TAG="+mediatree+hauppauge"

if [ -z "${UBUNTU_VERSION}" ] ; then
	if [ ! -f /etc/lsb-release ] ; then
		echo "No /etc/lsb-release, cannot determine running Ubuntu..."
		exit 250
	fi
	eval `cat /etc/lsb-release`
	UBUNTU_VERSION=${DISTRIB_CODENAME}
fi

#[ -z "${UBUNTU_REVISION}" ] && UBUNTU_REVISION=50aaaec159365f8f8788e054048545e7ec9734f1

################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
TRY_UPDATE=NO
TIP_UBUNTU_VERSION=

export TOP_DEVDIR=`pwd`

if [ -f ".state_env_file" ] ; then
	. .state_env_file
	export KB_PATCH_DIR="${TOP_DEVDIR}/patches/ubuntu-${UBUNTU_VERSION}-${KVER}.${KMAJ}.0"
fi

## Set env var V4L_SYNC_DATE to a specific date to override latest tarball
if [ -z "${V4L_SYNC_DATE}" -a -f "${TOP_DEVDIR}/.flag-media-tree-sync-time" ]; then
	export V4L_SYNC_DATE=`cat ${TOP_DEVDIR}/.flag-media-tree-sync-time`
fi

function get_ubuntu_kver()
{
	export KVER=`grep VERSION ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}/Makefile | head -n 1 | cut -d ' ' -f 3`
	export KMAJ=`grep PATCHLEVEL ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}/Makefile | head -n 1 | cut -d ' ' -f 3`
	export KMIN=0
	export K_ABI_A=`head -n1 ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}/debian.master/changelog | cut -d'-' -f2 | cut -d'.' -f1`
	export K_ABI_B=`head -n1 ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}/debian.master/changelog | cut -d'.' -f4 | cut -d')' -f1`
}

function write_state_env()
{
	echo "KVER=${KVER}" > ${TOP_DEVDIR}/.state_env_file
	echo "KMAJ=${KMAJ}" >> ${TOP_DEVDIR}/.state_env_file
	echo "KMIN=0" >> ${TOP_DEVDIR}/.state_env_file
	echo "K_ABI_A=${K_ABI_A}" >> ${TOP_DEVDIR}/.state_env_file
	echo "K_ABI_B=${K_ABI_B}" >> ${TOP_DEVDIR}/.state_env_file
	echo "K_ABI_MOD=${K_ABI_MOD}" >> ${TOP_DEVDIR}/.state_env_file
	echo "K_BUILD_VER=${K_BUILD_VER}" >> ${TOP_DEVDIR}/.state_env_file
	echo "UBUNTU_REVISION=${UBUNTU_REVISION}" >> ${TOP_DEVDIR}/.state_env_file
	echo "" >> ${TOP_DEVDIR}/.state_env_file
}

function get_ubuntu()
{
	ret_val=0
	cd ${TOP_DEVDIR}
	if [ -z "${1}" ]; then
		TARGET_DIR=ubuntu-${UBUNTU_VERSION}
	else
		TARGET_DIR=${1}
	fi
	if [ ! -d "${TARGET_DIR}" -a -d ".clean-master-repo" ] ; then
		cd .clean-master-repo
		git pull
		cd -
		git clone ${TOP_DEVDIR}/.clean-master-repo ${TARGET_DIR}
	elif [ ! -d "${TARGET_DIR}" ] ; then
		git clone git://kernel.ubuntu.com/ubuntu/ubuntu-${UBUNTU_VERSION}.git ${TARGET_DIR}
	fi

	if [ -n "${UBUNTU_REVISION}" -a "${TARGET_DIR}" != ".clean-master-repo" ] ; then
		cd ${TARGET_DIR}
		git fetch
		if [ -n "${TIP_UBUNTU_REVISION}" -a "${TIP_UBUNTU_REVISION}" != "${UBUNTU_REVISION}" ] ; then
			git checkout ${TIP_UBUNTU_REVISION}
			[ -z "${1}" ] && UBUNTU_REVISION=${TIP_UBUNTU_REVISION}
		else
			git checkout ${UBUNTU_REVISION}
		fi
		cd ..
	else
		cd ${TARGET_DIR}
		git pull
		CUR_UBUNTU_REVISION=`cat .git/refs/heads/master`
		if [ -n "${UBUNTU_REVISION}" -a "${CUR_UBUNTU_REVISION}" != "${UBUNTU_REVISION}" ] ; then
			echo -e "${RED}###############################################"
			echo -e "${RED}###############################################"
			echo -e "${RED}###############################################"
			echo -e "${RED}################### ${GREEN}ATTENTION ${RED}#################"
			echo -e "${RED}####### ${GREEN}Ubuntu master revision updated! ${RED}#######"
			echo -e "${RED}## ${NC}${CUR_UBUNTU_REVISION} ${RED}###"
			echo -e "${RED}###############################################"
			echo -e "${RED}### ${NC}Set env var MEDIATREE_KBUILD_UPDATE=YES ${RED}###"
			echo -e "${RED}############# ${NC}to update build ${RED}#################"
			echo -e "${RED}###############################################${NC}"
			ret_val=1
			if [ "${MEDIATREE_KBUILD_UPDATE}" == "YES" ] ; then
				TIP_UBUNTU_REVISION=${CUR_UBUNTU_REVISION}
				TRY_UPDATE=YES
			fi
		elif [ -z "${1}" ] ; then
			UBUNTU_REVISION=${CUR_UBUNTU_REVISION}
		fi
	fi

	if [ -z "${1}" ] ; then
		get_ubuntu_kver
		write_state_env
		export KB_PATCH_DIR="${TOP_DEVDIR}/patches/ubuntu-${UBUNTU_VERSION}-${KVER}.${KMAJ}.0"
	fi
	return ${ret_val}
}

function get_media_build()
{
	cd ${TOP_DEVDIR}
	if [ -z "${1}" ]; then
		TARGET_DIR=media_build
	else
		TARGET_DIR=${1}
	fi
	if [ ! -d "${TARGET_DIR}" ] ; then
		git clone git://linuxtv.org/media_build.git ${TARGET_DIR}
	else
		cd ${TARGET_DIR}
		git pull
		cd ..
	fi
}

function download_media_tree()
{
	cd ${TOP_DEVDIR}/media_build
	git pull

	git clean -xdf linux/
	git checkout linux/
	make -C linux/ download

	# UTC time marker for LinuxTV media tree sync
	export V4L_SYNC_DATE=`date -u +%Y-%0m-%0d-%0k:%0M`
	echo ${V4L_SYNC_DATE} > ${TOP_DEVDIR}/.flag-media-tree-sync-time
}

function gen_media_tree_tarball()
{
	cd ${TOP_DEVDIR}/media_build

	make -C linux/ untar
	chmod +x v4l/scripts/make_config_compat.pl

	cd linux
	../v4l/scripts/make_config_compat.pl ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}/ ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}/debian.master/config/config.common.ubuntu config-compat.h

	./version_patch.pl

	for i in `./patches_for_kernel.pl ${KVER}.${KMAJ}.0` ; do patch -p1 < ../backports/$i; done;

	sed -ie 's/NEED_USB_SPEED_WIRELESS/xxx_disabled_NEED_USB_SPEED_WIRELESS/' config-compat.h
	cp -av kernel_version.h include/linux
	cp -av config-compat.h include/media
	cp -v ../v4l/compat.h include/media

	tar -czvf ${TOP_DEVDIR}/linux-media-tree-${V4L_SYNC_DATE}.tgz drivers firmware include sound
}

function reset_repo_head_hard()
{
	cd ${TOP_DEVDIR}
	if [ -z "${1}" -o ! -d "${1}" ]; then
		TARGET_DIR=ubuntu-${UBUNTU_VERSION}
	else
		TARGET_DIR=${1}
	fi

	[ ! -d "${TARGET_DIR}" ] && return 2
	echo "WARNING: reset to HEAD^ *and* irreversibly clear ${TARGET_DIR}?  YES/NO"
	read x
	if [ "$x" == "YES" ] ; then
		cd ${TARGET_DIR}
		git fetch
		git reset --hard HEAD^
		git clean -xdf
		return 0
	else
		return 1
	fi
}

function reset_ubuntu_hard()
{
	cd ${TOP_DEVDIR}
	if [ -z "${1}" -o ! -d "${1}" ]; then
		TARGET_DIR=ubuntu-${UBUNTU_VERSION}
	else
		TARGET_DIR=${1}
	fi

	[ ! -d "${TARGET_DIR}" ] && return 2
	if [ -z "${UBUNTU_REVISION}" ] ; then
		echo "UBUNTU_REVISION cannot be empty!"
		return 3
	fi

	echo "WARNING: reset to rev ${UBUNTU_REVISION} *and* irreversibly clear ${TARGET_DIR}?  YES/NO"
	read x
	if [ "${x}" == "YES" ] ; then
		cd ${TARGET_DIR}
		git fetch
		git reset --hard ${UBUNTU_REVISION}
		git clean -xdf
		return 0
	else
		return 1
	fi
}

function apply_media_tree()
{
	cd ${TOP_DEVDIR}
	if [ -z "${1}" ]; then
		TARGET_DIR=ubuntu-${UBUNTU_VERSION}
	else
		TARGET_DIR=${1}
	fi

	cd ${TARGET_DIR}
	if [ -z "${V4L_SYNC_DATE}" -o ! -f "${TOP_DEVDIR}/linux-media-tree-${V4L_SYNC_DATE}.tgz" ] ; then
		LinuxTV_MT_TAR=`ls ${TOP_DEVDIR}/linux-media-tree-*.tgz | sort | tail -n 1`
		if [ -z "${LinuxTV_MT_TAR}" ] ; then
			return 1
		fi
		echo "################# $LinuxTV_MT_TAR"
		TMP_MT_DATE="`basename ${LinuxTV_MT_TAR}`"
		echo "################# $TMP_MT_DATE"
		TMP_MT_DATE="${TMP_MT_DATE#linux-media-tree-}"
		echo "################# $TMP_MT_DATE"
		export V4L_SYNC_DATE="${TMP_MT_DATE%.tgz}"
		echo "################# $V4L_SYNC_DATE"
	else
		LinuxTV_MT_TAR="${TOP_DEVDIR}/linux-media-tree-${V4L_SYNC_DATE}.tgz"
	fi

	tar -xzvf ${LinuxTV_MT_TAR}
#	export V4L_SYNC_DATE="${V4L_SYNC_DATE}"

	# dma-buf api changes < 4.10
	if [ "${KVER}" -le 4 -a "${KMAJ}" -lt 10 ] ; then
		git checkout include/linux/dma-buf.h
	fi

	git add --all
	git commit -m "Linuxtv.org media tree sync - ${V4L_SYNC_DATE}"
	git format-patch -o ../ -1 HEAD
	reset_repo_head_hard ${TARGET_DIR}
}

function configure_repo_git()
{
	cd ${TOP_DEVDIR}
	if [ -z "${1}" ]; then
		TARGET_DIR=ubuntu-${UBUNTU_VERSION}
	else
		TARGET_DIR=${1}
	fi

	[ ! -d "${TARGET_DIR}" ] && echo "configure_repo_git fail" && return 1

	cd ${TARGET_DIR}

	# set local Ubuntu kernel repo git config
	git config user.name "${U_FULLNAME}"
	git config user.email "hidden@email.co"
}

function apply_patch()
{
	if [ -z "${1}" -o ! -f "${1}" ] ; then
		echo "Error..."
		return 1
	fi

	patch -p1 < $1
	if [ $? != 0 ] ; then
		return 1
	fi
	return 0
}

function apply_patch_git_am()
{
	if [ -z "${1}" -o ! -f "${1}" ] ; then
		echo "Error..."
		return 1
	fi

	git am --reject $1
	if [ $? != 0 ] ; then
		echo "You must manually fix a conflict, and then mark complete with:"
		echo "    git am --continue"
		return 1
	fi
	return 0
}

function apply_patches()
{
	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}

	###################################################
	########## Pure LinuxTV.org media tree ############
	if [ -z "${V4L_SYNC_DATE}" -o ! -f "${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-${V4L_SYNC_DATE}.patch" ] ; then
		LinuxTV_MT_PATCH=`ls ${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-*.patch | sort | tail -n 1`
		if [ -z "${LinuxTV_MT_PATCH}" ] ; then
			echo "Missing Linuxtv.org-media-tree patch"
			return 1
		fi
	else
		LinuxTV_MT_PATCH="${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-${V4L_SYNC_DATE}.patch"
	fi
	apply_patch_git_am ${LinuxTV_MT_PATCH}
	[ $? != 0 ] && echo "patch failure, exiting" && return 1

	###################################################
	############# media tree build fixes ##############
	apply_patch_git_am ${KB_PATCH_DIR}/0002-Apply-build-fixes-to-media-tree.patch
	[ $? != 0 ] && echo "patch failure, exiting" && return 1

	###################################################
	######### 'New' LinuxTV kernel options ############
	apply_patch_git_am ${KB_PATCH_DIR}/0003-Add-new-media-tree-kernel-config.patch
	[ $? != 0 ] && echo "patch failure, exiting" && return 1

	###################################################
	########## Ubuntu mainline build fixes ############
	apply_patch_git_am ${KB_PATCH_DIR}/0004-Mainline-Ubuntu-build-fixes.patch
	[ $? != 0 ] && echo "patch failure, exiting" && return 1

	###################################################
	########### Ubuntu packaging patches ##############
	apply_patch_git_am ${KB_PATCH_DIR}/0005-Packaging-updates.patch
	[ $? != 0 ] && echo "patch failure, exiting" && return 1

	###################################################
	########## Add build system changelog #############
	if [ "${UPDATE_MT_KBUILD_VER}" == "YES" ] ; then
		regen_changelog "`date +%Y%m%d%H%M`"
		git add debian.master/changelog
		git commit -m 'Changelog'

		update_identity

		unset UPDATE_MT_KBUILD_VER
	else
		apply_patch_git_am ${KB_PATCH_DIR}/0006-Changelog.patch
		[ $? != 0 ] && echo "patch failure, exiting 2" && exit 1
	fi
#		apply_patch_git_am ../env-var-to-control-custom-tag-for-packaging.patch

	return 0
}

function apply_extra_patches()
{
	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}

	for i in `ls ${KB_PATCH_DIR}/extra/* | sort` ; do
		apply_patch_git_am $i
		[ $? != 0 ] && echo "patch [${i}] failure, exiting" && return 1
	done

	return 0
}

function generate_patch_set()
{
	if [ -z "${UBUNTU_REVISION}" ] ; then
		echo "UBUNTU_REVISION cannot be empty!"
		return 3
	fi

	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}

	#	git format-patch -# HEAD
	# Generate all patches after checkout revision
	git format-patch ${UBUNTU_REVISION}
}

function update_identity()
{
	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}

	sed -i "s/Fake User <hidden@email.co>/${U_FULLNAME} <${U_EMAIL}>/" debian.master/control.stub.in
	sed -i "s/Fake User <hidden@email.co>/${U_FULLNAME} <${U_EMAIL}>/" debian.master/changelog
}

function regen_changelog()
{
	if [ -z "${UBUNTU_REVISION}" ] ; then
		echo "UBUNTU_REVISION cannot be empty!"
		return 3
	fi

	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}

	[ -z "${1}" ] && echo "error..." && return 1

	git checkout ${UBUNTU_REVISION} debian.master/changelog
	get_ubuntu_kver

	cp debian.master/changelog /tmp/tmpkrn_changelog.orig

	# old version check
	if [ "${1}" == "${K_BUILD_VER}" ]; then
		export K_ABI_MOD=$(( ${K_ABI_MOD} + 1 ))
	else
		export K_BUILD_VER=${1}
		export K_ABI_MOD=0
	fi

	K_BUILD_TIME=`date -R`

	echo "linux (${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${K_BUILD_VER}.${K_ABI_MOD}${KERNEL_ABI_TAG}) ${UBUNTU_VERSION}; urgency=low" > /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod
	echo "  * Ubuntu kernel git clone">>  /tmp/tmpkrn_changelog.mod
	echo "    - ${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}.${K_ABI_B} rev ${UBUNTU_REVISION}">>  /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod

	echo "  * LinuxTV.org media tree slipstream + build fixes" >>  /tmp/tmpkrn_changelog.mod
	if [ -z "${V4L_SYNC_DATE}" -o ! -f "${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-${V4L_SYNC_DATE}.patch" ] ; then
		LinuxTV_MT_PATCH=`ls ${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-*.patch | sort | tail -n 1`
		if [ -z "${LinuxTV_MT_PATCH}" ] ; then
			echo "Missing Linuxtv.org-media-tree patch"
			return 1
		fi
	else
		LinuxTV_MT_PATCH="${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-${V4L_SYNC_DATE}.patch"
	fi
	echo "    - `basename ${LinuxTV_MT_PATCH}`" >>  /tmp/tmpkrn_changelog.mod
	echo "    - 0002-Apply-build-fixes-to-media-tree.patch" >>  /tmp/tmpkrn_changelog.mod
	echo "    - 0003-Add-new-media-tree-kernel-config.patch" >>  /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod

	echo "  * Ubuntu mainline build fixes" >>  /tmp/tmpkrn_changelog.mod
	echo "    - 0004-Mainline-Ubuntu-build-fixes.patch" >>  /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod

	echo "  * Packaging patches" >>  /tmp/tmpkrn_changelog.mod
	echo "    - 0005-Packaging-updates.patch" >>  /tmp/tmpkrn_changelog.mod
	echo "    - 0006-Changelog.patch" >>  /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod

	echo "  * Additional patches" >>  /tmp/tmpkrn_changelog.mod
	for i in `ls ${KB_PATCH_DIR}/extra/* | sort` ; do
		echo "    - `basename $i`" >>  /tmp/tmpkrn_changelog.mod
	done
	echo "" >>  /tmp/tmpkrn_changelog.mod

	echo " -- Fake User <hidden@email.co>  ${K_BUILD_TIME}" >>  /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod

	cat /tmp/tmpkrn_changelog.mod /tmp/tmpkrn_changelog.orig > debian.master/changelog

	write_state_env
}

function clean_kernel()
{
	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}
	fakeroot debian/rules clean
	return 0
}

function generate_new_kernel_version()
{
	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}

	regen_changelog "`date +%Y%m%d%H%M`"
	update_identity

	fakeroot debian/rules clean

	return 0
}

function generate_virtual_package()
{
	cd ${TOP_DEVDIR}

	if [ ! -f "ubuntu-${UBUNTU_VERSION}/debian/changelog" ] ; then
		echo "Error, you must 'clean'/regenerate build data first"
		return 1
	fi

	LAST_KBUILD_VER=`head -n 1 ubuntu-${UBUNTU_VERSION}/debian/changelog | egrep -o '201[7-9][[:digit:]]{8}'`

	VPACKAGE_VER=`head -n 1 changelog`
	cd .vpackage_tmp
	rm -rf linux-*-mediatree-*/
	rm -f *
        VP_BUILD_TIME=`date -R`

	if [ "${1}" == "image" -o "${1}" == "headers" ] ; then
		cp ../linux-${1}-mediatree.control ./ns_control
		echo "linux-${1}-mediatree (${VPACKAGE_VER}+${UBUNTU_VERSION}) ${UBUNTU_VERSION}; urgency=low" > changelog
		git log --pretty=format:"  * %h %s" -n 13 >> changelog
		echo "" >> changelog
		echo "" >> changelog
		echo " -- ${U_FULLNAME} <${U_EMAIL}>  ${VP_BUILD_TIME}" >> changelog
		echo "" >> changelog
		cat ../changelog >> changelog
	else
		return 1
	fi

	sed -i "s/__MAINTAINER_INFO__/${U_FULLNAME} <${U_EMAIL}>/" ns_control
	sed -i "s/__LINUX_HEADER_PACKAGE__/linux-headers-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic/" ns_control
	sed -i "s/__LINUX_IMAGE_PACKAGES__/linux-image-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic, linux-image-extra-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic/" ns_control
	echo "Building virtual package that depends on:"
	if [ "${1}" == "headers" ] ; then
		echo "    linux-headers-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic"
	else
		echo "    linux-image-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic"
		echo "    linux-image-extra-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic"
	fi
	equivs-build --full ns_control
	if [ ! -f "linux-${1}-mediatree_${VPACKAGE_VER}+${UBUNTU_VERSION}.dsc" ] ; then
		echo "Missing linux-${1}-mediatree_${VPACKAGE_VER}+${UBUNTU_VERSION}.dsc"
		return 1
	fi
	dpkg-source -x linux-${1}-mediatree_${VPACKAGE_VER}+${UBUNTU_VERSION}.dsc
	[ $? -ne 0 ] && return 1
	cd linux-${1}-mediatree-${VPACKAGE_VER}+${UBUNTU_VERSION}
	debuild -us -uc -S
	cd ..
	cp linux-${1}-mediatree*.tar.gz ..
	cp linux-${1}-mediatree*.dsc ..
	cp linux-${1}-mediatree*_source.changes ..

	return 0
}

function build_kernel_bin()
{
	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}

	if [ "$1" == "debug" ] ; then
		time fakeroot debian/rules binary-headers binary-generic binary-perarch skipdbg=false
			#skipmodule=true skipabi=true
	elif [ "$1" == "full" ] ; then
		time fakeroot debian/rules binary
	else
		time fakeroot debian/rules binary-headers binary-generic binary-perarch
			#skipmodule=true skipabi=true
	fi
}

function generate_ppa_data()
{
	echo "This should only be executed in a completely clean state"
	echo "For example, after:"
	echo "   ./mediatree.sh -r -p -x -c"
	echo "Continue?"
	read x
	[ "${x}" != "YES" ] && return 1

	cd ${TOP_DEVDIR}/ubuntu-${UBUNTU_VERSION}
	debuild -us -uc -S

	generate_virtual_package image
	generate_virtual_package headers
}

function init_mediatree_builder()
{
	ret_val=0

	# Saves time by keeping clean local master (also takes up space)
	cd ${TOP_DEVDIR}
	if [ "${MEDIATREE_KBUILD_USE_CLEAN_MASTER}" == "1" ] ; then
		echo "Initializing/Updating clean master repo"
		get_ubuntu .clean-master-repo
		ret_val=${?}
		echo ""
	fi

	cd ${TOP_DEVDIR}
	echo "Initializing/Updating clean patch gen repo"
	get_ubuntu .media-tree-clean-patch-repo
	configure_repo_git .media-tree-clean-patch-repo
	echo ""

	cd ${TOP_DEVDIR}
	if [ ! -d "ubuntu-${UBUNTU_VERSION}" ] ; then
		echo "Initializing Ubuntu work repo"
		get_ubuntu
		configure_repo_git
		echo ""
	elif [ "${TRY_UPDATE}" == "YES" ] ; then
		echo "Attempting to update Ubuntu work repo (should already be reset with -r)"
		get_ubuntu
		echo ""
	fi

	cd ${TOP_DEVDIR}
	echo "Initializing/Updating media_build system"
	get_media_build
	echo ""
	return ${ret_val}
}

function usage()
{
	echo "Usage:"
	echo "  ${0} [-i|-m|-s|-p|-x|-c|-r|-g|-b|-h]"
	echo "    -i  :  Initialize/update all git repositories"
	echo "    -m  :  Download and generate latest backport-patched LinuxTV.org media tree tarball"
	echo "    -s  :  Generate a vanilla media tree kernel patch from a tarball"
	echo "    -p  :  Apply mediatree kbuild system patches"
	echo "    -x  :  Apply extra patches"
	echo "    -c  :  Make new kernel build data and clean build system"
	echo "    -r  :  Hard reset build directory (wipes build dir clean!)"
	echo "    -g  :  Generate full patchset since original revision"
	echo "    -b  :  Build kernel (requires clean first unless build error)"
	echo "    -h  :  This help"
	echo ""
}

if [ -z "$1" ]; then
	usage
	exit 0
fi

# patch makefile to turn these on by default !
#  skipmodule=true skipabi=true

while getopts ":imrxCcgbB:spV:" o; do
	case "${o}" in
	i)
		init_mediatree_builder
		[ $? != 0 ] && exit 133
		;;
	m)
		## App operation: get latest drivers and make patched tarball for a particular kernel
		#
		init_mediatree_builder
		download_media_tree
		gen_media_tree_tarball
		;;
	s)
		## App operation: Make a patch with the latest tarball applied
		init_mediatree_builder
		apply_media_tree .media-tree-clean-patch-repo
		;;
	r)
		## App operation: Reset to original commit main ubuntu build directory
		#
		# resets Ubuntu git back to original commit package is based on
		# suitable for re applying updated patchset
		# WARNING: irreversibly wipes out all files and resets to original state!!!
		echo "!!! Requesting hard reset of ubuntu-${UBUNTU_VERSION}"
		echo "!!!  This will irrerversibly wipe out the entire directory and restore it to original state"
		echo "!!!  Any changes you have made will be lost."
		reset_ubuntu_hard
		;;
	p)
		## App operation: Apply all patches to main ubuntu build directory
		#
		# requires main ubuntu build repo reset
		#
		apply_patches
		[ $? != 0 ] && exit 1
		;;
	x)
		## App operation: Apply all extra patches to main ubuntu build directory
		#
		apply_extra_patches
		[ $? != 0 ] && exit 1
		;;
	c)
		## App operation: Update changelog with ABI, build tag, maintainer, and patch list
		generate_new_kernel_version
		[ $? != 0 ] && exit 1
		;;
	C)
		## App operation: clean kernel
		clean_kernel
		[ $? != 0 ] && exit 1
		;;
	g)
		## App operation: Make patch set from original commit to build this kernel
		generate_patch_set
		[ $? != 0 ] && exit 1
		;;
	b)
		## App operation: Build kernel
		#
		# Add dbg to build debug versions
		#
		build_kernel_bin
		;;
	B)
		## App operation: Build kernel either min (default), full, or dbg
		#
		if [ "${OPTARG}" != "min" -a "${OPTARG}" != "full" -a "${OPTARG}" != "debug" ] ; then
			echo "  -B [min|full|debug]"
			exit 1
		fi
		build_kernel_bin ${OPTARG}
		;;
	V)
		## App operation: build PPA decriptors
		if [ "${OPTARG}" == "all" ] ; then
			generate_ppa_data
		fi
#		generate_virtual_package ${OPTARG}
		;;
	h|*)
		usage
		;;
	esac
done
shift $((OPTIND-1))

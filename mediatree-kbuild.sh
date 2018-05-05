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

if [ -z "${DISTRO_NAME}" ] ; then
	if [ ! -f /etc/os-release ] ; then
		echo "No /etc/os-release, cannot determine running OS..."
		exit 250
	fi
	eval `cat /etc/os-release`
	DISTRO_NAME=${ID}
fi

if [ -z "${DISTRO_CODENAME}" ] ; then
	if [ ! -f /etc/os-release ] ; then
		echo "No /etc/os-release, cannot determine running OS..."
		exit 250
	fi
	eval `cat /etc/os-release`
	DISTRO_CODENAME=${VERSION_CODENAME}
fi

#[ -z "${DISTRO_GIT_REVISION}" ] && DISTRO_GIT_REVISION=50aaaec159365f8f8788e054048545e7ec9734f1

################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
TRY_UPDATE=NO
TIP_UBUNTU_VERSION=

export TOP_DEVDIR=`pwd`

if [ -f ".state_env_file" ] ; then
	. .state_env_file
	export KB_PATCH_DIR="${TOP_DEVDIR}/patches/${DISTRO_NAME}-${DISTRO_CODENAME}-${KVER}.${KMAJ}.0"
fi

## Set env var V4L_SYNC_DATE to a specific date to override latest tarball
if [ -z "${V4L_SYNC_DATE}" -a -f "${TOP_DEVDIR}/.flag-media-tree-sync-time" ]; then
	export V4L_SYNC_DATE=`cat ${TOP_DEVDIR}/.flag-media-tree-sync-time`
fi

function get_ubuntu_kver()
{
	export KVER=`grep VERSION ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}/Makefile | head -n 1 | cut -d ' ' -f 3`
	export KMAJ=`grep PATCHLEVEL ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}/Makefile | head -n 1 | cut -d ' ' -f 3`
	export KMIN=0
	export K_ABI_A=`head -n1 ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}/debian.master/changelog | cut -d'-' -f2 | cut -d'.' -f1`
	export K_ABI_B=`head -n1 ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}/debian.master/changelog | cut -d'.' -f4 | cut -d')' -f1`
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
	echo "DISTRO_GIT_REVISION=${DISTRO_GIT_REVISION}" >> ${TOP_DEVDIR}/.state_env_file
	echo "" >> ${TOP_DEVDIR}/.state_env_file
}

function get_ubuntu()
{
	ret_val=0
	cd ${TOP_DEVDIR}
	if [ -z "${1}" ]; then
		TARGET_DIR=${DISTRO_NAME}-${DISTRO_CODENAME}
	else
		TARGET_DIR=${1}
	fi
	if [ ! -d "${TARGET_DIR}" -a -d ".clean-master-repo" ] ; then
		cd .clean-master-repo
		git pull
		cd -
		git clone ${TOP_DEVDIR}/.clean-master-repo ${TARGET_DIR}
	elif [ ! -d "${TARGET_DIR}" ] ; then
		git clone git://kernel.ubuntu.com/ubuntu/${DISTRO_NAME}-${DISTRO_CODENAME}.git ${TARGET_DIR}
	fi

	if [ -n "${DISTRO_GIT_REVISION}" -a "${TARGET_DIR}" != ".clean-master-repo" ] ; then
		cd ${TARGET_DIR}
		git fetch
		if [ -n "${TIP_DISTRO_GIT_REVISION}" -a "${TIP_DISTRO_GIT_REVISION}" != "${DISTRO_GIT_REVISION}" ] ; then
			git checkout ${TIP_DISTRO_GIT_REVISION}
			[ -z "${1}" ] && DISTRO_GIT_REVISION=${TIP_DISTRO_GIT_REVISION}
		else
			git checkout ${DISTRO_GIT_REVISION}
		fi
		cd ..
	else
		cd ${TARGET_DIR}
		git pull
		CUR_DISTRO_GIT_REVISION=`cat .git/refs/heads/master`
		if [ -n "${DISTRO_GIT_REVISION}" -a "${CUR_DISTRO_GIT_REVISION}" != "${DISTRO_GIT_REVISION}" ] ; then
			echo -e "${RED}###############################################"
			echo -e "${RED}###############################################"
			echo -e "${RED}###############################################"
			echo -e "${RED}################### ${GREEN}ATTENTION ${RED}#################"
			echo -e "${RED}####### ${GREEN}Ubuntu master revision updated! ${RED}#######"
			echo -e "${RED}## ${NC}${CUR_DISTRO_GIT_REVISION} ${RED}###"
			echo -e "${RED}###############################################"
			echo -e "${RED}### ${NC}Set env var MEDIATREE_KBUILD_UPDATE=YES ${RED}###"
			echo -e "${RED}############# ${NC}to update build ${RED}#################"
			echo -e "${RED}###############################################${NC}"
			ret_val=1
			if [ "${MEDIATREE_KBUILD_UPDATE}" == "YES" ] ; then
				TIP_DISTRO_GIT_REVISION=${CUR_DISTRO_GIT_REVISION}
				TRY_UPDATE=YES
			fi
		elif [ -z "${1}" ] ; then
			DISTRO_GIT_REVISION=${CUR_DISTRO_GIT_REVISION}
		fi
	fi

	if [ -z "${1}" ] ; then
		get_ubuntu_kver
		write_state_env
		export KB_PATCH_DIR="${TOP_DEVDIR}/patches/${DISTRO_NAME}-${DISTRO_CODENAME}-${KVER}.${KMAJ}.0"
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

	git clean -xdf linux/
	git checkout linux/
	git pull

	make -C linux/ download

	# UTC time marker for LinuxTV media tree sync
	export V4L_SYNC_DATE=`date -u +%Y-%0m-%0d-%0k-%0M`
	echo ${V4L_SYNC_DATE} > ${TOP_DEVDIR}/.flag-media-tree-sync-time

	# generate unpatched tarball of currentlinuxtv.org media tree
	make -C linux/ untar
	cd linux
	# v4l2 version define, generated by make command
	cp -av kernel_version.h include/linux
	tar -czf ${TOP_DEVDIR}/linux-media-tree-${V4L_SYNC_DATE}.tgz drivers include sound
}

function unpack_media_tree()
{
	cd ${TOP_DEVDIR}/media_build

	git clean -xdf linux/
	git checkout linux/
	cd linux

	if [ -f "${TOP_DEVDIR}/linux-media-tree-${V4L_SYNC_DATE}.tgz" ] ; then
		echo "############################################################"
		echo "############################################################"
		echo "######### Unpacking linux-media-tree-${V4L_SYNC_DATE}.tgz"
		tar -xzf ${TOP_DEVDIR}/linux-media-tree-${V4L_SYNC_DATE}.tgz
		echo "############################################################"
		echo "############################################################"
		return 0
	else
		echo "${TOP_DEVDIR}/linux-media-tree-${V4L_SYNC_DATE}.tgz not found"
	fi
	return 1
}

function gen_media_tree_tarball_patched()
{
	cd ${TOP_DEVDIR}/media_build
	cd linux

	# linuxtv media tree syslog messages and config-compat.h generation
	perl ../v4l/scripts/make_config_compat.pl ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}/ ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}/debian.master/config/config.common.ubuntu config-compat.h
	perl ./version_patch.pl

	# apply kernel version specific backport patches
	for i in `./patches_for_kernel.pl ${KVER}.${KMAJ}.0` ; do patch -p1 < ../backports/$i; done;

	# copy includes where we need them for integration
	sed -ie 's/NEED_USB_SPEED_WIRELESS/xxx_disabled_NEED_USB_SPEED_WIRELESS/' config-compat.h
	cp -av config-compat.h include/media
	cp -v ../v4l/compat.h include/media

	# tar up fully kernel specific patched media tree tarball
	tar -czf ${TOP_DEVDIR}/linux-media-tree-${KVER}.${KMAJ}.${KMIN}-${V4L_SYNC_DATE}.tgz drivers include sound
}

function reset_repo_head_hard()
{
	cd ${TOP_DEVDIR}
	if [ -z "${1}" -o ! -d "${1}" ]; then
		TARGET_DIR=${DISTRO_NAME}-${DISTRO_CODENAME}
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

function reset_repo_revision_hard()
{
	cd ${TOP_DEVDIR}
	if [ -z "${1}" -o ! -d "${1}" ]; then
		TARGET_DIR=${DISTRO_NAME}-${DISTRO_CODENAME}
	else
		TARGET_DIR=${1}
	fi

	[ ! -d "${TARGET_DIR}" ] && return 2
	if [ -z "${DISTRO_GIT_REVISION}" ] ; then
		echo "DISTRO_GIT_REVISION cannot be empty!"
		return 3
	fi

	echo "WARNING: reset to rev ${DISTRO_GIT_REVISION} *and* irreversibly clear ${TARGET_DIR}?  YES/NO"
	read x
	if [ "${x}" == "YES" ] ; then
		cd ${TARGET_DIR}
		git fetch
		git reset --hard ${DISTRO_GIT_REVISION}
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
		TARGET_DIR=${DISTRO_NAME}-${DISTRO_CODENAME}
	else
		TARGET_DIR=${1}
	fi

	cd ${TARGET_DIR}
	if [ -z "${V4L_SYNC_DATE}" -o ! -f "${TOP_DEVDIR}/linux-media-tree-${KVER}.${KMAJ}.${KMIN}-${V4L_SYNC_DATE}.tgz" ] ; then
		LinuxTV_MT_TAR=`ls ${TOP_DEVDIR}/linux-media-tree-${KVER}.${KMAJ}.${KMIN}-*.tgz | sort | tail -n 1`
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
		LinuxTV_MT_TAR="${TOP_DEVDIR}/linux-media-tree-${KVER}.${KMAJ}.${KMIN}-${V4L_SYNC_DATE}.tgz"
	fi

	tar -xzf ${LinuxTV_MT_TAR}
#	export V4L_SYNC_DATE="${V4L_SYNC_DATE}"

	# dma-buf struct changes < 4.12
	if [ "${KVER}" -le 4 -a "${KMAJ}" -lt 12 ] ; then
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
		TARGET_DIR=${DISTRO_NAME}-${DISTRO_CODENAME}
	else
		TARGET_DIR=${1}
	fi

	[ ! -d "${TARGET_DIR}" ] && echo "configure_repo_git fail" && return 1

	cd ${TARGET_DIR}

	# set local repo git config
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
	if [ -z "${1}" ] ; then
		echo "Error 1..."
		return 1
	fi
	if [ -z "${2}" ] ; then
		echo "Error 2..."
		return 1
	fi

	if [ -d "${2}" ] ; then
		git am --reject ${2}/*patch
	else
		git am --reject ${2}
	fi
	if [ $? != 0 ] ; then
		if [ "$1" == "1" ] ; then
			echo "Patch failure: ${2}"
			echo "    Aborting git am"
			git am --abort
		else
			echo "You must manually fix a conflict, and then mark complete with:"
			echo "    git am --continue"
		fi
		return 1
	fi
	return 0
}

function apply_patches()
{
	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}

	###################################################
	########## Pure LinuxTV.org media tree ############
	echo "#############################################################"
	if [ -z "${V4L_SYNC_DATE}" -o ! -f "${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-sync-${V4L_SYNC_DATE}.patch" ] ; then
		LinuxTV_MT_PATCH=`ls ${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-*.patch | sort | tail -n 1`
		if [ -z "${LinuxTV_MT_PATCH}" ] ; then
			echo "Missing Linuxtv.org-media-tree patch"
			return 1
		fi
	else
		LinuxTV_MT_PATCH="${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-sync-${V4L_SYNC_DATE}.patch"
	fi
	apply_patch_git_am 1 ${LinuxTV_MT_PATCH}
	[ $? != 0 ] && echo "patch failure, exiting" && return 1

	###################################################
	########## Add build system changelog #############
	echo "#############################################################"
	if [ "${UPDATE_MT_KBUILD_VER}" == "YES" ] ; then
		regen_changelog "`date +%Y%m%d%H%M`"
		git add debian.master/changelog
		git commit -m 'Changelog'
		unset UPDATE_MT_KBUILD_VER
	else
		apply_patch_git_am 1 ${KB_PATCH_DIR}/0002-Changelog.patch
		if [ $? != 0 ] ; then
			echo "Changelog patch failure, regenerating..."
			regen_changelog "`date +%Y%m%d%H%M`"
			git add debian.master/changelog
			git commit -m 'Changelog'
		fi
	fi
	update_identity

	for i in ${KB_PATCH_DIR}/000[3456789]*patch ; do
		echo "#############################################################"
		apply_patch_git_am 1 "$i"
		[ $? != 0 ] && echo "patch failure, exiting" && return 1
	done

	return 0
}

function apply_extra_patches()
{
	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}

	for i in `ls -d ${KB_PATCH_DIR}/../mainline-extra/${KVER}.${KMAJ}.0/* | sort` ; do
		echo "#############################################################"
		echo "#############################################################"
		echo "### `basename $i` ###"
		echo "#############################################################"
		apply_patch_git_am 1 $i
		[ $? != 0 ] && echo "patch [${i}] failure, exiting" && return 1
	done

	return 0
}

function generate_patch_set()
{
	if [ -z "${DISTRO_GIT_REVISION}" ] ; then
		echo "DISTRO_GIT_REVISION cannot be empty!"
		return 3
	fi

	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}

	#	git format-patch -# HEAD
	# Generate all patches after checkout revision
	git format-patch ${DISTRO_GIT_REVISION}
}

function update_identity()
{
	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}

	sed -i "s/Fake User <hidden@email.co>/${U_FULLNAME} <${U_EMAIL}>/" debian.master/control.stub.in
	sed -i "s/Fake User <hidden@email.co>/${U_FULLNAME} <${U_EMAIL}>/" debian.master/changelog
}

function regen_changelog()
{
	if [ -z "${DISTRO_GIT_REVISION}" ] ; then
		echo "DISTRO_GIT_REVISION cannot be empty!"
		return 3
	fi

	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}

	[ -z "${1}" ] && echo "error..." && return 1

	git checkout ${DISTRO_GIT_REVISION} debian.master/changelog
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

	echo "linux (${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${K_BUILD_VER}.${K_ABI_MOD}${KERNEL_ABI_TAG}) ${DISTRO_CODENAME}; urgency=low" > /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod
	echo "  * Ubuntu kernel git clone">>  /tmp/tmpkrn_changelog.mod
	echo "    - ${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}.${K_ABI_B} rev ${DISTRO_GIT_REVISION}">>  /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod

	echo "  * LinuxTV.org media tree slipstream + build fixes" >>  /tmp/tmpkrn_changelog.mod
	if [ -z "${V4L_SYNC_DATE}" -o ! -f "${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-sync-${V4L_SYNC_DATE}.patch" ] ; then
		LinuxTV_MT_PATCH=`ls ${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-*.patch | sort | tail -n 1`
		if [ -z "${LinuxTV_MT_PATCH}" ] ; then
			echo "Missing Linuxtv.org-media-tree patch"
			return 1
		fi
	else
		LinuxTV_MT_PATCH="${KB_PATCH_DIR}/0001-Linuxtv.org-media-tree-sync-${V4L_SYNC_DATE}.patch"
	fi
	echo "    - `basename ${LinuxTV_MT_PATCH}`" >>  /tmp/tmpkrn_changelog.mod
	echo "    - 0002-Changelog.patch" >>  /tmp/tmpkrn_changelog.mod

	for i in `ls ${KB_PATCH_DIR}/000[3456789]*.patch | sort` ; do
		echo "    - `basename $i`" >>  /tmp/tmpkrn_changelog.mod
	done
	echo "" >>  /tmp/tmpkrn_changelog.mod

	echo "  * Additional patches" >>  /tmp/tmpkrn_changelog.mod

	for i in `ls -d ${KB_PATCH_DIR}/../mainline-extra/${KVER}.${KMAJ}.0/*/ | sort` ; do
		echo "    - `basename $i`" >>  /tmp/tmpkrn_changelog.mod
		for j in `ls $i/*.patch | sort` ; do
			echo "    --- `basename $j`" >>  /tmp/tmpkrn_changelog.mod
		done
	done
	echo "" >>  /tmp/tmpkrn_changelog.mod

	echo " -- Fake User <hidden@email.co>  ${K_BUILD_TIME}" >>  /tmp/tmpkrn_changelog.mod
	echo "" >>  /tmp/tmpkrn_changelog.mod

	cat /tmp/tmpkrn_changelog.mod /tmp/tmpkrn_changelog.orig > debian.master/changelog

	write_state_env
}

function clean_kernel()
{
	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}

	fakeroot debian/rules clean

	return 0
}

function generate_new_kernel_version()
{
	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}

	regen_changelog "`date +%Y%m%d%H%M`"
	update_identity

	clean_kernel

	return 0
}

function generate_virtual_package()
{
	cd ${TOP_DEVDIR}

	if [ ! -f "${DISTRO_NAME}-${DISTRO_CODENAME}/debian/changelog" ] ; then
		echo "Error, you must 'clean'/regenerate build data first"
		return 1
	fi

	LAST_KBUILD_VER=`head -n 1 ${DISTRO_NAME}-${DISTRO_CODENAME}/debian/changelog | egrep -o '201[7-9][[:digit:]]{8}'`

	VPACKAGE_VER=`head -n 1 changelog`
	cd .vpackage_tmp
	rm -rf linux-*-mediatree-*/
	rm -f *
	VP_BUILD_TIME=`date -R`

	if [ "${1}" == "image" -o "${1}" == "headers" ] ; then
		cp ../linux-${1}-mediatree.control ./ns_control
		echo "linux-${1}-mediatree (${VPACKAGE_VER}+${DISTRO_CODENAME}) ${DISTRO_CODENAME}; urgency=low" > changelog
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
	echo "#########################################"
	echo "#########################################"
	echo "Building virtual package that depends on:"
	if [ "${1}" == "headers" ] ; then
		echo "    linux-headers-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic"
	else
		echo "    linux-image-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic"
		echo "    linux-image-extra-${KVER}.${KMAJ}.${KMIN}-${K_ABI_A}${LAST_KBUILD_VER}-generic"
	fi
	echo "#########################################"
	echo "#########################################"
	equivs-build --full ns_control
	if [ ! -f "linux-${1}-mediatree_${VPACKAGE_VER}+${DISTRO_CODENAME}.dsc" ] ; then
		echo "Missing linux-${1}-mediatree_${VPACKAGE_VER}+${DISTRO_CODENAME}.dsc"
		return 1
	fi
	dpkg-source -x linux-${1}-mediatree_${VPACKAGE_VER}+${DISTRO_CODENAME}.dsc
	[ $? -ne 0 ] && return 1
	cd linux-${1}-mediatree-${VPACKAGE_VER}+${DISTRO_CODENAME}
	debuild -us -uc -S
	cd ..
	cp linux-${1}-mediatree*.tar.gz ..
	cp linux-${1}-mediatree*.dsc ..
	cp linux-${1}-mediatree*_source.changes ..
	cp linux-${1}-mediatree*_source.buildinfo .. 2>/dev/null

	return 0
}

function build_kernel_bin()
{
	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}

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

	cd ${TOP_DEVDIR}/${DISTRO_NAME}-${DISTRO_CODENAME}
	debuild -d -us -uc -S

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
	if [ ! -d "${DISTRO_NAME}-${DISTRO_CODENAME}" ] ; then
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
	echo "    -m  :  Download and generate latest LinuxTV.org media tree tarballs"
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

while getopts ":imMrxCcgbB:spV:" o; do
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
		gen_media_tree_tarball_patched	# generate patched tarball
		;;
	M)
		## App operation: App operation: unpack previous linuxtv.org tarball and patch for a particular kernel
		#
		init_mediatree_builder
		unpack_media_tree
		[ $? != 0 ] && exit 1
		gen_media_tree_tarball_patched	# generate patched tarball
		;;
	s)
		## App operation: Make a patch with the latest tarball applied
		init_mediatree_builder
		apply_media_tree .media-tree-clean-patch-repo
		;;
	r)
		## App operation: Reset to original commit main kernel build directory
		#
		# resets kernel git back to original commit package is based on
		# suitable for re applying updated patchset
		# WARNING: irreversibly wipes out all files and resets to original state!!!
		echo "!!! Requesting hard reset of ${DISTRO_NAME}-${DISTRO_CODENAME}"
		echo "!!!  This will irrerversibly wipe out the entire directory and restore it to original state"
		echo "!!!  Any changes you have made will be lost."
		reset_repo_revision_hard
		;;
	p)
		## App operation: Apply all patches to main kernel build directory
		#
		# requires main kernel build repo reset
		#
		apply_patches
		[ $? != 0 ] && exit 1
		;;
	x)
		## App operation: Apply all extra patches to main kernel build directory
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

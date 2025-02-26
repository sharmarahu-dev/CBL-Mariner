#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Building the existing mariner toolchain SPEC files in built-from-scratch chroot environment
echo Building RPMs for toolchain
echo Parameters passed: $@

MARINER_DIST_TAG=$1
MARINER_BUILD_NUMBER=$2
MARINER_RELEASE_VERSION=$3
MARINER_BUILD_DIR=$4
SPECROOT=$5
RUN_CHECK=${6}
MARINER_TOOLCHAIN_MANIFESTS_DIR=$7
INCREMENTAL_TOOLCHAIN=${8:-n}
MARINER_INPUT_SRPMS_DIR=$9
MARINER_OUTPUT_SRPMS_DIR=${10}

MARINER_LOGS=$MARINER_BUILD_DIR/logs
TOOLCHAIN_LOGS=$MARINER_LOGS/toolchain
TOOLCHAIN_BUILD_LIST=$TOOLCHAIN_LOGS/build_list.txt
TOOLCHAIN_FAILURES=$TOOLCHAIN_LOGS/failures.txt
set -x

export LFS=$MARINER_BUILD_DIR/toolchain/populated_toolchain
TOPDIR=/usr/src/mariner
CHROOT_SOURCES_DIR=$LFS$TOPDIR/SOURCES
CHROOT_SPECS_DIR=$LFS$TOPDIR/SPECS
CHROOT_SRPMS_DIR=$LFS$TOPDIR/SRPMS
CHROOT_RPMS_DIR=$LFS$TOPDIR/RPMS
CHROOT_RPMS_DIR_ARCH=$CHROOT_RPMS_DIR/$(uname -m)
CHROOT_RPMS_DIR_NOARCH=$CHROOT_RPMS_DIR/noarch
CHROOT_INSTALL_RPM_DIR=$LFS$TOPDIR/PREBUILT_RPMS
CHROOT_INSTALL_RPM_DIR_IN_CHROOT=$TOPDIR/PREBUILT_RPMS
FINISHED_RPM_DIR=$MARINER_BUILD_DIR/toolchain/built_rpms
PARAM_DIST_TAG=$MARINER_DIST_TAG
PARAM_BUILD_NUM=$MARINER_BUILD_NUMBER
PARAM_RELEASE_VER=$MARINER_RELEASE_VERSION

# Assumption: pipeline has copied file: build/toolchain/toolchain_from_container.tar.gz
# Or, if toolchain-build-all was called, both of the following will exist:
#       build/toolchain/populated_toolchain
#       build/toolchain/toolchain_from_container.tar.gz
#
pushd $MARINER_BUILD_DIR/toolchain
if [[ ! -d "$LFS" ]]
then
    echo "$LFS not created yet, unpacking tarball"
    tar -xzf toolchain_from_container.tar.gz --checkpoint=100000 --checkpoint-action=echo="%T"
fi
popd

mkdir -pv $FINISHED_RPM_DIR
mkdir -pv $CHROOT_SPECS_DIR
mkdir -pv $CHROOT_SRPMS_DIR
mkdir -pv $CHROOT_SOURCES_DIR
mkdir -pv $CHROOT_INSTALL_RPM_DIR
mkdir -pv $TOOLCHAIN_LOGS
mkdir -pv $CHROOT_RPMS_DIR

sudo rm -f $TOOLCHAIN_BUILD_LIST
sudo rm -f $TOOLCHAIN_FAILURES
touch $TOOLCHAIN_FAILURES

chroot_mount () {
    trap chroot_unmount EXIT
    mount --bind /dev $LFS/dev
    mount -t devpts devpts $LFS/dev/pts -o gid=5,mode=620
    mount -t proc proc $LFS/proc
    mount -t sysfs sysfs $LFS/sys
    mount -t tmpfs tmpfs $LFS/run
}

blocking_unmount () {
    # $1 mountpoint
    umount -l $1
    while mountpoint -q $1; do
        echo $1 is still busy...
        sleep 1
        umount -l $1
    done
}

chroot_unmount () {
    echo "Unmounting chroot"
    blocking_unmount $LFS/dev/pts
    blocking_unmount $LFS/dev
    blocking_unmount $LFS/run
    blocking_unmount $LFS/proc
    blocking_unmount $LFS/sys
    trap - EXIT
}

chroot_and_print_installed_rpms () {
    chroot_mount

    echo "List of packages installed in chroot:"

    chroot "$LFS" /usr/bin/env -i  \
        HOME=/root                         \
        TERM="$TERM"                       \
        PS1='\u:\w\$ '                     \
        PATH=/bin:/usr/bin:/sbin:/usr/sbin \
        rpm -qa
    echo ""

    chroot_unmount
}

chroot_and_install_rpms () {
    # $1 = package name
    # Clean and then copy the RPM into the chroot directory for installation below
    rm -v $CHROOT_INSTALL_RPM_DIR/*
    cp -v $CHROOT_RPMS_DIR_ARCH/$1-* $CHROOT_INSTALL_RPM_DIR
    cp -v $CHROOT_RPMS_DIR_NOARCH/$1-* $CHROOT_INSTALL_RPM_DIR

    chroot_mount

    echo "RPM files to be installed..."
    chroot "$LFS" ls -la $CHROOT_INSTALL_RPM_DIR_IN_CHROOT
    echo "Installing the rpms..."
    chroot "$LFS" /usr/bin/env -i  \
        HOME=/root                         \
        TERM="$TERM"                       \
        PS1='\u:\w\$ '                     \
        PATH=/bin:/usr/bin:/sbin:/usr/sbin \
        rpm -i -vh --force --nodeps $CHROOT_INSTALL_RPM_DIR_IN_CHROOT/*

    chroot_unmount
}

chroot_and_run_rpmbuild () {
    # $1 = package name
    echo "Will build spec for $1 in chroot"
    chroot_mount

    if [ "$RUN_CHECK" = "y" ]; then
        export CHECK_SETTING=" "
    else
        export CHECK_SETTING="--nocheck"
    fi

    chroot "$LFS" /usr/bin/env -i          \
        HOME=/root                         \
        TERM="$TERM"                       \
        PS1='\u:\w\$ '                     \
        PATH=/bin:/usr/bin:/sbin:/usr/sbin \
        SHELL=/bin/bash                    \
        rpmbuild --nodeps --rebuild --clean     \
            $CHECK_SETTING                 \
            --define "with_check 1" --define "dist $PARAM_DIST_TAG" --define "mariner_build_number $PARAM_BUILD_NUM" \
            --define "mariner_release_version $PARAM_RELEASE_VER" $TOPDIR/SRPMS/$1 \
            || echo "$1" >> "$TOOLCHAIN_FAILURES"

    chroot_unmount
}

build_rpm_in_chroot_no_install () {
    # $1 = package name
    # $2 = qualified package name
    if [ -n "$2" ]; then
        rpmPath=$(find $CHROOT_RPMS_DIR -name "$2-*" -print -quit)
    else
        rpmPath=$(find $CHROOT_RPMS_DIR -name "$1-*" -print -quit)
    fi
    if [ "$INCREMENTAL_TOOLCHAIN" = "y" ] && [ -n "$rpmPath" ]; then
        echo found $rpmPath for $1
        find $CHROOT_RPMS_DIR -name "$1*" -exec cp {} $FINISHED_RPM_DIR ';'
    else
        echo only building RPM $1 within the chroot
        specPath=$(find $SPECROOT -name "$1.spec" -print -quit)
        specDir=$(dirname $specPath)
        srpmName=$(rpmspec -q $specPath --srpm --define="with_check 1" --define="_sourcedir $specDir" --define="dist $PARAM_DIST_TAG" --queryformat %{NAME}-%{VERSION}-%{RELEASE}.src.rpm)
        srpmPath=$MARINER_INPUT_SRPMS_DIR/$srpmName
        cp $srpmPath $CHROOT_SRPMS_DIR
        chroot_and_run_rpmbuild $srpmName 2>&1 | awk '{ print strftime("time=\"%Y-%m-%dT%T%Z\""), $0; fflush(); }' | tee $TOOLCHAIN_LOGS/$srpmName.log
        cp $CHROOT_RPMS_DIR_ARCH/$1* $FINISHED_RPM_DIR
        cp $CHROOT_RPMS_DIR_NOARCH/$1* $FINISHED_RPM_DIR
        cp $srpmPath $MARINER_OUTPUT_SRPMS_DIR
        echo NOT installing the package $srpmName
    fi
    echo "$1" >> $TOOLCHAIN_BUILD_LIST
}

# Copy RPM subpackages that have a different prefix
copy_rpm_subpackage () {
    echo cache $1 RPMS
    cp $CHROOT_RPMS_DIR_ARCH/$1* $FINISHED_RPM_DIR
    cp $CHROOT_RPMS_DIR_NOARCH/$1* $FINISHED_RPM_DIR
}

echo Setting up initial chroot to build pass1 toolchain RPMs from SPECs

# Configure rpm macros
mkdir -pv $LFS/usr/etc/rpm
cp -v $SPECROOT/mariner-rpm-macros/macros $LFS/usr/etc/rpm/macros
mkdir -pv $LFS/usr/lib/rpm/mariner
cp -v $SPECROOT/mariner-rpm-macros/gen-ld-script.sh $LFS/usr/lib/rpm/mariner/gen-ld-script.sh
cp -v $SPECROOT/mariner-rpm-macros/generate-package-note.py $LFS/usr/lib/rpm/mariner/generate-package-note.py
cp -v $SPECROOT/mariner-rpm-macros/verify-package-notes.sh $LFS/usr/lib/rpm/mariner/verify-package-notes.sh
cp -v $SPECROOT/rpm/brp* $LFS/usr/lib/rpm
mkdir -pv $LFS/usr/lib/rpm/macros.d
cp -v $MARINER_TOOLCHAIN_MANIFESTS_DIR/macros.override $LFS/usr/lib/rpm/macros.d/macros.override
chmod +x $LFS/usr/lib/rpm/brp*
cp /etc/resolv.conf $LFS/etc/

chroot_and_print_installed_rpms

echo Building final list of toolchain RPMs
build_rpm_in_chroot_no_install mariner-rpm-macros
copy_rpm_subpackage mariner-check-macros
chroot_and_install_rpms mariner-rpm-macros
chroot_and_install_rpms mariner-check-macros
build_rpm_in_chroot_no_install mariner-release
chroot_and_install_rpms mariner-release
build_rpm_in_chroot_no_install filesystem
build_rpm_in_chroot_no_install kernel-headers
build_rpm_in_chroot_no_install glibc
build_rpm_in_chroot_no_install zlib
build_rpm_in_chroot_no_install file
build_rpm_in_chroot_no_install binutils
build_rpm_in_chroot_no_install gmp
build_rpm_in_chroot_no_install mpfr
build_rpm_in_chroot_no_install libmpc
build_rpm_in_chroot_no_install gcc
build_rpm_in_chroot_no_install ncurses
build_rpm_in_chroot_no_install readline
build_rpm_in_chroot_no_install bash
build_rpm_in_chroot_no_install bzip2
build_rpm_in_chroot_no_install gdbm
build_rpm_in_chroot_no_install coreutils
build_rpm_in_chroot_no_install gettext
build_rpm_in_chroot_no_install sqlite
build_rpm_in_chroot_no_install nspr
build_rpm_in_chroot_no_install expat
build_rpm_in_chroot_no_install libffi
build_rpm_in_chroot_no_install xz
build_rpm_in_chroot_no_install zstd
build_rpm_in_chroot_no_install lz4
build_rpm_in_chroot_no_install m4
build_rpm_in_chroot_no_install libcap
build_rpm_in_chroot_no_install popt
build_rpm_in_chroot_no_install findutils
build_rpm_in_chroot_no_install tar
build_rpm_in_chroot_no_install gawk
build_rpm_in_chroot_no_install gzip
build_rpm_in_chroot_no_install libpipeline
build_rpm_in_chroot_no_install libtool
build_rpm_in_chroot_no_install make
build_rpm_in_chroot_no_install patch
build_rpm_in_chroot_no_install procps-ng
build_rpm_in_chroot_no_install sed
build_rpm_in_chroot_no_install check
build_rpm_in_chroot_no_install cpio

# perl needs gdbm, bzip2, zlib
chroot_and_install_rpms gdbm
chroot_and_install_rpms bzip2
chroot_and_install_rpms zlib
build_rpm_in_chroot_no_install perl
chroot_and_install_rpms perl

build_rpm_in_chroot_no_install flex
build_rpm_in_chroot_no_install libarchive
build_rpm_in_chroot_no_install diffutils

# Need to install perl-DBI in order for perl-DBD-SQLite to build
build_rpm_in_chroot_no_install perl-DBI
chroot_and_install_rpms perl-DBI

build_rpm_in_chroot_no_install perl-Object-Accessor
build_rpm_in_chroot_no_install bison
build_rpm_in_chroot_no_install autoconf
build_rpm_in_chroot_no_install texinfo
build_rpm_in_chroot_no_install perl-DBD-SQLite
build_rpm_in_chroot_no_install perl-DBIx-Simple
build_rpm_in_chroot_no_install elfutils
build_rpm_in_chroot_no_install automake

build_rpm_in_chroot_no_install pkgconf

# Need to install elfutils to build dwz
chroot_and_install_rpms elfutils
build_rpm_in_chroot_no_install dwz

# Need to install perl-Text-Template and perl-Test-Warnings
# to build openssl
build_rpm_in_chroot_no_install perl-Test-Warnings
chroot_and_install_rpms perl-Test-Warnings
build_rpm_in_chroot_no_install perl-Text-Template
chroot_and_install_rpms perl-Text-Template
build_rpm_in_chroot_no_install openssl

# perl-generators requires perl-Fedora-VSP
build_rpm_in_chroot_no_install perl-Fedora-VSP
chroot_and_install_rpms perl-Fedora-VSP
build_rpm_in_chroot_no_install perl-generators
chroot_and_install_rpms perl-generators

build_rpm_in_chroot_no_install wget

# build and install additional openjdk build dependencies
build_rpm_in_chroot_no_install pcre
chroot_and_install_rpms pcre
build_rpm_in_chroot_no_install which
chroot_and_install_rpms which
build_rpm_in_chroot_no_install zip
chroot_and_install_rpms zip
build_rpm_in_chroot_no_install unzip
chroot_and_install_rpms unzip
build_rpm_in_chroot_no_install gperf
chroot_and_install_rpms gperf

# Python3 needs to be installed for RPM to build
build_rpm_in_chroot_no_install python3
rm -vf $FINISHED_RPM_DIR/python3*debuginfo*.rpm
chroot_and_install_rpms python3

# libxml2 is required for at least: libxslt, createrepo_c
build_rpm_in_chroot_no_install libxml2
copy_rpm_subpackage python3-libxml2
chroot_and_install_rpms libxml2

# Download JDK rpms
echo Download JDK rpms
case $(uname -m) in
    x86_64)
        wget -nv --timeout=30 https://packages.microsoft.com/cbl-mariner/2.0/prod/Microsoft/x86_64/msopenjdk-11-11.0.14.1+1-LTS-31207.x86_64.rpm --directory-prefix=$CHROOT_RPMS_DIR_ARCH
    ;;
    aarch64)
        wget -nv --timeout=30 https://packages.microsoft.com/cbl-mariner/2.0/prod/Microsoft/aarch64/msopenjdk-11-11.0.14.1+1-LTS-31207.aarch64.rpm --directory-prefix=$CHROOT_RPMS_DIR_ARCH
    ;;
esac

# PCRE needs to be installed (above) for grep to build with perl regexp support
build_rpm_in_chroot_no_install grep

# Lua needs to be installed for RPM to build
build_rpm_in_chroot_no_install lua
chroot_and_install_rpms lua

build_rpm_in_chroot_no_install lua-rpm-macros
chroot_and_install_rpms lua-rpm-macros

# Build tdnf-3.2.2
build_rpm_in_chroot_no_install kmod
build_rpm_in_chroot_no_install perl-XML-Parser
build_rpm_in_chroot_no_install libssh2
build_rpm_in_chroot_no_install perl-libintl-perl
build_rpm_in_chroot_no_install libgpg-error

# intltool needs perl-XML-Parser
chroot_and_install_rpms perl-XML-Parser
build_rpm_in_chroot_no_install intltool
build_rpm_in_chroot_no_install e2fsprogs

# libgcrypt needs libgpg-error
chroot_and_install_rpms libgpg-error
build_rpm_in_chroot_no_install libgcrypt
build_rpm_in_chroot_no_install kbd

# krb5 needs e2fsprogs
chroot_and_install_rpms e2fsprogs
build_rpm_in_chroot_no_install krb5

# curl needs libssh2, krb5
chroot_and_install_rpms libssh2
chroot_and_install_rpms krb5
build_rpm_in_chroot_no_install curl

# python3-setuptools needs python3-xml
# python3-xml is built by building python3
chroot_and_install_rpms python3-xml

# cracklib needs python3-setuptools
chroot_and_install_rpms python3-setuptools
build_rpm_in_chroot_no_install cracklib

# pam needs cracklib
chroot_and_install_rpms cracklib

build_rpm_in_chroot_no_install cmake
build_rpm_in_chroot_no_install pam
build_rpm_in_chroot_no_install docbook-dtd-xml

# libxslt needs libgcrypt
chroot_and_install_rpms libgcrypt
build_rpm_in_chroot_no_install libxslt

# docbook-style-xsl needs pam
chroot_and_install_rpms pam
build_rpm_in_chroot_no_install docbook-style-xsl

# gtest needs cmake
chroot_and_install_rpms cmake
build_rpm_in_chroot_no_install gtest

build_rpm_in_chroot_no_install libsolv

# glib needs perl-XML-Parser, python3-xml, gtk-doc, meson, libselinux
chroot_and_install_rpms perl-XML-Parser

# itstool needs python3-libxml2
chroot_and_install_rpms python3-libxml2
build_rpm_in_chroot_no_install itstool

# ninja-build requires gtest
chroot_and_install_rpms gtest
build_rpm_in_chroot_no_install ninja-build

# meson requires ninja-build, gettext
chroot_and_install_rpms ninja-build
chroot_and_install_rpms gettext
build_rpm_in_chroot_no_install meson

# gtk-doc needs itstool, meson, python3-pygments
chroot_and_install_rpms itstool
chroot_and_install_rpms meson
build_rpm_in_chroot_no_install python-pygments
chroot_and_install_rpms python-pygments

# gtk-doc and ca-certificates require libxslt
chroot_and_install_rpms docbook-dtd-xml
chroot_and_install_rpms docbook-style-xsl
chroot_and_install_rpms libxslt
chroot_and_install_rpms python3
build_rpm_in_chroot_no_install gtk-doc

# python3-lxml requires python3-Cython and libxslt
build_rpm_in_chroot_no_install Cython
chroot_and_install_rpms python3-Cython
build_rpm_in_chroot_no_install python-lxml
chroot_and_install_rpms python3-lxml

# p11-kit, libtasn1 and glib need gtk-doc
chroot_and_install_rpms gtk-doc
build_rpm_in_chroot_no_install libtasn1

build_rpm_in_chroot_no_install libsepol
build_rpm_in_chroot_no_install swig

# libselinux requires libsepol and swig
chroot_and_install_rpms libsepol
chroot_and_install_rpms swig
build_rpm_in_chroot_no_install libselinux

chroot_and_install_rpms libselinux

build_rpm_in_chroot_no_install glib
build_rpm_in_chroot_no_install libassuan
build_rpm_in_chroot_no_install npth
build_rpm_in_chroot_no_install libksba

# gnupg2 requires readline, npth, libassuan, libksba
chroot_and_install_rpms readline
chroot_and_install_rpms npth
chroot_and_install_rpms libassuan
chroot_and_install_rpms libksba
build_rpm_in_chroot_no_install gnupg2

# gpgme needs gnupg2 and python3
chroot_and_install_rpms gnupg2
build_rpm_in_chroot_no_install gpgme

# tdnf needs python3, gpgme, curl, libmetalink and libsolv
build_rpm_in_chroot_no_install libmetalink
chroot_and_install_rpms libsolv
chroot_and_install_rpms curl
chroot_and_install_rpms gpgme
chroot_and_install_rpms libmetalink
build_rpm_in_chroot_no_install pinentry

build_rpm_in_chroot_no_install tdnf

# Build createrepo_c
# createrepo_c needs file, glib
chroot_and_install_rpms file
chroot_and_install_rpms glib
build_rpm_in_chroot_no_install createrepo_c

build_rpm_in_chroot_no_install libsepol

# audit needs: python3, krb5, swig, e2fsprogs
build_rpm_in_chroot_no_install audit

# rebuild pam with selinux and audit support
chroot_and_install_rpms audit
build_rpm_in_chroot_no_install pam

# libselinux requires libsepol
chroot_and_install_rpms libsepol
build_rpm_in_chroot_no_install libselinux
# util-linux and rpm require libselinux
chroot_and_install_rpms libselinux
build_rpm_in_chroot_no_install util-linux
# rpm requires debugedit
build_rpm_in_chroot_no_install debugedit
chroot_and_install_rpms debugedit
build_rpm_in_chroot_no_install rpm

# python-jinja2 needs python3-markupsafe
# python3-setuptools, python3-xml are also needed but already installed
build_rpm_in_chroot_no_install python-markupsafe
copy_rpm_subpackage python3-markupsafe
chroot_and_install_rpms python3-markupsafe
build_rpm_in_chroot_no_install python-jinja2
copy_rpm_subpackage python3-jinja2

# systemd-bootstrap requires libcap, xz, kbd, kmod, util-linux, meson, intltool, python3-jinja2
# gperf is also needed, but is installed earlier
chroot_and_install_rpms libcap
chroot_and_install_rpms lz4
chroot_and_install_rpms xz
chroot_and_install_rpms kbd
chroot_and_install_rpms kmod
chroot_and_install_rpms util-linux
chroot_and_install_rpms meson
chroot_and_install_rpms intltool
chroot_and_install_rpms python3-jinja2
build_rpm_in_chroot_no_install systemd-bootstrap

# Removed 'lvm2', might not need: ncurses
chroot_and_install_rpms ncurses

# p11-kit needs libtasn1, systemd-bootstrap
chroot_and_install_rpms libtasn1
chroot_and_install_rpms systemd-bootstrap
build_rpm_in_chroot_no_install p11-kit

# asciidoc needs python3-xml
build_rpm_in_chroot_no_install asciidoc

# ca-certificates needs p11-kit and asciidoc
chroot_and_install_rpms p11-kit
chroot_and_install_rpms asciidoc
build_rpm_in_chroot_no_install ca-certificates

# slang needs readline
build_rpm_in_chroot_no_install slang

# newt needs popt and slang
chroot_and_install_rpms popt
chroot_and_install_rpms slang
build_rpm_in_chroot_no_install newt

# chkconfig needs newt, popt and slang
chroot_and_install_rpms newt
build_rpm_in_chroot_no_install chkconfig

build_rpm_in_chroot_no_install mariner-repos
build_rpm_in_chroot_no_install pyproject-rpm-macros

# Rebuild audit with systemd-bootstrap-rpm-macros installed.
# Without it, audit's systemd macros won't expand and install/uninstall
# will fail.
build_rpm_in_chroot_no_install audit
copy_rpm_subpackage python3-audit

chroot_and_print_installed_rpms

# Ensure all RPMS are copied out of the chroot
echo Copying all built RPMS from chroot
cp -v $CHROOT_RPMS_DIR_ARCH/* $FINISHED_RPM_DIR
cp -v $CHROOT_RPMS_DIR_NOARCH/* $FINISHED_RPM_DIR

echo Finished building final list of toolchain RPMs
chroot_unmount
ls -la $FINISHED_RPM_DIR
ls -la $FINISHED_RPM_DIR | wc

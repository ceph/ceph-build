#!/bin/sh

#
#  Generate the files neccessary for a yum repo conf rpm.
#  Needs to be run after all the RPMs are built.

usage() {
    echo "usage: $0 releasedir repo vers dist"
}

release_dir="$1"
repo="$2"
vers="$3"
dist="$4"

echo "$0, 1=$1, 2=$2, 3=$3, 4=$4"

[ ! -d $release_dir ] && echo "Release directory, $release_dir, does not exist" && exit 1
[ ! -d $repo ] && echo "Repo directory, $repo, does not exist" && exit 1

REPO_HOST="http://ceph.com"
#BRANCH=${TARGET}/ref/${BRANCH}/
BRANCH="rpm-cuttlefish/${dist}"
#BRANCH="rpm-testing/${dist}"
echo "Building for branch=${REPO_HOST}/${BRANCH}"

if [ "$dist" = "sles11" -o "$dist" = "opensuse12.2" ]
then
    pkg_release="0"
    EXTRA="suse_version 12.2"
else
    pkg_release="0.$dist"
fi

RPMBUILD=${release_dir}/${vers}/rpmbuild
mkdir -p ${RPMBUILD}/BUILD
mkdir -p ${RPMBUILD}/BUILDROOT
mkdir -p ${RPMBUILD}/RPMS
mkdir -p ${RPMBUILD}/SOURCES
mkdir -p ${RPMBUILD}/SPECS
mkdir -p ${RPMBUILD}/SRPMS

#  Spec File
cat <<EOF > ${RPMBUILD}/SPECS/ceph-release.spec
Name:           ceph-release       
Version:        1
Release:        $pkg_release
Summary:        Ceph repository configuration
Group:          System Environment/Base 
License:        GPLv2
URL:            http://ceph.com
Source0:        ceph.repo	
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:	noarch

%description
This package contains the Ceph repository GPG key as well as configuration
for yum and up2date.  

%prep

%setup -q  -c -T
install -pm 644 %{SOURCE0} .

%build

%install
rm -rf %{buildroot}
%if 0%{defined suse_version}
install -dm 755 %{buildroot}/%{_sysconfdir}/zypp
install -dm 755 %{buildroot}/%{_sysconfdir}/zypp/repos.d
install -pm 644 %{SOURCE0} \
    %{buildroot}/%{_sysconfdir}/zypp/repos.d
%else
install -dm 755 %{buildroot}/%{_sysconfdir}/yum.repos.d
install -pm 644 %{SOURCE0} \
    %{buildroot}/%{_sysconfdir}/yum.repos.d
%endif

%clean
#rm -rf %{buildroot}

%post

%postun 

%files
%defattr(-,root,root,-)
#%doc GPL
%if 0%{defined suse_version}
/etc/zypp/repos.d/*
%else
/etc/yum.repos.d/*
%endif
#/etc/pki/rpm-gpg/*

%changelog
* Tue Mar 10 2013 Gary Lowell <glowell@inktank.com> - 1-0
- Handle both yum and zypper
- Use URL to ceph git repo for key
- remove config attribute from repo file
* Tue Aug 27 2012 Gary Lowell <glowell@inktank.com> - 1-0
- Initial Package
EOF
#  End of ceph-release.spec file.

# Install ceph.repo file
cat <<EOF > ${RPMBUILD}/SOURCES/ceph.repo
[ceph]
name=Ceph packages for \$basearch
baseurl=${REPO_HOST}/${BRANCH}/\$basearch
enabled=1
gpgcheck=1
type=rpm-md
gpgkey=https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/release.asc

[ceph-noarch]
name=Ceph noarch packages
baseurl=${REPO_HOST}/${BRANCH}/noarch
enabled=1
gpgcheck=1
type=rpm-md
gpgkey=https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/release.asc

[ceph-source]
name=Ceph source packages
baseurl=${REPO_HOST}/${BRANCH}/SRPMS
enabled=0
gpgcheck=1
type=rpm-md
gpgkey=https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/release.asc
EOF
# End of ceph.repo file

# Build RPMs
echo "$RPMBUILD" | grep -v -q '^/' &&  \
    RPMBUILD=`readlink -fn ${RPMBUILD}`   ### rpm wants absolute path

if [ -n "$EXTRA" ] ; then
    rpmbuild -bb --define "_topdir ${RPMBUILD}" --define "_unpackaged_files_terminate_build 0" --define "$EXTRA" ${RPMBUILD}/SPECS/ceph-release.spec
else
    rpmbuild -bb --define "_topdir ${RPMBUILD}" --define "_unpackaged_files_terminate_build 0" ${RPMBUILD}/SPECS/ceph-release.spec
fi


mkdir -p $repo/$vers/$dist/noarch
cp -a ${RPMBUILD}/RPMS/noarch/* $repo/$vers/$dist/noarch/.
rm -rf ${RPMBUILD}/RPMS/*

exit 0

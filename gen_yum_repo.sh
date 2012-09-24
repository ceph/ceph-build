#!/bin/sh

#
#  Generate the files neccessary for a yum repo conf rpm.
#  Needs to be run after all the RPMs are built.

usage() {
    echo "usage: $0 releasedir keyid [repo-host]"
}

release_dir="$1"
keyid="$2"
repo_host="$3"

[ -z "$release_dir" ] && echo specify release directory && exit 1
#[ -z "$keyid" ] && echo specify keyid && exit 1

# For testing
[ -z "$keyid" ] && keyid=3CF7ABC8
[ -z "$repo_host" ] && repo_host="gitbuilder-centos6-amd64"

#
RPMBUILD=$release_dir/rpmbuild

#  Spec File
cat <<EOF > $RPMBUILD/SPECS/ceph-release.spec
Name:           ceph-release       
Version:        1
Release:        0
Summary:        Ceph repository configuration
Group:          System Environment/Base 
License:        GPLv2
URL:            http://download.ceph.com/pub/ceph
Source0:        RPM-GPG-KEY-CEPH
Source1:        ceph.repo	
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:	noarch

%description
This package contains the Ceph repository GPG key as well as configuration
for yum and up2date.  

%prep

%setup -q  -c -T
install -pm 644 %{SOURCE0} .
install -pm 644 %{SOURCE1} .

%build

%install
rm -rf %{buildroot}
install -Dpm 644 %{SOURCE0} \
    %{buildroot}/%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-CEPH
install -dm 755 %{buildroot}/%{_sysconfdir}/yum.repos.d
install -pm 644 %{SOURCE1} \
    %{buildroot}/%{_sysconfdir}/yum.repos.d

%clean
#rm -rf %{buildroot}

%post

%postun 

%files
%defattr(-,root,root,-)
#%doc GPL
%config(noreplace) /etc/yum.repos.d/*
/etc/pki/rpm-gpg/*

%changelog
* Tue Aug 27 2011 Gary Lowell <glowell@inktank.com> - 1-0
- Initial Package
EOF
#  End of ceph-release.spec file.

# GPG Key
gpg --export --armor $keyid > $RPMBUILD/SOURCES/RPM-GPG-KEY-CEPH
chmod 644 $RPMBUILD/SOURCES/RPM-GPG-KEY-CEPH

# Install ceph.repo file
cat <<EOF > $RPMBUILD/SOURCES/ceph.repo
[ceph]
name=Ceph
baseurl=http://gitbuilder-centos6-amd64.front.sepia.ceph.com/rpms/centos6/\$basearch
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CEPH
EOF
# End of ceph.repo file

# Build RPMs
echo "$RPMBUILD" | grep -v -q '^/' &&  \
    RPMBUILD=`readlink -fn ${RPMBUILD}`   ### rpm wants absolute path

rpmbuild -bb --define "_topdir ${RPMBUILD}" --define "_unpackaged_files_terminate_build 0" ${RPMBUILD}/SPECS/ceph-release.spec

# Package builds as noarch, but we want to move it to x86_64 for centos.
mv ${RPMBUILD}/RPMS/noarch/ceph*.rpm ${RPMBUILD}/RPMS/x86_64/.
[ "$(ls -A ${RPMBUILD}/RPMS/noarch)" ] || rmdir ${RPMBUILD}/RPMS/noarch

# Construct repodata
for dir in $RPMBUILD/RPMS/* 
do
    if [ -d $dir ] ; then
        createrepo $dir
        gpg --detach-sign --armor -u $keyid $dir/repodata/repomd.xml
    fi
done

exit 0

Name:           ceph-release
Version:        1
Release:        0%{?dist}
Summary:        Ceph Development repository configuration
Group:          System Environment/Base
License:        GPLv2
URL:            ${project_url}
Source0:        ceph.repo
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch

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

%post

%postun

%files
%defattr(-,root,root,-)
%if 0%{defined suse_version}
/etc/zypp/repos.d/*
%else
/etc/yum.repos.d/*
%endif

%changelog
* Mon Apr 28 2025 Zack Cerza <zack@cerza.org> 1-1

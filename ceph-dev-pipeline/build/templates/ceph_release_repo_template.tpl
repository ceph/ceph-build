[Ceph]
name=Ceph packages for \\$basearch
baseurl=${repo_base_url}/\\$basearch
enabled=1
gpgcheck=0
type=rpm-md
gpgkey=https://download.ceph.com/keys/autobuild.asc

[Ceph-noarch]
name=Ceph noarch packages
baseurl=${repo_base_url}/noarch
enabled=1
gpgcheck=0
type=rpm-md
gpgkey=https://download.ceph.com/keys/autobuild.asc

[ceph-source]
name=Ceph source packages
baseurl=${repo_base_url}/SRPMS
enabled=1
gpgcheck=0
type=rpm-md
gpgkey=https://download.ceph.com/keys/autobuild.asc

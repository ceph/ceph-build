import groovy.transform.Field

@Field Map ubuntu_releases = [
  "noble": "24.04",
  "jammy": "22.04",
  "focal": "20.04",
]
@Field Map debian_releases = [
  "bookworm": "12",
  "bullseye": "11",
]
@Field Map build_matrix = [:]

@Field String ceph_release_spec_template = '''
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
'''

@Field String ceph_release_repo_template = '''
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
'''

def get_os_info(dist) {
  def os = [
    "name": dist,
    "version": dist,
    "version_name": dist,
    "pkg_type": "NONE",
  ]
  def matcher = dist =~ /^(centos|rhel|rocky|fedora)(\d+)/
  if ( matcher.find() ) {
    os.name = matcher.group(1)
    os.version = os.version_name = matcher.group(2)
    os.pkg_type = "rpm"
  } else if ( debian_releases.keySet().contains(dist) ) {
    os.name = "debian"
    os.version = debian_releases[dist]
    os.pkg_type = "deb"
  } else if ( ubuntu_releases.keySet().contains(dist) ) {
    os.name = "ubuntu"
    os.version = ubuntu_releases[dist]
    os.pkg_type = "deb"
  }
  // Avoid NotSerializableException on Matchers
  matcher = null
  return os
}

@NonCPS
def get_ceph_release_spec_text(project_url) {
  def engine = new groovy.text.SimpleTemplateEngine()
  def template = engine.createTemplate(ceph_release_spec_template)
  def text = template.make(["project_url": project_url])
  return text.toString()
}

@NonCPS
def get_ceph_release_repo_text(base_url) {
  def engine = new groovy.text.SimpleTemplateEngine()
  def template = engine.createTemplate(ceph_release_repo_template)
  def text = template.make(["repo_base_url": base_url])
  return text.toString()
}

def run(Map CFG) {
  stage('source distribution') {
    if (!env.SETUP_BUILD_ID) {
      def setup_build = build(
        job: env.SETUP_JOB,
        parameters: [
          string(name: "BRANCH", value: env.BRANCH),
          // Below are just for ceph-source-dist
          string(name: "SHA1", value: env.SHA1),
          string(name: "CEPH_REPO", value: env.CEPH_REPO),
          string(name: "CEPH_BUILD_BRANCH", value: env.CEPH_BUILD_BRANCH),
          // Below are only for actual releases
          string(name: 'RELEASE_TYPE',  value: env.RELEASE_TYPE ?: ''),
          string(name: 'RELEASE_BUILD', value: env.RELEASE_BUILD ?: ''),
          string(name: 'VERSION',       value: env.VERSION ?: '')
        ]
      )
      env.SETUP_BUILD_ID = setup_build.getNumber()
    }
    echo "SETUP_BUILD_ID=${env.SETUP_BUILD_ID}"
    env.SETUP_BUILD_URL = new URI([env.JENKINS_URL, "job", env.SETUP_JOB, env.SETUP_BUILD_ID].join("/")).normalize().toString()
    echo "${env.SETUP_BUILD_URL}"
  }

  stage('parallel build') {
    def dists   = ['centos9','centos10','rocky9','rocky10','focal','jammy','noble','bookworm']
    def archs   = ['x86_64','arm64']
    def flavors = ['default','crimson-release','crimson-debug']

    def branches = [:]

    // tokenize for exact matching (avoids substring false-positives [e.g., jam = jammy])
    def distList   = (env.DISTROS ?: '').tokenize()
    def archList   = (env.ARCHS   ?: '').tokenize()
    def flavorList = (env.FLAVORS ?: '').tokenize()

    for (d in dists) {
      for (a in archs) {
        for (f in flavors) {

          // honor matrix 'when' conditions early (exact matches)
          if (!distList.contains(d))   continue
          if (!archList.contains(a))   continue
          if (!flavorList.contains(f)) continue

          // crimson only on centos9 x86_64
          if (f.startsWith('crimson') && (d != 'centos9' || a != 'x86_64')) {
            continue
          }

          // if CI_CONTAINER=true, restrict DIST=centos9
          if ((env.CI_CONTAINER ?: '') == 'true' && d != 'centos9') {
            continue
          }

          final String D = d
          final String A = a
          final String F = f
          final String key = "${D}_${A}_${F}"

          branches[key] = {
            node("(installed-os-centos9||installed-os-noble)&&${A}&&${CFG.base_node_label}") {

              // ensure env for this axis
              withEnv(["DIST=${D}", "ARCH=${A}", "FLAVOR=${F}"]) {

                boolean branchFailed = false

                try {
                  stage("node ${key}") {
                    build_matrix["${D}_${A}"] = (env.CI_COMPILE ?: 'false').toBoolean()
                    sh "hostname -f"
                    def node_shortname = env.NODE_NAME.split('\\+')[-1]
                    def node_url = new URI([env.JENKINS_URL, "computer", env.NODE_NAME].join("/")).normalize()
                    echo "DIST=${env.DIST} ARCH=${env.ARCH} FLAVOR=${env.FLAVOR}"
                    echo "${node_shortname}"
                    echo "${node_url}"
                    def os = get_os_info(env.DIST)
                    echo "OS_NAME=${os.name}"
                    echo "OS_PKG_TYPE=${os.pkg_type}"
                    echo "OS_VERSION=${os.version}"
                    echo "OS_VERSION_NAME=${os.version_name}"
                    sh './scripts/setup_container_runtime.sh'
                    sh "cat /etc/os-release"
                  }

                  stage("checkout ceph-build") {
                    checkout scmGit(
                      branches: [[name: CFG.ceph_build_branch]],
                      userRemoteConfigs: [[url: CFG.ceph_build_repo]],
                      extensions: [[$class: 'CleanBeforeCheckout']]
                    )
                  }

                  stage("copy artifacts") {
                    def artifact_filter = "dist/sha1,dist/version,dist/other_envvars,dist/ceph-*.tar.bz2"
                    def os = get_os_info(env.DIST)
                    if ((env.CI_COMPILE ?: 'false').toBoolean() && os.pkg_type == "deb") {
                      artifact_filter += ",dist/ceph_*.diff.gz,dist/ceph_*.dsc"
                    }
                    echo artifact_filter
                    copyArtifacts(
                      projectName: env.SETUP_JOB,
                      selector: specific(buildNumber: env.SETUP_BUILD_ID),
                      filter: artifact_filter
                    )
                    sh 'sudo journalctl --show-cursor -n 0 --no-pager | tail -n1 | cut -d" " -f3 > $WORKSPACE/cursor'

                    def sha1_props = readProperties file: "${WORKSPACE}/dist/sha1"
                    def sha1_from_artifact = sha1_props.SHA1.trim().toLowerCase()
                    def sha1_trimmed = (env.SHA1 ?: "").trim().toLowerCase()
                    if (env.SHA1 && sha1_from_artifact != sha1_trimmed) {
                      error "SHA1 from artifact (${sha1_from_artifact}) does not match parameter value (${sha1_trimmed})"
                    } else if (!env.SHA1) {
                      env.SHA1 = sha1_from_artifact
                    }
                    echo "SHA1=${env.SHA1}"
                    env.VERSION = readFile(file: "${WORKSPACE}/dist/version").trim()

                    // import extra envvars written by ceph-source-dist
                    def props = readProperties file: "${WORKSPACE}/dist/other_envvars"
                    for (p in props) {
                      env."${p.key}" = p.value
                    }

                    def branch_ui_value = env.BRANCH
                    def sha1_ui_value = env.SHA1
                    if (env.CEPH_REPO?.find(/https?:\/\/github.com\//)) {
                      def suffix = (env.RELEASE_BUILD?.trim() == "true") ? "-release" : ""
                      def branch_url = "${env.CEPH_REPO}/tree/${env.BRANCH}${suffix}"
                      branch_ui_value = "<a href=\"${branch_url}\">${env.BRANCH}${suffix}</a>"
                      def commit_url = "${env.CEPH_REPO}/commit/${env.SHA1}"
                      sha1_ui_value = "<a href=\"${commit_url}\">${env.SHA1}</a>"
                    }
                    def shaman_url = "https://shaman.ceph.com/builds/ceph/${env.BRANCH}/${env.SHA1}"
                    def build_description = """\
                      BRANCH=${branch_ui_value}<br />
                      SHA1=${sha1_ui_value}<br />
                      VERSION=${env.VERSION}<br />
                      DISTROS=${env.DISTROS}<br />
                      ARCHS=${env.ARCHS}<br />
                      FLAVORS=${env.FLAVORS}<br />
                      <a href="${env.SETUP_BUILD_URL}">SETUP_BUILD_ID=${env.SETUP_BUILD_ID}</a><br />
                      <a href="${shaman_url}">shaman builds for this branch+commit</a>
                    """.stripIndent()
                    buildDescription build_description

                    sh "sha256sum dist/*"
                    sh "cat dist/sha1 dist/version"
                    sh '''#!/bin/bash
                      set -ex
                      cd dist
                      mkdir ceph
                      tar --strip-components=1 -C ceph -xjf ceph-${VERSION}.tar.bz2 ceph-${VERSION}/{container,ceph.spec,ceph.spec.in,debian,Dockerfile.build,do_cmake.sh,install-deps.sh,run-make-check.sh,make-debs.sh,make-dist,make-srpm.sh,src/script}
                    '''
                  }

                  stage("check for built packages") {
                    if ((env.THROWAWAY ?: 'false') == 'false' && (build_matrix["${d}_${a}"] == true)) {
                      withCredentials([
                        string(credentialsId: 'chacractl-key', variable: 'CHACRACTL_KEY'),
                        string(credentialsId: 'shaman-api-key',  variable: 'SHAMAN_API_KEY')
                      ]) {
                        sh './scripts/setup_chacractl.sh'
                        def chacra_url = sh(script: '''grep url ~/.chacractl | cut -d'"' -f2''', returnStdout: true).trim()
                        def os = get_os_info(env.DIST)
                        def chacra_endpoint = "ceph/${env.BRANCH}/${env.SHA1}/${os.name}/${os.version_name}/${env.ARCH}/flavors/${env.FLAVOR}/"
                        def rc = sh(script: "$HOME/.local/bin/chacractl exists binaries/${chacra_endpoint}", returnStatus: true)
                        if (rc == 0 && env.FORCE != "true") {
                          echo "Skipping compilation since chacra already has artifacts. To override, use THROWAWAY=true (to skip this check) or FORCE=true (to re-upload artifacts)."
                          build_matrix["${d}_${a}"] = false
                        }
                      }
                    }
                  }

                  stage("builder container") {
                    if (build_matrix["${d}_${a}"] == true) {
                      withCredentials([
                        usernamePassword(credentialsId: 'quay-ceph-io-ceph-ci', usernameVariable: 'CONTAINER_REPO_CREDS_USR', passwordVariable: 'CONTAINER_REPO_CREDS_PSW'),
                        usernamePassword(credentialsId: 'dgalloway-docker-hub', usernameVariable: 'DOCKER_HUB_CREDS_USR', passwordVariable: 'DOCKER_HUB_CREDS_PSW')
                      ]) {
                        env.CEPH_BUILDER_IMAGE = "${env.CONTAINER_REPO_HOSTNAME}/${env.CONTAINER_REPO_ORGANIZATION}/ceph-build"
                        sh '''#!/bin/bash
                          set -ex
                          podman login -u ${CONTAINER_REPO_CREDS_USR} -p ${CONTAINER_REPO_CREDS_PSW} ${CONTAINER_REPO_HOSTNAME}/${CONTAINER_REPO_ORGANIZATION}
                          podman login -u ${DOCKER_HUB_CREDS_USR} -p ${DOCKER_HUB_CREDS_PSW} docker.io
                        '''
                        def ceph_builder_tag_short = "${env.BRANCH}.${env.DIST}.${env.ARCH}.${env.FLAVOR}"
                        def ceph_builder_tag = "${env.SHA1[0..6]}.${ceph_builder_tag_short}"
                        sh """#!/bin/bash -ex
                          podman pull ${env.CEPH_BUILDER_IMAGE}:${ceph_builder_tag} || \
                          podman pull ${env.CEPH_BUILDER_IMAGE}:${ceph_builder_tag_short} || \
                          true
                        """
                        sh """#!/bin/bash
                          set -ex
                          echo > .env
                          [[ $FLAVOR == crimson* ]] && echo "WITH_CRIMSON=true" >> .env || true
                          cd dist/ceph
                          python3 src/script/build-with-container.py --env-file=${env.WORKSPACE}/.env --image-repo=${env.CEPH_BUILDER_IMAGE} --tag=${ceph_builder_tag} --image-variant=packages -d ${DIST} -e build-container
                          podman tag ${env.CEPH_BUILDER_IMAGE}:${ceph_builder_tag} ${env.CEPH_BUILDER_IMAGE}:${ceph_builder_tag_short}
                        """
                        sh """#!/bin/bash -ex
                          podman push ${env.CEPH_BUILDER_IMAGE}:${ceph_builder_tag_short}
                          podman push ${env.CEPH_BUILDER_IMAGE}:${ceph_builder_tag}
                        """
                      }
                    }
                  }

                  stage("build") {
                    if (build_matrix["${d}_${a}"] == true) {
                      withCredentials([
                        string(credentialsId: 'shaman-api-key', variable: 'SHAMAN_API_KEY'),
                        usernamePassword(credentialsId: 'ibm-cloud-sccache-bucket', usernameVariable: 'SCCACHE_BUCKET_CREDS_USR', passwordVariable: 'SCCACHE_BUCKET_CREDS_PSW')
                      ]) {
                        def os = get_os_info(env.DIST)
                        sh "./scripts/update_shaman.sh started ceph ${os.name} ${os.version_name} ${env.ARCH}"
                        env.AWS_ACCESS_KEY_ID     = env.SCCACHE_BUCKET_CREDS_USR
                        env.AWS_SECRET_ACCESS_KEY = env.SCCACHE_BUCKET_CREDS_PSW

                        def ceph_builder_tag = "${env.SHA1[0..6]}.${env.BRANCH}.${env.DIST}.${env.ARCH}.${env.FLAVOR}"
                        def bwc_command_base = "python3 src/script/build-with-container.py --image-repo=${env.CEPH_BUILDER_IMAGE} --tag=${ceph_builder_tag} -d ${env.DIST} --image-variant=packages --ceph-version ${env.VERSION}"
                        def bwc_command = bwc_command_base
                        def bwc_cmd_sccache_flags = ""

                        if ((env.DWZ ?: 'true') == "false") {
                          sh '''#!/bin/bash
                            echo "DWZ=$DWZ" >> .env
                          '''
                          bwc_cmd_sccache_flags = "--env-file=${env.WORKSPACE}/.env"
                        }

                        if ((env.SCCACHE ?: 'false') == "true") {
                          sh '''#!/bin/bash
                            echo "SCCACHE=$SCCACHE" >> .env
                            echo "SCCACHE_CONF=/ceph/sccache.conf" >> .env
                            echo "SCCACHE_ERROR_LOG=/ceph/sccache_log.txt" >> .env
                            echo "SCCACHE_LOG=debug" >> .env
                            echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
                            echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env
                            echo "CEPH_BUILD_NORMALIZE_PATHS=true" >> .env
                          '''
                          writeFile(
                            file: "dist/ceph/sccache.conf",
                            text: """\
                              [cache.s3]
                              bucket = "ceph-sccache"
                              endpoint = "s3.us-south.cloud-object-storage.appdomain.cloud"
                              use_ssl = true
                              key_prefix = ""
                              server_side_encryption = false
                              no_credentials = false
                              region = "auto"
                            """
                          )
                          bwc_cmd_sccache_flags = "--env-file=${env.WORKSPACE}/.env"
                        }

                        def ceph_extra_cmake_args = ""
                        def deb_build_profiles = ""
                        switch (env.FLAVOR) {
                          case "default":
                            ceph_extra_cmake_args += " -DALLOCATOR=tcmalloc"
                            if ((env.RELEASE_BUILD ?: 'false').toBoolean()) {
                              ceph_extra_cmake_args += " -DWITH_SYSTEM_BOOST=OFF -DWITH_BOOST_VALGRIND=ON"
                            }
                            break
                          case ~/crimson.*/:
                            deb_build_profiles = "pkg.ceph.crimson"
                            break
                          default:
                            echo "FLAVOR=${env.FLAVOR} is invalid"
                            error("invalid flavor")
                        }

                        bwc_command = "${bwc_command} ${bwc_cmd_sccache_flags}"

                        if (os.pkg_type == "deb") {
                          def sccache_flag = "-DWITH_SCCACHE=ON"
                          if ((env.SCCACHE ?: 'false') == "true" && !ceph_extra_cmake_args.contains(sccache_flag)) {
                            ceph_extra_cmake_args += " ${sccache_flag}"
                          }
                          if (deb_build_profiles) {
                            sh """#!/bin/bash
                              echo "DEB_BUILD_PROFILES=${deb_build_profiles}" >> .env
                            """
                          }
                          bwc_command = "${bwc_command} -e debs"
                        } else if (env.DIST =~ /^(centos|rhel|rocky|fedora).*/) {
                          def rpmbuild_args = ""
                          if ((env.SCCACHE ?: 'false') == "true") rpmbuild_args += " -R--with=sccache"
                          if ((env.DWZ ?: 'true')   == "false")   rpmbuild_args += " -R--without=dwz"
                          if (env.FLAVOR == "default")            rpmbuild_args += " -R--with=tcmalloc"
                          if (env.FLAVOR.startsWith("crimson"))   rpmbuild_args += " -R--with=crimson"
                          bwc_command = "${bwc_command}${rpmbuild_args} -e rpm"
                        } else if (env.DIST =~ /suse|sles/) {
                          error("bwc not implemented for ${env.DIST}")
                        } else if (env.DIST =~ /windows/) {
                          error("bwc not implemented for ${env.DIST}")
                        } else {
                          error("DIST '${env.DIST}' is invalid!")
                        }

                        sh """#!/bin/bash
                          echo "CEPH_EXTRA_CMAKE_ARGS=${ceph_extra_cmake_args}" >> .env
                        """
                        sh """#!/bin/bash -ex
                          cd dist/ceph
                          ln ../ceph-${env.VERSION}.tar.bz2 .
                          ${bwc_command}
                        """

                        if (os.pkg_type == "deb") {
                          sh """#!/bin/bash -ex
                            cd dist/ceph
                            ${bwc_command_base} -e custom -- "dpkg-deb --fsys-tarfile /ceph/debs/*/pool/main/c/ceph/cephadm_${VERSION}*.deb | tar -x -f - --strip-components=3 ./usr/sbin/cephadm"
                            ln ./cephadm ../../
                          """
                        } else if (env.DIST =~ /^(centos|rhel|rocky|fedora).*/) {
                          sh """#!/bin/bash -ex
                            cd dist/ceph
                            ${bwc_command_base} -e custom -- "rpm2cpio /ceph/rpmbuild/RPMS/noarch/cephadm-*.rpm | cpio -i --to-stdout *sbin/cephadm > cephadm"
                            ln ./cephadm ../../
                          """
                        }
                      }
                    }
                  }

                  stage("upload packages") {
                    if (build_matrix["${d}_${a}"] == true) {
                      withCredentials([
                        string(credentialsId: 'chacractl-key', variable: 'CHACRACTL_KEY'),
                        string(credentialsId: 'shaman-api-key',  variable: 'SHAMAN_API_KEY')
                      ]) {
                        def chacra_url = sh(script: '''grep url ~/.chacractl | cut -d'"' -f2''', returnStdout: true).trim()
                        def os = get_os_info(env.DIST)
                        if (os.pkg_type == "rpm") {
                          sh """#!/bin/bash
                              set -ex
                              cd ./dist/ceph
                              mkdir -p ./rpmbuild/SRPMS/
                              ln ceph-*.src.rpm ./rpmbuild/SRPMS/
                          """
                          env.SHA1 = (env.TEST?.toBoolean()) ? 'test' : env.SHA1

                          def spec_text = get_ceph_release_spec_text("${chacra_url}r/ceph/${env.BRANCH}/${env.SHA1}/${os.name}/${os.version_name}/flavors/${env.FLAVOR}/")
                          writeFile(file: "dist/ceph/rpmbuild/SPECS/ceph-release.spec", text: spec_text)

                          def repo_text = get_ceph_release_repo_text("${chacra_url}/r/ceph/${env.BRANCH}/${env.SHA1}/${os.name}/${os.version_name}/flavors/${env.FLAVOR}")
                          writeFile(file: "dist/ceph/rpmbuild/SOURCES/ceph.repo", text: repo_text)

                          def ceph_builder_tag = "${env.SHA1[0..6]}.${env.BRANCH}.${env.DIST}.${env.ARCH}.${env.FLAVOR}"
                          def bwc_command_base = "python3 src/script/build-with-container.py --image-repo=${env.CEPH_BUILDER_IMAGE} --tag=${ceph_builder_tag} -d ${env.DIST} --image-variant=packages --ceph-version ${env.VERSION}"
                          def bwc_command = "${bwc_command_base} -e custom -- rpmbuild -bb --define \\'_topdir /ceph/rpmbuild\\' /ceph/rpmbuild/SPECS/ceph-release.spec"
                          sh """#!/bin/bash
                            set -ex
                            cd \$WORKSPACE/dist/ceph
                            ${bwc_command}
                          """
                        }

                        sh """#!/bin/bash
                          export CHACRA_URL="${chacra_url}"
                          export OS_NAME="${os.name}"
                          export OS_VERSION="${os.version}"
                          export OS_VERSION_NAME="${os.version_name}"
                          export OS_PKG_TYPE="${os.pkg_type}"
                          if [ "$THROWAWAY" != "true" ]; then ./scripts/chacra_upload.sh; fi
                        """

                        def os2 = get_os_info(env.DIST)
                        sh "./scripts/update_shaman.sh completed ceph ${os2.name} ${os2.version_name} ${env.ARCH}"
                      }
                    }
                  }

                  stage("container") {
                    if ((env.CI_CONTAINER ?: '') == 'true' && env.DIST == 'centos9') {
                      withCredentials([
                        usernamePassword(credentialsId: 'quay-ceph-io-ceph-ci', usernameVariable: 'CONTAINER_REPO_CREDS_USR', passwordVariable: 'CONTAINER_REPO_CREDS_PSW')
                      ]) {
                        env.CONTAINER_REPO_USERNAME = env.CONTAINER_REPO_CREDS_USR
                        env.CONTAINER_REPO_PASSWORD = env.CONTAINER_REPO_CREDS_PSW
                        def distro  = sh(script: '. /etc/os-release && echo -n $ID',         returnStdout: true).trim()
                        def release = sh(script: '. /etc/os-release && echo -n $VERSION_ID', returnStdout: true).trim()
                        def cephver = env.VERSION.trim()
                        sh """#!/bin/bash
                          export DISTRO=${distro}
                          export RELEASE=${release}
                          export cephver=${cephver}
                          ./scripts/build_container
                        """
                      }
                    }
                  }

                  echo "success: ${env.DIST} ${env.ARCH} ${env.FLAVOR}"

                } catch (Throwable e) {
                  branchFailed = true
                  // emulate post { unsuccessful { ... } }
                  try {
                    def os = get_os_info(env.DIST)
                    sh "./scripts/update_shaman.sh failed ceph ${os.name} ${os.version_name} ${env.ARCH}"
                  } catch (Exception markFailedError) {
                    echo "update_shaman.sh failed: ${markFailedError}"
                  }
                  echo "failure: ${env.DIST} ${env.ARCH} ${env.FLAVOR}"
                  throw e

                } finally {
                  // emulate post { always { ... } }
                  try {
                    sh 'hostname'
                    sh 'sudo journalctl -k -c $(cat ${WORKSPACE}/cursor)'
                    sh 'podman unshare chown -R 0:0 ${WORKSPACE}/'

                    if (fileExists('dist/ceph/sccache_log.txt')) {
                      sh """
                        if [ -f "${env.WORKSPACE}/dist/ceph/sccache_log.txt" ]; then
                          ln dist/ceph/sccache_log.txt sccache_log_${env.DIST}_${env.ARCH}_${env.FLAVOR}.txt
                        fi
                      """
                      sh "find ${env.WORKSPACE}/dist/ceph/ -name .qa -exec rm {} \\;"
                      archiveArtifacts(artifacts: 'sccache_log*.txt', allowEmptyArchive: true, fingerprint: true)
                    }
                  } catch (Exception cleanupError) {
                    echo "Cleanup failed: ${cleanupError}"
                  }
                }
              } // withEnv
            } // node
          } // branch closure
        } // for flavors
      } // for archs
    } // for dists

    // Run the matrix in parallel
    parallel branches
  } // stage parallel build
} // run(Map)

return this

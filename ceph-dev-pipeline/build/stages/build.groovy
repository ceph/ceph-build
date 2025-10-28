def run(Map ctx) {
  def env = ctx.env
  def os = ctx.get_os_info(env.DIST)

  ctx.sh "./scripts/update_shaman.sh started ceph ${os.name} ${os.version_name} ${env.ARCH}"
  env.AWS_ACCESS_KEY_ID     = env.SCCACHE_BUCKET_CREDS_USR
  env.AWS_SECRET_ACCESS_KEY = env.SCCACHE_BUCKET_CREDS_PSW

  def ceph_builder_tag   = "${env.SHA1[0..6]}.${env.BRANCH}.${env.DIST}.${env.ARCH}.${env.FLAVOR}"
  def bwc_base           = "python3 src/script/build-with-container.py --image-repo=${env.CEPH_BUILDER_IMAGE} --tag=${ceph_builder_tag} -d ${env.DIST} --image-variant=packages --ceph-version ${env.VERSION}"
  def bwc_cmd            = bwc_base
  def bwc_envfile_flag   = ""

  if (env.DWZ == "false" || env.SCCACHE == "true") {
    ctx.sh "true > ${env.WORKSPACE}/.env"
  }
  if (env.DWZ == "false") {
    ctx.sh "echo 'DWZ=$DWZ' >> ${env.WORKSPACE}/.env"
    bwc_envfile_flag = "--env-file=${env.WORKSPACE}/.env"
  }
  if (env.SCCACHE == "true") {
    ctx.sh """cat >> ${env.WORKSPACE}/.env <<'EOF'
SCCACHE=true
SCCACHE_CONF=/ceph/sccache.conf
SCCACHE_ERROR_LOG=/ceph/sccache_log.txt
SCCACHE_LOG=debug
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
CEPH_BUILD_NORMALIZE_PATHS=true
EOF"""
    ctx.writeFile file: "dist/ceph/sccache.conf", text: """\
[cache.s3]
bucket = "ceph-sccache"
endpoint = "s3.us-south.cloud-object-storage.appdomain.cloud"
use_ssl = true
key_prefix = ""
server_side_encryption = false
no_credentials = false
region = "auto"
"""
    bwc_envfile_flag = "--env-file=${env.WORKSPACE}/.env"
  }

  def ceph_extra_cmake_args = ""
  def deb_build_profiles    = ""
  switch (env.FLAVOR) {
    case "default":
      ceph_extra_cmake_args += " -DALLOCATOR=tcmalloc"
      if (env.RELEASE_BUILD?.toBoolean()) {
        ceph_extra_cmake_args += " -DWITH_SYSTEM_BOOST=OFF -DWITH_BOOST_VALGRIND=ON"
      }
      break
    case ~/crimson.*/:
      deb_build_profiles = "pkg.ceph.crimson"
      break
    default:
      ctx.error "FLAVOR=${env.FLAVOR} is invalid"
  }

  bwc_cmd = "${bwc_cmd} ${bwc_envfile_flag}"
  if (os.pkg_type == "deb") {
    if (env.SCCACHE == "true" && !ceph_extra_cmake_args.contains("-DWITH_SCCACHE=ON")) {
      ceph_extra_cmake_args += " -DWITH_SCCACHE=ON"
    }
    if (deb_build_profiles) {
      ctx.sh "echo 'DEB_BUILD_PROFILES=${deb_build_profiles}' >> ${env.WORKSPACE}/.env"
    }
    bwc_cmd = "${bwc_cmd} -e debs"
  } else if (env.DIST =~ /^(centos|rhel|rocky|fedora).*/) {
    def rpmbuild_args = ""
    if (env.SCCACHE == "true")              rpmbuild_args += " -R--with=sccache"
    if (env.DWZ == "false")                 rpmbuild_args += " -R--without=dwz"
    if (env.FLAVOR == "default")            rpmbuild_args += " -R--with=tcmalloc"
    if (env.FLAVOR.startsWith("crimson"))   rpmbuild_args += " -R--with=crimson"
    bwc_cmd = "${bwc_cmd}${rpmbuild_args} -e rpm"
  } else {
    ctx.error "DIST '${env.DIST}' is invalid!"
  }

  ctx.sh "echo 'CEPH_EXTRA_CMAKE_ARGS=${ceph_extra_cmake_args}' >> ${env.WORKSPACE}/.env"
  ctx.sh """#!/bin/bash -ex
    cd dist/ceph
    ln ../ceph-${env.VERSION}.tar.bz2 .
    ${bwc_cmd}
  """

  if (os.pkg_type == "deb") {
    ctx.sh """#!/bin/bash -ex
      cd dist/ceph
      ${bwc_base} -e custom -- "dpkg-deb --fsys-tarfile /ceph/debs/*/pool/main/c/ceph/cephadm_${env.VERSION}*.deb | tar -x -f - --strip-components=3 ./usr/sbin/cephadm"
      ln ./cephadm ../../
    """
  } else {
    ctx.sh """#!/bin/bash -ex
      cd dist/ceph
      ${bwc_base} -e custom -- "rpm2cpio /ceph/rpmbuild/RPMS/noarch/cephadm-*.rpm | cpio -i --to-stdout *sbin/cephadm > cephadm"
      ln ./cephadm ../../
    """
  }
}
return this

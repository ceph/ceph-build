import groovy.transform.Field
@Field Map debian_releases = [
  "bookworm": "12",
  "bullseye": "11",
]
@Field Map ubuntu_releases = [
  "noble": "24.04",
  "jammy": "22.04",
  "focal": "20.04",
]

@NonCPS
def call(String dist) {
  def os = [
    "name": dist,
    "version": dist,
    "version_name": dist,
    "pkg_type": "NONE",
  ]
  def matcher = dist =~ /^(centos|rhel|rocky|alma|fedora)(\d+)/
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
    os.version = ubuntu_releases[env.DIST]
    os.pkg_type = "deb"
  }
  // We need to set matcher to null right after using it to avoid a java.io.NotSerializableException
  matcher = null
  return os
}

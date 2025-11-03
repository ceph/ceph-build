def build_source_dist(Map params) {
  def result = [:];
  if ( params.SETUP_BUILD_ID ) {
    result.SETUP_BUILD_ID = params.SETUP_BUILD_ID;
  } else {
    def setup_build = build(
      job: params.SETUP_JOB,
      parameters: [
        string(name: "BRANCH", value: params.BRANCH),
        // Below are just for ceph-source-dist
        string(name: "SHA1", value: params.SHA1),
        string(name: "CEPH_REPO", value: params.CEPH_REPO),
        string(name: "CEPH_BUILD_BRANCH", value: params.CEPH_BUILD_BRANCH),
        // Below are only for actual releases
        string(name: 'RELEASE_TYPE',  value: params.RELEASE_TYPE ?: ''),
        string(name: 'RELEASE_BUILD', value: params.RELEASE_BUILD ?: ''),
        string(name: 'VERSION',       value: params.VERSION ?: '')
      ]
    )
    result.SETUP_BUILD_ID = setup_build.getNumber()
  }
  println "SETUP_BUILD_ID=${params.SETUP_BUILD_ID}"
  result.SETUP_BUILD_URL = new URI([params.JENKINS_URL, "job", params.SETUP_JOB, params.SETUP_BUILD_ID].join("/")).normalize()
  println "${result.SETUP_BUILD_URL}"
  return result;
}

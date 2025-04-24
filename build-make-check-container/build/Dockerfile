# This is just the default.  Overridden by `docker build --build-arg DISTRO=$DISTRO` at build time
ARG DISTRO='ubuntu:20.04'
FROM $DISTRO
RUN if command -v yum; then \
      yum install -y epel-release; \
      yum install -y git sudo ccache clang; \
      yum update -y; \
    else \
      apt update && DEBIAN_FRONTEND="noninteractive" apt install -y git-core sudo ccache; \
    fi
RUN git clone https://github.com/ceph/ceph /opt/ceph
RUN git clone https://github.com/ceph/ceph-ci /opt/ceph-ci
# Set some defaults (again, overridden using --build-arg)
ARG INSTALL_DEPS_REPO=ceph
ARG INSTALL_DEPS_BRANCH=master
RUN cd /opt/$INSTALL_DEPS_REPO \
    && if ! git checkout $INSTALL_DEPS_BRANCH; then \
      echo $INSTALL_DEPS_BRANCH doesn\'t exist; \
      exit 1; \
    fi \
    && DEBIAN_FRONTEND="noninteractive" ./install-deps.sh \
    && git submodule update --init --recursive
# Doesn't work yet
#    # To populate ccache
#    && ./src/script/run-make.sh \
#    && rm -rf build
# Some defaults.  Overridden by `docker run -e VAR=$VAR` at runtime
ENV REPO=${REPO:-ceph}
ENV BRANCH=${BRANCH:-master}
ENV PULLREQUEST_ID=${PULLREQUEST_ID}
# Uncertain on the proper order here.  Do I need to `pull` after checking out the branch again?
CMD cd /opt/$REPO \
    && git fetch --all \
    && if [ "$PULLREQUEST_ID" == "" ]; then \
         echo "PULLREQUEST_ID was not defined.  Using the \$BRANCH var"; \
         echo -e "****************\n\nChecking out branch: $BRANCH\n\n****************"; \
         git checkout $BRANCH; \
         git pull; \
       else \
         echo -e "****************\n\nChecking out Pull Request ID: $PULLREQUEST_ID\n\n****************"; \
         git fetch origin pull/$PULLREQUEST_ID/head:PR$PULLREQUEST_ID; \
         git checkout PR$PULLREQUEST_ID; \
       fi \
    && ./install-deps.sh \
    && timeout 3h ./run-make-check.sh

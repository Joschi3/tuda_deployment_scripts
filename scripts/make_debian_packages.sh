#!/bin/bash

. $(dirname $0)/helper/globals.sh
. $(dirname $0)/helper/log_output.sh

cd $ROSWSS_ROOT

DEB_BUILD_PATH="$DEB_BASE_PATH/build"
DEB_DEVEL_PATH="$DEB_BASE_PATH/devel"
BUILD_TIMESTAMP="$(date -u "+%Y%m%d-%H%M%SUTC")"

function add_debian_pkg_to_rosdep() {
    local PKG_NAME=$1
    local DEBIAN_PKG_NAME=$2
    local ROSDEP_FILE=${APT_REPO_PATH}/${ROSWSS_PROJECT_NAME}.yaml
    cat $ROSDEP_FILE | grep -e "^${PKG_NAME}:" >/dev/null 2>&1 || create_rosdep_entry "${PKG_NAME}" "${DEBIAN_PKG_NAME}" >> $ROSDEP_FILE
}

function build_deb_from_ros_package() {
    local PKG_BUILD_PATH=$1
    if [ ! -d "${PKG_BUILD_PATH}" ]; then
        error "Build path for package does not exist: '$PKG_BUILD_PATH'"
        return -1;
    fi
    
    local PKG_NAME=$(basename ${PKG_BUILD_PATH})
    local DEBIAN_PKG_NAME_PROJECT=$(to_debian_pkg_name "$PKG_NAME")

    rm $APT_REPO_PATH/$DEBIAN_PKG_NAME_PROJECT*.deb 2>/dev/null
    rm $APT_REPO_PATH/$DEBIAN_PKG_NAME_PROJECT*.ddeb 2>/dev/null

    # search for package src path locally to make sure we find local packages, not released ones in /opt/ros/...
    #PKG_SRC_PATH=$(egrep -lir --include=package.xml "<name>$PKG_NAME</name>" ${ROSWSS_ROOT}/src | xargs dirname)
    local PKG_SRC_PATH=$(catkin locate --workspace $ROSWSS_ROOT --profile deb_pkgs --src $PKG_NAME 2>/dev/null)

    local PKG_IS_GIT_PKG=0
    local PKG_GIT_BRANCH
    local PKG_GIT_COMMIT
    local PKG_GIT_URL
    cd ${PKG_SRC_PATH}
    git branch >/dev/null 2>&1 && {
        # This is only executed if this is a git repository
        PKG_IS_GIT_PKG=1
        PKG_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        # Get commit id of 4 or more characters (minimal length to ensure uniqueness)
        PKG_GIT_COMMIT=$(git rev-parse --short HEAD)
        PKG_GIT_URL=$(git remote get-url $(git remote))
    }

    cd ${PKG_BUILD_PATH}

    # clean up previous deb build
    if [ -d debian ]; then
        rm -rf debian
    fi

    # generate debian package control files in "debian" directory
    bloom-generate rosdebian --debug --os-name ${OS_NAME} --os-version ${OS_VERSION} --ros-distro ${ROS_DISTRO} ${PKG_SRC_PATH} >bloom.log #2>&1
    local RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
        error "Generation of deb package control files failed for package '$PKG_NAME'."
        error "See $(readlink -f bloom.log) for details."
        return ${RESULT}
    fi

    # rename package to avoid conflicts with publicly released ones
    local DEBIAN_PKG_NAME_ROS=ros-${ROS_DISTRO}-$(echo ${PKG_NAME} | tr '_' '-')
    find ./debian -type f -print0 | xargs -0 sed -i 's/'"$DEBIAN_PKG_NAME_ROS"'/'"$DEBIAN_PKG_NAME_PROJECT"'/g'

    # use environment setup of this workspace
    sed -i -e 's:/opt/ros/melodic/setup.sh:'"${DEB_DEVEL_PATH}"'/setup.sh:g' debian/rules

    # use standard make instead of cmake to build the binaries
    sed -i -e 's:-v --buildsystem=cmake::g' debian/rules

    # set install prefix in make files
    local CMAKE_INSTALL_PREFIX="/opt/${ROSWSS_PROJECT_NAME}"
    cmake -DCMAKE_INSTALL_PREFIX="$CMAKE_INSTALL_PREFIX" -DCATKIN_BUILD_BINARY_PACKAGE="1" . >cmake.log 2>&1
    sed -i -e 's:CMAKE_INSTALL_PREFIX="/opt/ros/melodic":CMAKE_INSTALL_PREFIX="'"$CMAKE_INSTALL_PREFIX"'":g' debian/rules
    sed -i -e 's://opt/ros/melodic/lib/:'"$CMAKE_INSTALL_PREFIX"'/lib:g' debian/rules

    # disable lib dependency checking TODO: fix ceres_catkin and glog_catkin so they work without this
    #sed -i -e 's:dh_shlibdeps -l:dh_shlibdeps --dpkg-shlibdeps-params=--ignore-missing-info -l:g' debian/rules
    sed -i -e 's:dh_shlibdeps -l:return 0 #:g' debian/rules

    # set output dir for the deb package
    echo "" >>debian/rules
    echo "override_dh_builddeb:" >>debian/rules
    echo -e "\tdh_builddeb --destdir=$APT_REPO_PATH" >>debian/rules

    # prevent dh_fixperms to change file permissions in /etc and /root
    echo "" >>debian/rules
    echo "override_dh_fixperms:" >>debian/rules
    echo -e "\tdh_fixperms -X/etc/ -X/root/" >>debian/rules

    # append current UTC date-time to version
    local BUILD_INFO=$BUILD_TIMESTAMP
    # If this is a git repository, we include the branch and commit hash in the version:
    if [ ${PKG_IS_GIT_PKG} -ne 0 ]; then
      # Append commit id to version
      BUILD_INFO="${BUILD_INFO}-${PKG_GIT_COMMIT}"

      # Add Url including branch to control file
      sed -i -r 's/^(Homepage:.*)$/Homepage: '"$(echo "${PKG_GIT_URL}#${PKG_GIT_BRANCH}" | sed 's/\//\\\//g')"'/' debian/control
    fi
    # Add info that this package replaces the ros debian package if a ros debian package exists already
    if apt show $DEBIAN_PKG_NAME_ROS 2&>1 >/dev/null; then
        sed -i "/^Depends:.*/a Provides: ${DEBIAN_PKG_NAME_ROS}" debian/control
    fi
    sed -i -e '1 s:'"$OS_VERSION"'):'"$OS_VERSION"'-'"$BUILD_INFO"'):g' debian/changelog

    # start the build process for the deb package
    fakeroot debian/rules binary >debian/build.log 2>&1
    RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
        error "Compilation of deb package failed for package '$PKG_NAME'."
        error "See $(readlink -f debian/build.log) for details."
        return ${RESULT}
    fi
    add_debian_pkg_to_rosdep "${PKG_NAME}" "${DEBIAN_PKG_NAME_PROJECT}"
    success "Compiled deb package '$PKG_NAME'."
}

function parallel_build_deb_packages() {
    local BUILD_COUNT=0
    local SUCCESSES=0
    local TOTAL=$(echo $@ | wc -w)
    local QUEUE=( $@ )
    
    function build_package() {
        build_deb_from_ros_package "${DEB_BUILD_PATH}/${PACKAGE}"
        return $?
    }

    function ready_to_build() {
        SUB_DEPENDENCIES=$(rospack depends $PACKAGE 2> /dev/null)
        # If rospack depends failed because one dependency is not a proper ROS dependency, we
        # try again using a slower custom implementation, this shouldn't be necessary anymore
        # with noetic upwards if they accepted my PR
        if [[ $? != 0 ]]; then
            SUB_DEPENDENCIES=$(find_dependencies $PACKAGE)
        fi
        for DEPENDENCY in $SUB_DEPENDENCIES; do
            for PKG in $QUEUE; do
                if [[ "$PKG" == "$DEPENDENCY" ]]; then
                    return 1
                fi
            done
        done
        return 0
    }
    
    # Dont build parallel without dependency management
    #local MAX_THREADS
    ## build deb packages in parallel
    #if [ "$ROS_PARALLEL_JOBS" = "" ]; then
    #    MAX_THREADS=4
    #else
    #    MAX_THREADS=$(echo $ROS_PARALLEL_JOBS | egrep -o "[0-9]+")
    #fi
    while [ ! -z "${QUEUE}" ]; do
        PACKAGE=${QUEUE[@]:0:1}
        QUEUE=( ${QUEUE[@]:1} )
        if ! ready_to_build; then
            QUEUE="$QUEUE $PACKAGE"
            continue
        fi
        BUILD_COUNT=$((BUILD_COUNT+1))
        if build_package; then
            SUCCESSES=$((SUCCESSES+1))
            info "Finished $BUILD_COUNT of $TOTAL builds. ($SUCCESSES successful)"
        else
            error "Build of $PACKAGE failed!"
        fi
        
    done
    # # wait for remaining jobs
    # while [ "$(jobs | wc -l)" -gt 0 ]; do
    #     wait_with_status
    # done
    
    if [[ $SUCCESSES != $TOTAL ]]; then
      return 1
    fi
}

which bloom-generate >/dev/null || {
    echo -e "Please install 'bloom-generate' command:\nsudo apt install python-bloom"
    exit 1
}

# call rosdep_add_local_packages script
for dir in ${ROSWSS_SCRIPTS//:/ }; do
    if [ -x "${dir}/rosdep_add_local_packages.sh" ]; then
        ${dir}/rosdep_add_local_packages.sh || exit $?
        break
    fi
done

# create catkin profile for deb package builds
catkin profile --workspace $ROSWSS_ROOT remove deb_pkgs >/dev/null 2>&1
catkin config  --workspace $ROSWSS_ROOT --profile deb_pkgs --build-space ${DEB_BUILD_PATH} \
    --devel-space ${DEB_DEVEL_PATH} --install-space "/opt/${ROSWSS_PROJECT_NAME}" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null 2>&1

info "Cleaning packages..."
catkin clean --workspace $ROSWSS_ROOT --profile deb_pkgs $@

info "Building packages..."
catkin build --no-status --force-color --workspace $ROSWSS_ROOT --profile deb_pkgs $@ || exit 1

function _find_dependencies {
  for item in "${PKG_DEPENDENCIES[@]}"; do
    [[ "$1" == "$item" ]] && return
  done
  echo $1
  PKG_DEPENDENCIES+=("$1")
  for DEPENDENCY in $(rosdep keys $1); do
    rospack find $DEPENDENCY 2> /dev/null | egrep --quiet "^${ROSWSS_ROOT}/src" && _find_dependencies $DEPENDENCY
  done
}

function find_dependencies {
  local PKG_DEPENDENCIES=()
  for DEPENDENCY in $(rosdep keys $1); do
    rospack find $DEPENDENCY 2> /dev/null | egrep --quiet "^${ROSWSS_ROOT}/src" && _find_dependencies $DEPENDENCY
  done
}

info "Start building deb packages with timestamp $BUILD_TIMESTAMP"
mkdir -p ${APT_REPO_PATH}
if [ -z "$1" ]; then
    #PACKAGES=$(find ${DEB_BUILD_PATH}/* -maxdepth 0 -type d -not -name catkin_tools_prebuild)
    PACKAGES=$(catkin list --workspace $ROSWSS_ROOT --profile deb_pkgs --unformatted)
else
    PACKAGES=""
    if [ "$1" = "--no-deps" ]; then
        shift
    else
        # find dependencies that are within this workspace and build them as well
        DEPENDENCIES=$({
            for PACKAGE in $@; do
                SUB_DEPENDENCIES=$(rospack depends $PACKAGE 2> /dev/null)
                # If rospack depends failed because one dependency is not a proper ROS dependency, we
                # try again using a slower custom implementation, this shouldn't be necessary anymore
                # with noetic upwards if they accepted my PR
                if [[ $? != 0 ]]; then
                    SUB_DEPENDENCIES=$(find_dependencies $PACKAGE)
                fi
                for DEPENDENCY in $SUB_DEPENDENCIES; do
                    rospack find $DEPENDENCY | egrep --quiet "^${ROSWSS_ROOT}/src" && echo $DEPENDENCY
                done
            done
        } | sort -u)

        for PACKAGE in $DEPENDENCIES; do
            PACKAGES="$PACKAGES $PACKAGE"
        done
    fi

    for PACKAGE in $@; do
        PACKAGES="$PACKAGES $PACKAGE"
    done
fi

parallel_build_deb_packages "${PACKAGES}"
RESULT=$?
info "Done building. (Error code: ${RESULT})"
exit $RESULT

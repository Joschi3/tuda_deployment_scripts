#!/bin/bash

. "$(dirname "$0")/helper/globals.sh"
. "$(dirname "$0")/helper/log_output.sh"

#chek that ROSWSS_PROJECT_NAME is set
[ -z "$ROSWSS_PROJECT_NAME" ] && error "ROSWSS_PROJECT_NAME is not set. Set it to the name of the project (e.g. hector)!" && exit 1

# check that ROSWSS_ROOT is set
[ -z "$ROSWSS_ROOT" ] && error "ROSWSS_ROOT is not set. Set it to the Workspace root!" && exit 1

BASE_PATH="$(readlink -f "$(dirname "$(readlink -f "$0")")/..")"
echo "BASE_PATH: $BASE_PATH"
DEB_BUILD_PATH="$DEB_BASE_PATH/build"
BUILD_TIMESTAMP="$(date -u "+%Y%m%d-%H%M%SUTC")"

cd "${ROSWSS_ROOT}" || exit 1

function add_debian_pkg_to_rosdep() {
    local PKG_NAME=$1
    local DEBIAN_PKG_NAME=$2
    local ROSDEP_FILE=${APT_REPO_PATH}/${ROSWSS_PROJECT_NAME}.yaml
    echo "Adding debian package '$DEBIAN_PKG_NAME' to rosdep file '$ROSDEP_FILE'"
    grep -e "^${PKG_NAME}:" "$ROSDEP_FILE" >/dev/null 2>&1 || create_rosdep_entry "${PKG_NAME}" "${DEBIAN_PKG_NAME}" >>"$ROSDEP_FILE"
    grep -e "^${PKG_NAME}:" "$ROSDEP_YAML_FILE" >/dev/null 2>&1 || create_rosdep_entry "${PKG_NAME}" "${DEBIAN_PKG_NAME}" >>"$ROSDEP_YAML_FILE"
}

# Function to find local dependencies of a specified package in a ROS workspace
find_local_dependencies() {
    local package_name=$1
    local local_packages
    local dependencies
    local package_dir

    # List all local packages in the workspace
    local_packages=$(colcon list --names-only --base-paths "${ROSWSS_ROOT}")
    if [[ -z "$local_packages" ]]; then
        echo "No packages found in the workspace."
        return 1
    fi

    # Find the directory of the specified package
    package_dir=$(ros2 pkg prefix "$package_name" --share)

    # Get all dependencies from package.xml
    if [ ! -f "$package_dir/package.xml" ]; then
        echo "No package.xml found for '$package_name'."
        return 1
    fi

    # Extract dependencies
    dependencies=$(grep -Po '(?<=<depend>)\w+|(?<=<build_depend>)\w+|(?<=<exec_depend>)\w+' "$package_dir/package.xml")

    # Check which dependencies are also local
    local local_dependencies=()
    for dep in $dependencies; do
        if [[ "$dep" != "$package_name" ]] && echo "$local_packages" | grep -wq "$dep"; then
            local_dependencies+=("$dep")
        fi
    done

    # Output local dependencies
    if [ ${#local_dependencies[@]} -eq 0 ]; then
        echo "No local dependencies found for '$package_name'."
        echo ""
    else
        for dep in "${local_dependencies[@]}"; do
            echo "$dep"
        done
    fi
}

function build_deb_from_ros_package() {
    local PKG_BUILD_PATH=$1
    if [ ! -d "${PKG_BUILD_PATH}" ]; then
        mkdir "${PKG_BUILD_PATH}"
        #error "Build path for package does not exist: '$PKG_BUILD_PATH'"
        #return -1;
    fi

    local PKG_NAME=$(basename "${PKG_BUILD_PATH}")
    local DEBIAN_PKG_NAME_PROJECT=$(to_debian_pkg_name "$PKG_NAME")

    # Delete OLD leftover debian packages
    rm "$APT_REPO_PATH"/"${DEBIAN_PKG_NAME_PROJECT}"_*.deb 2>/dev/null
    rm "$APT_REPO_PATH"/"${DEBIAN_PKG_NAME_PROJECT}"_*.ddeb 2>/dev/null

    # search for package src path locally to make sure we find local packages, not released ones in /opt/ros/...
    local PKG_SRC_PATH="${ROSWSS_ROOT}"/$(colcon info "$PKG_NAME" | grep 'path:' | awk '{print $2}')

    local PKG_IS_GIT_PKG=0
    local PKG_GIT_BRANCH
    local PKG_GIT_COMMIT
    local PKG_GIT_URL
    cd "${PKG_SRC_PATH}" || {
        error "Failed to change to package source directory: '${PKG_SRC_PATH}'"
        return 1
    }
    git branch >/dev/null 2>&1 && {
        # This is only executed if this is a git repository
        PKG_IS_GIT_PKG=1
        PKG_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        # Get commit id of 4 or more characters (minimal length to ensure uniqueness)
        PKG_GIT_COMMIT=$(git rev-parse --short HEAD)
        PKG_GIT_URL=$(git remote get-url "$(git remote)")
    }

    # clean up previous deb build
    if [ -d debian ]; then
        rm -rf debian
    fi
    # generate debian package control files in "debian" directory
    local LOG_FILE=${LOG_FOLDER}/${PKG_NAME}/bloom.log
    mkdir -p "$(dirname "${LOG_FILE}")"
    bloom-generate rosdebian --debug --os-name "${OS_NAME}" --os-version "${OS_VERSION}" --ros-distro "${ROS_DISTRO}" >"${LOG_FILE}" 2>&1
    local RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
        error "Generation of deb package control files failed for package '$PKG_NAME'."
        error "See $(readlink -f bloom.log) for details."
        return ${RESULT}
    fi
    PACKAGE_NAME_HYPHEN=$(echo "${PKG_NAME}" | tr '_' '-')
    BUILD_TYPE="RelWithDebInfo" # Change to Debug, Release, or any other build type
    NEW_INSTALL_DIR="/opt/${ROSWSS_PROJECT_NAME}/${ROS_DISTRO}"
    # rename package from ros-<distro>-<package_name> to hector-<distro>-<package_name>
    sed -i "s/ros-${ROS_DISTRO}-${PACKAGE_NAME_HYPHEN}/${DEBIAN_PKG_NAME_PROJECT}/g" debian/control
    sed -i "s/ros-${ROS_DISTRO}-${PACKAGE_NAME_HYPHEN}/${DEBIAN_PKG_NAME_PROJECT}/g" debian/rules
    sed -i "s/ros-${ROS_DISTRO}-${PACKAGE_NAME_HYPHEN}/${DEBIAN_PKG_NAME_PROJECT}/g" debian/changelog

    # Modify rules file
    sed -i "s|/opt/ros/${ROS_DISTRO}|${NEW_INSTALL_DIR}|g" debian/rules
    sed -i "s|CMAKE_BUILD_TYPE=.*|CMAKE_BUILD_TYPE=${BUILD_TYPE} \\\\|g" debian/rules

    # use environment setup of this workspace
    #sed -i -e 's:/opt/ros/'"${ROS_DISTRO}"'/setup.sh:'"${DEB_DEVEL_PATH}"'/setup.sh:g' debian/rules

    # use standard make instead of cmake to build the binaries
    sed -i -e 's:-v --buildsystem=cmake::g' debian/rules

    # disable lib dependency checking TODO: fix ceres_catkin and glog_catkin so they work without this
    #sed -i -e 's:dh_shlibdeps -l:dh_shlibdeps --dpkg-shlibdeps-params=--ignore-missing-info -l:g' debian/rules
    sed -i -e 's:dh_shlibdeps -l:return 0 #:g' debian/rules

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
    if apt show $DEBIAN_PKG_NAME_ROS 2 &>1 >/dev/null; then
        sed -i "/^Depends:.*/a Provides: ${DEBIAN_PKG_NAME_ROS}" debian/control
    fi
    sed -i -e '1 s:'"$OS_VERSION"'):'"$OS_VERSION"'-'"$BUILD_INFO"'):g' debian/changelog

    # start the build process for the deb package
    local BUILD_LOG_FILE=${LOG_FOLDER}/${PKG_NAME}/build.log
    #fakeroot debian/rules binary > ${BUILD_LOG_FILE} 2>&1
    dpkg-buildpackage -b -d -uc -us -ui >"${BUILD_LOG_FILE}" 2>&1

    RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
        error "Compilation of deb package failed for package '$PKG_NAME'."
        error "See ${BUILD_LOG_FILE} for details."
        return ${RESULT}
    fi

    local OUTPUT_FILE=$(ls -1 .. | grep "^${DEBIAN_PKG_NAME_PROJECT}_.*\.deb$" | tail -1)
    if [ -z "${OUTPUT_FILE}" ] || ! [ -f "../${OUTPUT_FILE}" ]; then
        error "No deb was generated despite compilation being successful!"
        return 1
    fi

    mv "../${OUTPUT_FILE}" "${APT_REPO_PATH}"
    RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
        error "Failed to move deb file to output directory!"
        return 1
    fi
    add_debian_pkg_to_rosdep "${PKG_NAME}" "${DEBIAN_PKG_NAME_PROJECT}"

    success "Compiled deb package '$PKG_NAME'."
}

function parallel_build_deb_packages() {
    local PROCESSING=0
    local TOTAL=$(echo "$@" | wc -w)
    local QUEUE=("$@")
    local NEW_QUEUE
    local READY_TO_BUILD_QUEUE
    local EXIT_CODE=0
    local BLACKLISTED=$("${BASE_PATH}"/scripts/get_blacklisted_packages.py --workspace "${ROSWSS_ROOT}")

    function ready_to_build() {
        local SUB_DEPENDENCIES
        SUB_DEPENDENCIES=$(find_local_dependencies "$PACKAGE")
        for DEPENDENCY in $SUB_DEPENDENCIES; do
            for PKG in "${QUEUE[@]}"; do
                if [[ "$PKG" == "$DEPENDENCY" ]]; then
                    return 1
                fi
            done
        done
        return 0
    }

    # Remove blacklisted packages
    NEW_QUEUE=""
    for PACKAGE in "${QUEUE[@]}"; do
        if [[ ${BLACKLISTED} =~ (^|[[:space:]])"${PACKAGE}"($|[[:space:]]) ]]; then
            continue
        fi
        NEW_QUEUE="$NEW_QUEUE $PACKAGE"
    done
    QUEUE=($NEW_QUEUE)

    # Dont build parallel without dependency management
    local MAX_THREADS
    # build deb packages in parallel
    if [ "$ROS_PARALLEL_JOBS" = "" ]; then
        MAX_THREADS=4
    else
        MAX_THREADS=$(echo $ROS_PARALLEL_JOBS | egrep -o "[0-9]+")
    fi
    # Unfortunately it is not easy to keep track of which packages failed because wait PID only works for some time
    # after the subprocess ended. It would require to test each PID of the active jobs whenever wait -n terminates to see
    # which job(s) ended
    while [ ! -z "$QUEUE" ]; do
        NEW_QUEUE=""
        READY_TO_BUILD_QUEUE=""
        for PACKAGE in "${QUEUE[@]}"; do
            if ready_to_build $PACKAGE; then
                echo "Ready to build: $PACKAGE"
                READY_TO_BUILD_QUEUE="$READY_TO_BUILD_QUEUE $PACKAGE"
            else
                NEW_QUEUE="$NEW_QUEUE $PACKAGE"
                echo "Not ready to build: $PACKAGE"
                echo "Unmet Dependencies: $(find_local_dependencies $PACKAGE)"
            fi
        done
        QUEUE=($NEW_QUEUE)
        for PACKAGE in ${READY_TO_BUILD_QUEUE[@]}; do
            if [ "$(jobs | wc -l)" -ge $MAX_THREADS ]; then
                if ! wait -n; then
                    EXIT_CODE=1
                fi
            fi
            PROCESSING=$((PROCESSING + 1))
            info "[$PROCESSING/$TOTAL] Started build of $PACKAGE"
            build_deb_from_ros_package "${DEB_BUILD_PATH}/$PACKAGE" &
        done
        # wait for remaining jobs (normal wait for all processes always finishes with 0)
        while [ "$(jobs | wc -l)" -gt 0 ]; do
            if ! wait -n; then
                EXIT_CODE=1
            fi
        done
    done

    if [ $EXIT_CODE -ne 0 ]; then
        error "Some builds failed!"
    fi
    return $EXIT_CODE
}

which bloom-generate >/dev/null || {
    echo -e "Please install 'bloom-generate' command:\nsudo apt install python-bloom"
    exit 1
}

# call rosdep_add_local_packages script
for dir in ${ROSWSS_SCRIPTS//:/ }; do
    if [ -x "${dir}/rosdep_add_local_packages.sh" ]; then
        "${dir}"/rosdep_add_local_packages.sh || exit $?
        break
    fi
done

info "Building packages..."
FILTERED_ARGS=()
for arg in "$@"; do
    if [[ $arg != -* ]]; then
        FILTERED_ARGS+=("$arg")
    fi
done

# Check if filtered arguments are provided
if [ ${#FILTERED_ARGS[@]} -gt 0 ]; then
    info "Building specified packages: ${FILTERED_ARGS[@]}"
    colcon build --base-paths "$ROSWSS_ROOT" --build-base "${DEB_BUILD_PATH}" --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo --packages-up-to "${FILTERED_ARGS[@]}" || exit 1
else
    info "Building all packages in the workspace."
    colcon build --base-paths "$ROSWSS_ROOT" --build-base "${DEB_BUILD_PATH}" --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo || exit 1
fi

info "Start building deb packages with timestamp $BUILD_TIMESTAMP"
mkdir -p "${APT_REPO_PATH}"
if [ -z "$1" ]; then
    info "No packages specified, building all packages in workspace."
    PACKAGES=$(colcon list --base-paths "$ROSWSS_ROOT" --names-only)
else
    PACKAGES=""
    if [ "$1" = "--no-deps" ]; then
        shift
        for PACKAGE in "$@"; do
            PACKAGES="$PACKAGES $PACKAGE"
        done
    else
        info "Building package dependencies as well."
        # find dependencies that are within this workspace and build them as well
        DEPENDENCIES=$({
            for PACKAGE in "$@"; do
                echo "$PACKAGE"
                SUB_DEPENDENCIES=$(find_local_dependencies "$PACKAGE")
                for DEPENDENCY in $SUB_DEPENDENCIES; do
                    echo "$DEPENDENCY" # dependency is already checked in find_dependencies
                done
            done
        } | sort -u)

        for PACKAGE in $DEPENDENCIES; do
            PACKAGES="$PACKAGES $PACKAGE"
        done
    fi
fi
info "Start building packages: $PACKAGES"
parallel_build_deb_packages "${PACKAGES}"
RESULT=$?
info "Done building. (Error code: ${RESULT})"
exit $RESULT

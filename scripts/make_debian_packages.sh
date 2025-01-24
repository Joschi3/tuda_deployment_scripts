#!/bin/bash

. "$(dirname "$0")/helper/globals.sh"
. "$(dirname "$0")/helper/log_output.sh"
. "$(dirname "$0")/rosdep_add_local_packages.sh" || exit $?

#chek that ROSWSS_PROJECT_NAME is set
[ -z "$ROSWSS_PROJECT_NAME" ] && error "ROSWSS_PROJECT_NAME is not set. Set it to the name of the project (e.g. hector)!" && exit 1

# check that ROSWSS_ROOT is set
[ -z "$ROSWSS_ROOT" ] && error "ROSWSS_ROOT is not set. Set it to the Workspace root!" && exit 1

BASE_PATH="$(readlink -f "$(dirname "$(readlink -f "$0")")/..")"
echo "BASE_PATH: $BASE_PATH"
DEB_BUILD_PATH="$DEB_BASE_PATH/build"
BUILD_TIMESTAMP="$(date -u "+%Y%m%d-%H%M%SUTC")"

cd "${ROSWSS_ROOT}" || exit 1

# make sure the log folder exists
mkdir -p "${LOG_FOLDER}"

# Define the lock file for mutual exclusion
LOCK_FILE="/tmp/dpkg_install.lock"

# Function to install the deb package
function install_deb_package() {
    local OUTPUT_FILE=$1
    local PKG_NAME=$2

    flock "$LOCK_FILE" dpkg -i "../${OUTPUT_FILE}" || {
        error "Failed to install deb package '$PKG_NAME'."
        return 1
    }
}

function add_debian_pkg_to_rosdep() {
    local PKG_NAME=$1
    local DEBIAN_PKG_NAME=$2
    local ROSDEP_FILE=${APT_REPO_PATH}/${ROSWSS_PROJECT_NAME}.yaml
    echo "Adding debian package '$DEBIAN_PKG_NAME' to rosdep file '$ROSDEP_FILE'"
    grep -e "^${PKG_NAME}:" "$ROSDEP_FILE" >/dev/null 2>&1 || create_rosdep_entry "${PKG_NAME}" "${DEBIAN_PKG_NAME}" >>"$ROSDEP_FILE"
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
        exit 1
    fi

    # Find the directory of the specified package
    package_dir=$(colcon info "$package_name" | grep -oP '(?<=path: ).*')

    if [ -z "$package_dir" ]; then
        echo "Error: Package '$package_name' not found."
        exit 1
    fi

    # Get all dependencies from package.xml
    if [ ! -f "$package_dir/package.xml" ]; then
        echo "No package.xml found for '$package_name'."
        exit 1
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
        #echo "No local dependencies found for '$package_name'."
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
    fi

    local PKG_NAME=$(basename "${PKG_BUILD_PATH}")
    local DEBIAN_PKG_NAME_PROJECT=$(to_debian_pkg_name "$PKG_NAME")

    # Delete OLD leftover debian packages
    rm "$APT_REPO_PATH"/"${DEBIAN_PKG_NAME_PROJECT}"_*.deb 2>/dev/null
    rm "$APT_REPO_PATH"/"${DEBIAN_PKG_NAME_PROJECT}"_*.ddeb 2>/dev/null

    # Determine package source path
    local PKG_SRC_PATH="${ROSWSS_ROOT}"/$(colcon info "$PKG_NAME" | grep 'path:' | awk '{print $2}')

    # Clean up source directory before building
    cd "${PKG_SRC_PATH}" || {
        error "Failed to change to package source directory: '${PKG_SRC_PATH}'"
        return 1
    }
    rm -rf build dist *.egg-info .pytest_cache 2>/dev/null

    # Generate debian package control files
    local LOG_FILE=${LOG_FOLDER}/${PKG_NAME}/bloom.log
    mkdir -p "$(dirname "${LOG_FILE}")"
    bloom-generate rosdebian --os-name "${OS_NAME}" --os-version "${OS_VERSION}" --ros-distro "${ROS_DISTRO}" >"${LOG_FILE}" 2>&1
    if [ $? -ne 0 ]; then
        error "Failed to generate debian package control files for package '$PKG_NAME'."
        return 1
    fi

    # Update control and rules files
    local PACKAGE_NAME_HYPHEN=$(echo "${PKG_NAME}" | tr '_' '-')
    sed -i "s/ros-${ROS_DISTRO}-${PACKAGE_NAME_HYPHEN}/${DEBIAN_PKG_NAME_PROJECT}/g" debian/control debian/rules debian/changelog
    sed -i "s|/opt/ros/${ROS_DISTRO}|/opt/${ROSWSS_PROJECT_NAME}/${ROS_DISTRO}|g" debian/rules
    sed -i 's:-v --buildsystem=cmake::g' debian/rules

    # Exclude unnecessary files during the build
    echo -e "\noverride_dh_install:\n\tdh_install --exclude=.pytest_cache --exclude=*.egg-info" >> debian/rules

    # Append build info to changelog
    local BUILD_INFO=$BUILD_TIMESTAMP
    sed -i -e '1 s:'"$OS_VERSION"'):'"$OS_VERSION"'-'"$BUILD_INFO"'):g' debian/changelog

    # Build the package
    local BUILD_LOG_FILE=${LOG_FOLDER}/${PKG_NAME}/build.log
    dpkg-buildpackage -b -d -uc -us -ui >"${BUILD_LOG_FILE}" 2>&1
    if [ $? -ne 0 ]; then
        error "Compilation of deb package failed for package '$PKG_NAME'."
        return 1
    fi

    # Move the package to the APT repository
    local OUTPUT_FILE=$(ls -1 .. | grep "^${DEBIAN_PKG_NAME_PROJECT}_.*\.deb$" | tail -1)
    if [ -z "${OUTPUT_FILE}" ] || ! [ -f "../${OUTPUT_FILE}" ]; then
        error "No deb was generated despite compilation being successful!"
        return 1
    fi
    mv "../${OUTPUT_FILE}" "${APT_REPO_PATH}" || {
        error "Failed to move deb file to output directory!"
        return 1
    }

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

    # TODO: remove
    # iterate packages and print their local dependencies
    for PACKAGE in ${QUEUE[@]}; do
        find_local_dependencies "$PACKAGE"
    done

    function ready_to_build() {
        local SUB_DEPENDENCIES
        SUB_DEPENDENCIES=$(find_local_dependencies "$PACKAGE")
        for DEPENDENCY in $SUB_DEPENDENCIES; do
            for PKG in ${QUEUE[@]}; do
                if [[ "$PKG" == "$DEPENDENCY" ]]; then
                    return 1
                fi
            done
        done
        return 0
    }

    # Remove blacklisted packages
    NEW_QUEUE=""
    for PACKAGE in ${QUEUE[@]}; do
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
        for PACKAGE in ${QUEUE[@]}; do
            if ready_to_build $PACKAGE; then
                #echo "Ready to build: $PACKAGE"
                READY_TO_BUILD_QUEUE="$READY_TO_BUILD_QUEUE $PACKAGE"
            else
                NEW_QUEUE="$NEW_QUEUE $PACKAGE"
                #echo "Not ready to build: $PACKAGE"
                #echo "Unmet Dependencies: $(find_local_dependencies $PACKAGE)"
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


info "Building packages..."
FILTERED_ARGS=()
for arg in "$@"; do
    if [[ $arg != -* ]]; then
        FILTERED_ARGS+=("$arg")
    fi
done

# Check if filtered arguments are provided #TODO:  --install-base "/opt/${ROSWSS_PROJECT_NAME}"
if [ ${#FILTERED_ARGS[@]} -gt 0 ]; then
    info "Building specified packages: ${FILTERED_ARGS[*]}"
    colcon build --base-paths "$ROSWSS_ROOT" --build-base "${DEB_BUILD_PATH}" --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo --packages-up-to "${FILTERED_ARGS[@]}" 2>&1 | tee "${LOG_FOLDER}/colcon.log"
    [ ${PIPESTATUS[0]} -ne 0 ] && exit 1
else
    info "Building all packages in the workspace."
    colcon build --base-paths "$ROSWSS_ROOT" --build-base "${DEB_BUILD_PATH}" --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo 2>&1 | tee "${LOG_FOLDER}/colcon.log"
    [ ${PIPESTATUS[0]} -ne 0 ] && exit 1
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

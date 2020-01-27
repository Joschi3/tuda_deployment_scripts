#!/bin/bash

. $(dirname $0)/helper/globals.sh

function remove_local_rosdeps() {
    # remove workspace packages from rosdep list and update rosdep cache
    sudo rm -rf ${ROSDEP_YAML_FILE} ${ROSDEP_LIST_FILE}
    rosdep update
}

remove_local_rosdeps || exit $?

#!/bin/bash

DEB_BASE_PATH="$ROSWSS_ROOT/debs"
APT_REPO_PATH="$DEB_BASE_PATH/repo"
LOG_FOLDER="$DEB_BASE_PATH/logs"
OS_NAME=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
OS_VERSION=$(lsb_release -sc)
ROSDEP_YAML_FILE="${ROSWSS_ROOT}/.rosdep-local-packages.yaml"
ROSDEP_LIST_FILE="/etc/ros/rosdep/sources.list.d/00-${ROSWSS_PROJECT_NAME}.list"

function to_debian_pkg_name() {
    echo "${ROSWSS_PROJECT_NAME}"-"${ROS_DISTRO}"-"$(echo "$1" | tr '_' '-')"
}

#! Arguments: PKG_NAME DEBIAN_PKG_NAME
function create_rosdep_entry() {
  echo "$1: {$OS_NAME: $2}"
}

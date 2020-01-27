#!/bin/bash
# This script requires root privileges
. $(dirname $0)/helper/globals.sh
. $(dirname $0)/helper/log_output.sh

BASE_PATH=$(readlink -f $(dirname $0)/..)
ROSDEP_EXTRA_YAML_FILE="${BASE_PATH}/rosdep_extra_packages.yaml"

echo "yaml file://$ROSDEP_YAML_FILE ${ROS_DISTRO}" | sudo tee ${ROSDEP_LIST_FILE} > /dev/null
echo "yaml file://$ROSDEP_EXTRA_YAML_FILE ${ROS_DISTRO}" | sudo tee --append ${ROSDEP_LIST_FILE} > /dev/null

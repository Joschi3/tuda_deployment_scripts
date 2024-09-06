#!/usr/bin/env python3
import os
import sys
from argparse import ArgumentParser

def has_colcon_ignore(directory):
    # Check current and all parent directories for a COLCON_IGNORE file
    while True:
        if 'COLCON_IGNORE' in os.listdir(directory):
            return True
        parent_directory = os.path.dirname(directory)
        if parent_directory == directory:
            # Reached the root directory
            return False
        directory = parent_directory

def find_ignored_ros_packages(workspace_path):
    ignored_packages = []
    for root, dirs, files in os.walk(workspace_path):
        if 'package.xml' in files:
            # It's a ROS package, check for COLCON_IGNORE
            if has_colcon_ignore(root):
                rel_path = os.path.relpath(root, workspace_path)
                ignored_packages.append(rel_path)
    return ignored_packages

if __name__ == "__main__":
    parser = ArgumentParser(description="Find ROS packages ignored by colcon due to COLCON_IGNORE")
    parser.add_argument("--workspace", required=True, metavar="PATH", help="Path to the ROS workspace")
    args = parser.parse_args()

    if not os.path.exists(args.workspace):
        print(f"Workspace path does not exist: {args.workspace}")
        sys.exit(1)

    ignored_packages = find_ignored_ros_packages(args.workspace)
    if ignored_packages:
        print("Ignored packages:")
        for package in ignored_packages:
            print(package)
    else:
        print("No packages are being ignored.")

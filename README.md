# tuda_deployment_scripts
An overlay for the [workspace_scripts](https://github.com/tu-darmstadt-ros-pkg/workspace_scripts).

### Commands:
#### make_debian_packages_init
Requires root privileges. Initializes this machine for building debian packages by adding a custom rosdep entry.


#### make_debian_packages [PKGS...]
Does not require root privileges. Will create debian packages for all packages in the workspace (if no arguments) or the given packages including their dependencies.
The homepage for each package is set to the git remote url followed by the branch (separated by a '#') if the package is a git package.
This is to encode the information necessary for the `desourcify` and `checkout` commands in the [tuda_workspace_scripts](https://github.com/tu-darmstadt-ros-pkg/tuda_workspace_scripts) to work.


## rosdep_extra_packages.yaml
This file can be used to add additional packages that are not (yet) in the ROS base.yaml.
For the format, see below and the ROS distro base.yaml. The `depends_key` is the key used in `package.xml` for `<depend>`, `<build_depend>` etc. 
```
depends_key: {ubuntu: apt-package-name}
```

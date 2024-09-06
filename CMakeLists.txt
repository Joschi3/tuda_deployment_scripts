cmake_minimum_required(VERSION 3.5)
project(tuda_deployment_scripts VERSION 1.0)

find_package(ament_cmake REQUIRED)


#############
## Install ##
#############
ament_environment_hooks("30.setup_tuda_deployment_scripts.bash.em")

install(DIRECTORY scripts/
  DESTINATION share/${PROJECT_NAME}/scripts
)



ament_package()
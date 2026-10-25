# The helper runs as the current user and forwards only Minecraft connections.
function(fyl_configure_network target system)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  find_program(FYL_GO_EXECUTABLE NAMES go)
  if(NOT FYL_GO_EXECUTABLE)
    message(FATAL_ERROR "Go 1.24 or later is required for FYL Minecraft networking")
  endif()
  get_filename_component(FYL_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
  set(FYL_NETWORK_OUTPUT "${PROJECT_BINARY_DIR}/fyl-network")
  if(CMAKE_GENERATOR_PLATFORM MATCHES "ARM64" OR CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64|ARM64)$")
    set(FYL_NETWORK_ARCH arm64)
  else()
    set(FYL_NETWORK_ARCH x64)
  endif()
  add_custom_target(fyl_network ALL
    COMMAND "${Python3_EXECUTABLE}" "${FYL_SOURCE}/tool/build_network.py"
      --target "${system}" --arch "${FYL_NETWORK_ARCH}"
      --go "${FYL_GO_EXECUTABLE}" --output "${FYL_NETWORK_OUTPUT}"
    WORKING_DIRECTORY "${FYL_SOURCE}"
    VERBATIM
  )
  add_dependencies(${target} fyl_network)
  install(DIRECTORY "${FYL_NETWORK_OUTPUT}/"
    DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/fyl-network" COMPONENT Runtime
    USE_SOURCE_PERMISSIONS)
endfunction()

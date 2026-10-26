# TODO(multiplayer): experimental; default builds only remove stale helper files.
# Parse Flutter's actual defines in Python, so Dart and native packaging agree.
function(fyl_configure_network target system)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  include("${FLUTTER_MANAGED_DIR}/ephemeral/generated_config.cmake")
  set(FYL_DART_DEFINES "")
  foreach(entry IN LISTS FLUTTER_TOOL_ENVIRONMENT)
    if(entry MATCHES "^DART_DEFINES=(.*)$")
      set(FYL_DART_DEFINES "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  get_filename_component(FYL_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
  if(CMAKE_GENERATOR_PLATFORM MATCHES "ARM64" OR CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64|ARM64)$")
    set(FYL_NETWORK_ARCH arm64)
  else()
    set(FYL_NETWORK_ARCH x64)
  endif()
  install(CODE "
    execute_process(
      COMMAND \"${Python3_EXECUTABLE}\" \"${FYL_SOURCE}/tool/build_network.py\"
        --target \"${system}\" --arch \"${FYL_NETWORK_ARCH}\"
        --dart-defines \"${FYL_DART_DEFINES}\"
        --bundle-root \"${CMAKE_INSTALL_PREFIX}\"
        --output \"${INSTALL_BUNDLE_DATA_DIR}/fyl-network\"
      RESULT_VARIABLE FYL_NETWORK_RESULT
    )
    if(NOT FYL_NETWORK_RESULT EQUAL 0)
      message(FATAL_ERROR \"Failed to configure optional Minecraft networking helper\")
    endif()
  " COMPONENT Runtime)
endfunction()

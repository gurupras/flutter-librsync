# Linux plugin CMake build
#
# The native shared library is built from Go + CGO via the Makefile.
# CMake drives an incremental make call on every `flutter build`/`flutter run`.

cmake_minimum_required(VERSION 3.10)
project(flutter_librsync LANGUAGES C)

set(PLUGIN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(PREBUILT_LIB "${PLUGIN_ROOT}/prebuilt/linux/libflutter_librsync.so")

# Input files that trigger a rebuild when they change.
set(GO_SOURCES
  "${PLUGIN_ROOT}/go/librsync.go"
  "${PLUGIN_ROOT}/go/go.mod"
  "${PLUGIN_ROOT}/go/go.sum"
)

# Custom command: rebuild the .so whenever any Go source changes.
add_custom_command(
  OUTPUT  "${PREBUILT_LIB}"
  COMMAND make linux
  WORKING_DIRECTORY "${PLUGIN_ROOT}"
  DEPENDS ${GO_SOURCES}
  COMMENT "Building libflutter_librsync.so (Go CGO)"
)

# Drive the custom command as part of the default build.
add_custom_target(flutter_librsync_go ALL DEPENDS "${PREBUILT_LIB}")

# Expose an INTERFACE library so dependents can link against it without CMake
# needing to understand the IMPORTED library's full properties.
add_library(flutter_librsync INTERFACE)
add_dependencies(flutter_librsync flutter_librsync_go)

# Tell Flutter to bundle the prebuilt .so alongside the application.
set(flutter_librsync_bundled_libraries
  "${PREBUILT_LIB}"
  PARENT_SCOPE
)

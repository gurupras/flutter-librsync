# Windows plugin CMake build
#
# The native DLL is built from Go + CGO via the Makefile using MinGW.
# Requires: x86_64-w64-mingw32-gcc in PATH (e.g. from mingw-w64 package).

cmake_minimum_required(VERSION 3.14)
project(flutter_librsync LANGUAGES C)

set(PLUGIN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(PREBUILT_LIB "${PLUGIN_ROOT}/prebuilt/windows/flutter_librsync.dll")

set(GO_SOURCES
  "${PLUGIN_ROOT}/go/librsync.go"
  "${PLUGIN_ROOT}/go/go.mod"
  "${PLUGIN_ROOT}/go/go.sum"
)

add_custom_command(
  OUTPUT  "${PREBUILT_LIB}"
  COMMAND make windows
  WORKING_DIRECTORY "${PLUGIN_ROOT}"
  DEPENDS ${GO_SOURCES}
  COMMENT "Building flutter_librsync.dll (Go CGO via MinGW)"
)

add_custom_target(flutter_librsync_go ALL DEPENDS "${PREBUILT_LIB}")

add_library(flutter_librsync INTERFACE)
add_dependencies(flutter_librsync flutter_librsync_go)

set(flutter_librsync_bundled_libraries
  "${PREBUILT_LIB}"
  PARENT_SCOPE
)

cmake_minimum_required(VERSION 3.20)
project(kwin_mmsimpulse LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(QT_MAJOR_VERSION 6)
find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

find_package(Qt6 REQUIRED COMPONENTS Core DBus Gui Quick Widgets)
find_package(KF6 REQUIRED COMPONENTS CoreAddons)
find_package(KWin REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_get_variable(WAYLAND_PROTOCOLS wayland-protocols pkgdatadir)
pkg_get_variable(WLR_PROTOCOLS wlr-protocols pkgdatadir)

# The protocols KWin does not speak and other shells expect.
set(PROTOCOLS
    ${WAYLAND_PROTOCOLS}/staging/ext-workspace/ext-workspace-v1.xml
    ${WLR_PROTOCOLS}/unstable/wlr-foreign-toplevel-management-unstable-v1.xml)
set(PROTOCOL_SOURCES)
foreach(xml ${PROTOCOLS})
    get_filename_component(name ${xml} NAME_WE)
    add_custom_command(
        OUTPUT ${name}-server-protocol.h ${name}-protocol.c
        COMMAND wayland-scanner server-header ${xml} ${name}-server-protocol.h
        COMMAND wayland-scanner private-code ${xml} ${name}-protocol.c
        DEPENDS ${xml})
    list(APPEND PROTOCOL_SOURCES ${name}-server-protocol.h ${name}-protocol.c)
endforeach()

kcoreaddons_add_plugin(kwin-mmsimpulse
    SOURCES main.cpp toplevels.cpp workspaces.cpp ${PROTOCOL_SOURCES}
    INSTALL_NAMESPACE "kwin/plugins")
target_include_directories(kwin-mmsimpulse PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(kwin-mmsimpulse KWin::kwin)

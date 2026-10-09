cmake_minimum_required(VERSION 3.20)
project(mmsimpulse_workspaceshare LANGUAGES CXX)
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
find_package(KWin REQUIRED COMPONENTS kwineffects)

kcoreaddons_add_plugin(mmsimpulse_workspaceshare
    SOURCES workspaceshare.cpp
    INSTALL_NAMESPACE "kwin/effects/plugins")
target_link_libraries(mmsimpulse_workspaceshare KWin::kwin Qt6::DBus)

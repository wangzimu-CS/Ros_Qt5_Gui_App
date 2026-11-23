@echo off
call "D:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=x64
rem VS bundles a vcpkg under its own spaced path, which breaks MSVC link lines;
rem force the project's vcpkg at D:\vcpkg (no spaces)
set "VCPKG_ROOT=D:\vcpkg"
set "VCPKG_OVERLAY_PORTS=c:\cppproject\Ros_Qt5_Gui_App\vcpkg-overlay"
rem yaml-cpp (FetchContent) declares cmake_minimum_required < 3.5; CMake 4 needs this opt-in
set "CMAKE_EXTRA_ARGS=-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SHARED_LINKER_FLAGS=/MAP /DEBUG"
cd /d c:\cppproject\Ros_Qt5_Gui_App
build.bat

cmake_minimum_required(VERSION 3.18)
project(macVNC VERSION 0.1.0 LANGUAGES C OBJC)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(CMAKE_GENERATOR MATCHES "Unix Makefiles|Ninja")
# some LSP servers expect compile_commands.json in the project root
add_custom_target(
    macvnc-copy-compile-commands ALL
    ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_BINARY_DIR}/compile_commands.json
        ${CMAKE_CURRENT_SOURCE_DIR}
    )
endif(CMAKE_GENERATOR MATCHES "Unix Makefiles|Ninja")

#
# Dependencies
#
find_package(LibVNCServer REQUIRED)
find_package(Threads REQUIRED)
find_library(CARBON_LIBRARY Carbon REQUIRED)
find_library(IOKIT_LIBRARY IOKit REQUIRED)
find_library(SCREEN_CAPTURE_KIT ScreenCaptureKit REQUIRED)
find_library(CORE_MEDIA CoreMedia)
find_library(CORE_VIDEO CoreVideo)
find_library(FOUNDATION Foundation)
find_library(APPKIT_LIBRARY AppKit REQUIRED)
find_library(CORE_GRAPHICS CoreGraphics REQUIRED)

#
# Sources
#
set(SOURCE_FILES
    src/ScreenCapturer.h
    src/ScreenCapturer.m
    src/mac.m
    src/icon.icns
)

#
# Build bundle
#
set(MACOSX_BUNDLE_COPYRIGHT "© 2024 Christian Beier (macvnc@christianbeier.net)")
set(MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION})
set(MACOSX_BUNDLE_ICON_FILE icon.icns)
set(MACVNC_BUNDLE_IDENTIFIER "com.github.libvnc.macVNC")
configure_file(src/Info.plist.in ${CMAKE_CURRENT_BINARY_DIR}/Info.plist @ONLY)
set_source_files_properties(src/icon.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

add_executable(${PROJECT_NAME} MACOSX_BUNDLE ${SOURCE_FILES})
set_target_properties(${PROJECT_NAME} PROPERTIES MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/Info.plist)

target_link_libraries(${PROJECT_NAME} LibVNCServer::vncserver ${CMAKE_THREAD_LIBS_INIT} ${CARBON_LIBRARY} ${IOKIT_LIBRARY}
  ${SCREEN_CAPTURE_KIT}
  ${CORE_MEDIA}
  ${CORE_VIDEO}
  ${FOUNDATION})

#
# Install, i.e. finalise bundle
#
set(APP ${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}.app)  # paths to executables
set(DIRS "")   # directories to search for prerequisites
INSTALL(CODE "
set(BU_CHMOD_BUNDLE_ITEMS ON) # as per https://cmake.org/Bug/view.php?id=13833
include(BundleUtilities)
fixup_bundle(\"${APP}\"   \"\"   \"${DIRS}\")
   " COMPONENT Runtime)
INSTALL(FILES README.md DESTINATION ${APP})

#
# macVNCUI – menu bar wrapper application
#
set(MACVNCUI_SOURCE_FILES
    src/MenuBarApp.h
    src/MenuBarApp.m
    src/icon.icns
)

set(MACVNCUI_TARGET macVNCUI)
set(MACVNCUI_BUNDLE_IDENTIFIER "com.github.libvnc.macVNCUI")
set(MACVNCUI_BUNDLE_EXECUTABLE "macVNCUI")
configure_file(src/MenuBarInfo.plist.in ${CMAKE_CURRENT_BINARY_DIR}/MenuBarInfo.plist @ONLY)

add_executable(${MACVNCUI_TARGET} MACOSX_BUNDLE ${MACVNCUI_SOURCE_FILES})
set_target_properties(${MACVNCUI_TARGET} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/MenuBarInfo.plist
    # Objective-C is needed for AppKit
    XCODE_ATTRIBUTE_ENABLE_OBJC_ARC NO
)
target_compile_options(${MACVNCUI_TARGET} PRIVATE -fobjc-arc)

target_link_libraries(${MACVNCUI_TARGET}
    ${APPKIT_LIBRARY}
    ${FOUNDATION}
    ${CORE_GRAPHICS})

# Embed the macVNC CLI binary inside macVNCUI.app/Contents/MacOS/ so the UI
# can locate and launch it as a subprocess at runtime.
add_custom_command(TARGET ${MACVNCUI_TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy
        $<TARGET_FILE:${PROJECT_NAME}>
        $<TARGET_BUNDLE_CONTENT_DIR:${MACVNCUI_TARGET}>/MacOS/macVNC
    COMMENT "Embedding macVNC CLI binary into macVNCUI.app"
    DEPENDS ${PROJECT_NAME}
)

#
# Install macVNCUI bundle
#
set(UI_APP ${CMAKE_CURRENT_BINARY_DIR}/${MACVNCUI_TARGET}.app)
INSTALL(CODE "
set(BU_CHMOD_BUNDLE_ITEMS ON)
include(BundleUtilities)
fixup_bundle(\"${UI_APP}\"   \"\"   \"${DIRS}\")
   " COMPONENT Runtime)
INSTALL(FILES README.md DESTINATION ${UI_APP})

cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
    "window_service_channel.cpp"
  "launcher_channel.cpp"
  "drop_target.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Treat source files as UTF-8 to avoid C4819 warnings on Chinese comments.
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# ── 在线更新 updater.exe 子项目 ──
# 与 manager.exe 同目录，单独 target 编译（独立可执行），
# 由 Dart 端通过 com.scummod/window.launchUpdater 调起。
# 不依赖 Flutter，纯 Win32 API（kernel32 + shell32 + user32）。
# 约 50KB，无需资源文件、无控制台窗口。
add_executable(scum_mod_manager_updater WIN32
  "updater_main.cpp"
)

# 独立编译设置：关闭 utf-8 之外的 warning（updater 无中文注释）。
target_compile_options(scum_mod_manager_updater PRIVATE "/utf-8")
target_compile_definitions(scum_mod_manager_updater PRIVATE "NOMINMAX")
target_compile_definitions(scum_mod_manager_updater PRIVATE
  "_UNICODE" "UNICODE" "WIN32_LEAN_AND_MEAN")

# updater 只需 kernel32 + shell32（CommandLineToArgvW）+ advapi32（日志）。
# 不链 dwmapi / ole32 / flutter —— 避免拖大体积。
target_link_libraries(scum_mod_manager_updater PRIVATE "kernel32.lib")
target_link_libraries(scum_mod_manager_updater PRIVATE "shell32.lib")

# ── v3 架构：引导器 scum_mod_manager.exe ──
# 唯一稳定的用户入口：读 app.json → 设 SCUM_MM_ROOT → 启动 *_app.exe。
# 纯 Win32（kernel32 + shell32 + user32），无 Flutter 依赖，<50KB。
add_executable(scum_mod_manager WIN32
  "launcher_main.cpp"
)
target_compile_options(scum_mod_manager PRIVATE "/utf-8")
target_compile_definitions(scum_mod_manager PRIVATE "NOMINMAX")
target_compile_definitions(scum_mod_manager PRIVATE
  "_UNICODE" "UNICODE" "WIN32_LEAN_AND_MEAN")
target_link_libraries(scum_mod_manager PRIVATE "kernel32.lib")
target_link_libraries(scum_mod_manager PRIVATE "shell32.lib")
target_link_libraries(scum_mod_manager PRIVATE "user32.lib")
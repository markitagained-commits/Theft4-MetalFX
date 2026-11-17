# Builds the five iPhoneOS static archives Theft4 0.3.2 links:
# libMoltenVK.a libMoltenVK_Common.a libMoltenVK_ShaderConverter.a
# libspirv-cross.a libSPIRV-Tools.a
# Mirrors XeniOS third_party/CMakeLists.txt (macOS MoltenVK block) for iOS.
cmake_minimum_required(VERSION 3.24)
project(theft4_moltenvk_ios C CXX OBJC OBJCXX)
if(NOT TP)
  message(FATAL_ERROR "Set -DTP=<XeniOS>/third_party")
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
add_compile_options(-w)

set(SPIRV-Headers_SOURCE_DIR "${TP}/SPIRV-Headers" CACHE INTERNAL "")
set(SPIRV_SKIP_TESTS ON CACHE INTERNAL "")
set(SPIRV_SKIP_EXECUTABLES ON CACHE INTERNAL "")
set(SKIP_SPIRV_TOOLS_INSTALL ON CACHE INTERNAL "")
set(SPIRV_WERROR OFF CACHE INTERNAL "")
set(SPIRV_BUILD_FUZZER OFF CACHE INTERNAL "")
add_subdirectory(${TP}/SPIRV-Tools ${CMAKE_BINARY_DIR}/SPIRV-Tools EXCLUDE_FROM_ALL)

add_library(spirv-cross STATIC
  ${TP}/SPIRV-Cross/spirv_cross.cpp
  ${TP}/SPIRV-Cross/spirv_cross_parsed_ir.cpp
  ${TP}/SPIRV-Cross/spirv_parser.cpp
  ${TP}/SPIRV-Cross/spirv_cfg.cpp
  ${TP}/SPIRV-Cross/spirv_cross_util.cpp
  ${TP}/SPIRV-Cross/spirv_glsl.cpp
  ${TP}/SPIRV-Cross/spirv_msl.cpp
  ${TP}/SPIRV-Cross/spirv_reflect.cpp)
target_include_directories(spirv-cross PUBLIC ${TP}/SPIRV-Cross)

find_package(Git QUIET)
execute_process(COMMAND ${GIT_EXECUTABLE} -C ${TP}/MoltenVK rev-parse --short HEAD
  OUTPUT_VARIABLE MVK_GIT_REV OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT MVK_GIT_REV)
  set(MVK_GIT_REV "00000000")
endif()
configure_file(${TP}/MoltenVK/Templates/cmake/mvkGitRevDerived.h.in
  ${CMAKE_BINARY_DIR}/MoltenVK-gen/mvkGitRevDerived.h @ONLY)

file(GLOB _mvk_common_src "${TP}/MoltenVK/Common/*.c" "${TP}/MoltenVK/Common/*.cpp"
  "${TP}/MoltenVK/Common/*.m" "${TP}/MoltenVK/Common/*.mm")
add_library(MoltenVK_Common STATIC ${_mvk_common_src})
target_include_directories(MoltenVK_Common PUBLIC ${TP}/MoltenVK/Common
  ${TP}/MoltenVK/MoltenVK/include ${TP}/Vulkan-Headers/include)
target_compile_options(MoltenVK_Common PUBLIC -Wno-deprecated-declarations -Wno-vla-cxx-extension)
target_compile_definitions(MoltenVK_Common PUBLIC MVK_CONFIG_LOG_LEVEL=1 MVK_USE_METAL_PRIVATE_API=0)

file(GLOB _mvk_sc_src
  "${TP}/MoltenVK/MoltenVKShaderConverter/MoltenVKShaderConverter/*.c"
  "${TP}/MoltenVK/MoltenVKShaderConverter/MoltenVKShaderConverter/*.cpp"
  "${TP}/MoltenVK/MoltenVKShaderConverter/MoltenVKShaderConverter/*.m"
  "${TP}/MoltenVK/MoltenVKShaderConverter/MoltenVKShaderConverter/*.mm")
add_library(MoltenVK_ShaderConverter STATIC ${_mvk_sc_src})
target_include_directories(MoltenVK_ShaderConverter PUBLIC
  ${TP}/MoltenVK/MoltenVKShaderConverter ${TP}/SPIRV-Headers/include)
target_link_libraries(MoltenVK_ShaderConverter PUBLIC MoltenVK_Common spirv-cross SPIRV-Tools-static)

file(GLOB_RECURSE _mvk_core_src "${TP}/MoltenVK/MoltenVK/MoltenVK/*.c"
  "${TP}/MoltenVK/MoltenVK/MoltenVK/*.cpp" "${TP}/MoltenVK/MoltenVK/MoltenVK/*.m"
  "${TP}/MoltenVK/MoltenVK/MoltenVK/*.mm")
add_library(MoltenVK STATIC ${_mvk_core_src})
target_include_directories(MoltenVK PUBLIC ${TP}/MoltenVK/MoltenVK/include
  PRIVATE
  ${TP}/MoltenVK/MoltenVK/MoltenVK/API ${TP}/MoltenVK/MoltenVK/MoltenVK/Commands
  ${TP}/MoltenVK/MoltenVK/MoltenVK/GPUObjects ${TP}/MoltenVK/MoltenVK/MoltenVK/Layers
  ${TP}/MoltenVK/MoltenVK/MoltenVK/OS ${TP}/MoltenVK/MoltenVK/MoltenVK/Utility
  ${TP}/MoltenVK/MoltenVK/MoltenVK/Vulkan ${TP}/cereal/include ${CMAKE_BINARY_DIR}/MoltenVK-gen)
target_compile_definitions(MoltenVK PUBLIC MVK_FRAMEWORK_VERSION=1.4.2)
target_link_libraries(MoltenVK PUBLIC MoltenVK_ShaderConverter)

add_custom_target(theft4_libs ALL DEPENDS MoltenVK MoltenVK_Common MoltenVK_ShaderConverter
  spirv-cross SPIRV-Tools-static)

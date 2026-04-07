cmake_minimum_required(VERSION 3.18)
project(tunnel_jni C)

add_library(tunnel_jni SHARED tunnel_jni.c)

# Link the prebuilt Rust tunnel library
add_library(tunnel SHARED IMPORTED)
set_target_properties(tunnel PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/../jniLibs/${ANDROID_ABI}/libtunnel.so"
    IMPORTED_NO_SONAME TRUE)

target_link_libraries(tunnel_jni tunnel log)

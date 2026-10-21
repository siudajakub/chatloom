# SPDX-License-Identifier: AGPL-3.0-or-later
# Add the two already-bundled BoringSSL files omitted by webcrypto 0.6.1's
# Apple x86_64 source list. No cryptographic implementation is replaced.
if(PROJECT_NAME STREQUAL "webcrypto" AND APPLE AND CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
  file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/CMakeLists.txt" chatloom_webcrypto_build_sha)
  if(NOT chatloom_webcrypto_build_sha STREQUAL "4993a45232752c1b9498abbf25496f8042637d19b1fce39a3d0a42c522e601b4")
    message(FATAL_ERROR "webcrypto build changed; review the Apple x86_64 source-list fix")
  endif()
  function(chatloom_link_bundled_fiat)
    get_target_property(chatloom_crypto_sources webcrypto SOURCES)
    foreach(name fiat_p256_adx_mul.S fiat_p256_adx_sqr.S)
      set(relative "../third_party/boringssl/third_party/fiat/asm/${name}")
      if(NOT relative IN_LIST chatloom_crypto_sources)
        target_sources(webcrypto PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/${relative}")
      endif()
    endforeach()
  endfunction()
  cmake_language(DEFER CALL chatloom_link_bundled_fiat)
endif()

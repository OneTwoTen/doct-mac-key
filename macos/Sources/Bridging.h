/*
 * Bridging.h — Swift <-> Rust C ABI bridging header for DoctKey.
 *
 * The Swift app is compiled with
 *   -import-objc-header macos/Sources/Bridging.h -Xcc -Icore/include
 * so the declarations from core/include/doctkey.h are visible to Swift.
 */
#ifndef DOCTKEY_BRIDGING_H
#define DOCTKEY_BRIDGING_H

#include "doctkey.h"

#endif /* DOCTKEY_BRIDGING_H */

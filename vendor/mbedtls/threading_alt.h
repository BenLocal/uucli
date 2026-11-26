/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef UUCLI_MBEDTLS_THREADING_ALT_H
#define UUCLI_MBEDTLS_THREADING_ALT_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

typedef struct mbedtls_threading_mutex_t {
    CRITICAL_SECTION mutex;
    char is_valid;
} mbedtls_threading_mutex_t;

#endif

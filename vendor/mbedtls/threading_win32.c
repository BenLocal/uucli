/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <windows.h>
#include "mbedtls/threading.h"

static LONG threading_initialized = 0;

static void win32_mutex_init(mbedtls_threading_mutex_t *mutex) {
    if (mutex == NULL) return;
    InitializeCriticalSection(&mutex->mutex);
    mutex->is_valid = 1;
}

static void win32_mutex_free(mbedtls_threading_mutex_t *mutex) {
    if (mutex == NULL || !mutex->is_valid) return;
    DeleteCriticalSection(&mutex->mutex);
    mutex->is_valid = 0;
}

static int win32_mutex_lock(mbedtls_threading_mutex_t *mutex) {
    if (mutex == NULL || !mutex->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
    EnterCriticalSection(&mutex->mutex);
    return 0;
}

static int win32_mutex_unlock(mbedtls_threading_mutex_t *mutex) {
    if (mutex == NULL || !mutex->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
    LeaveCriticalSection(&mutex->mutex);
    return 0;
}

void uucli_mbedtls_init_threading(void) {
    if (InterlockedExchange(&threading_initialized, 1) != 0) return;
    mbedtls_threading_set_alt(win32_mutex_init, win32_mutex_free, win32_mutex_lock, win32_mutex_unlock);
}

/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Mbed TLS user config for uucli, applied on top of the default mbedtls_config.h.
 * libdatachannel's DTLS transport references the DTLS-SRTP profile types and calls Mbed TLS
 * from several threads, so enable the same options Homebrew's mbedtls@3 enables. */
#define MBEDTLS_SSL_DTLS_SRTP
#define MBEDTLS_THREADING_C
#ifdef _WIN32
#define MBEDTLS_THREADING_ALT
#else
#define MBEDTLS_THREADING_PTHREAD
#endif

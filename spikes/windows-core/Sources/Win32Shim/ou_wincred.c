/* Win32Shim is Windows-only. Guarding the whole translation unit keeps `swift build` and
   `swift test` green on Linux and macOS, where this target is still built but never linked
   into a product (see the platform condition in Package.swift). */
#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>
#include <stdlib.h>
#include <string.h>

#include "ou_shim.h"

int ou_cred_read_generic_utf8(const wchar_t *target, char **out, size_t *out_len) {
    *out = NULL;
    *out_len = 0;
    PCREDENTIALW cred = NULL;
    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &cred)) {
        return 0;
    }
    size_t len = (size_t)cred->CredentialBlobSize;
    char *buf = (char *)malloc(len + 1);
    if (!buf) {
        CredFree(cred);
        return 0;
    }
    if (len > 0) {
        memcpy(buf, cred->CredentialBlob, len);
    }
    buf[len] = '\0';
    CredFree(cred);
    *out = buf;
    *out_len = len;
    return 1;
}

void ou_cred_free_string(char *p) {
    free(p);
}

#else
/* ISO C requires a translation unit to hold at least one declaration. */
typedef int ou_win32shim_unused_on_this_platform;
#endif /* _WIN32 */

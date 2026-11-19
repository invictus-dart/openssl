/*
 * Smoke test for the prebuilt OpenSSL bundles: links against libcrypto.a and
 * exercises the only entry points mars uses (MD5, RAND_bytes). Kept tiny on
 * purpose so it doubles as a cheap symbol/ABI check per target triple.
 */
#include <stdio.h>
#include <string.h>
#include <openssl/md5.h>
#include <openssl/rand.h>

int main(void) {
    unsigned char digest[MD5_DIGEST_LENGTH];
    unsigned char rnd[16];
    const char *abc = "abc";

    if (MD5((const unsigned char *)abc, strlen(abc), digest) == NULL) {
        fprintf(stderr, "MD5 failed\n");
        return 1;
    }
    /* RFC 1321 test vector */
    if (memcmp(digest,
               "\x90\x01\x50\x98\x3c\xd2\x4f\xb0\xd6\x96\x3f\x7d\x28\xe1\x7f\x72",
               MD5_DIGEST_LENGTH) != 0) {
        fprintf(stderr, "MD5 mismatch\n");
        return 1;
    }
    if (RAND_bytes(rnd, sizeof(rnd)) != 1) {
        fprintf(stderr, "RAND_bytes failed\n");
        return 1;
    }
    puts("ok");
    return 0;
}

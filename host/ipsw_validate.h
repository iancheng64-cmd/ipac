#ifndef HENGEVM_IPSW_VALIDATE_H
#define HENGEVM_IPSW_VALIDATE_H

/* Checks the ZIP directory and BuildManifest without reading large restore
   payloads. expected_build may be NULL. Returns 0 for a valid Mac IPSW, -1 otherwise. */
int hv_ipsw_validate(const char *path, const char *expected_build);

#endif

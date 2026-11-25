#include "ipsw_validate.h"

#include <plist/plist.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <zip.h>

enum { MAX_MANIFEST_BYTES = 16 << 20, MAX_ARCHIVE_ENTRIES = 100000, MAX_BUILD_IDENTITIES = 512 };

static int has_mac_product(plist_t manifest) {
    plist_t types = plist_dict_get_item(manifest, "SupportedProductTypes");
    if (!PLIST_IS_ARRAY(types)) return 0;
    for (uint32_t i = 0; i < plist_array_get_size(types); i++) {
        plist_t type = plist_array_get_item(types, i);
        if (PLIST_IS_STRING(type) && plist_string_val_compare(type, "VirtualMac2,1") == 0) return 1;
    }
    return 0;
}

static int has_identity_payloads(zip_t *archive, plist_t identity) {
    if (!PLIST_IS_DICT(identity)) return 0;
    plist_t components = plist_dict_get_item(identity, "Manifest");
    if (!PLIST_IS_DICT(components)) return 0;
    plist_dict_iter iter = NULL;
    plist_dict_new_iter(components, &iter);
    if (!iter) return 0;
    int valid = 1, files = 0;
    while (valid) {
        plist_t component = NULL;
        plist_dict_next_item(components, iter, NULL, &component);
        if (!component) break;
        if (!PLIST_IS_DICT(component)) {
            valid = 0;
            break;
        }
        plist_t info = plist_dict_get_item(component, "Info");
        plist_t path_node = PLIST_IS_DICT(info) ? plist_dict_get_item(info, "Path") : NULL;
        if (!path_node) continue;
        if (!PLIST_IS_STRING(path_node)) {
            valid = 0;
            break;
        }
        char *path = NULL;
        plist_get_string_val(path_node, &path);
        zip_stat_t st;
        zip_stat_init(&st);
        if (!path || !*path || zip_stat(archive, path, 0, &st) != 0 || !(st.valid & ZIP_STAT_SIZE) || st.size == 0) {
            valid = 0;
        } else {
            files++;
        }
        free(path);
    }
    plist_dict_free_iter(iter);
    return valid && files > 0;
}

static int has_valid_manifest(zip_t *archive, plist_t manifest, const char *expected_build) {
    if (!PLIST_IS_DICT(manifest)) return 0;
    plist_t build = plist_dict_get_item(manifest, "ProductBuildVersion");
    plist_t version = plist_dict_get_item(manifest, "ProductVersion");
    if (!PLIST_IS_STRING(build) || plist_string_val_compare(build, "") == 0 ||
        !PLIST_IS_STRING(version) || plist_string_val_compare(version, "") == 0) return 0;
    if (expected_build && *expected_build && plist_string_val_compare(build, expected_build) != 0) return 0;
    if (!has_mac_product(manifest)) return 0;
    plist_t identities = plist_dict_get_item(manifest, "BuildIdentities");
    if (!PLIST_IS_ARRAY(identities)) return 0;
    uint32_t count = plist_array_get_size(identities);
    if (count == 0 || count > MAX_BUILD_IDENTITIES) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (!has_identity_payloads(archive, plist_array_get_item(identities, i))) return 0;
    }
    return 1;
}

int hv_ipsw_validate(const char *path, const char *expected_build) {
    struct stat file_stat;
    if (!path || stat(path, &file_stat) != 0 || !S_ISREG(file_stat.st_mode) || file_stat.st_size < 32) return -1;
    int zip_error = 0;
    zip_t *archive = zip_open(path, ZIP_RDONLY | ZIP_CHECKCONS, &zip_error);
    if (!archive) return -1;
    int result = -1;
    zip_int64_t entries = zip_get_num_entries(archive, 0);
    zip_stat_t st;
    zip_stat_init(&st);
    if (entries < 2 || entries > MAX_ARCHIVE_ENTRIES ||
        zip_stat(archive, "BuildManifest.plist", 0, &st) != 0 || !(st.valid & ZIP_STAT_SIZE) ||
        st.size == 0 || st.size > MAX_MANIFEST_BYTES) goto done;
    char *data = malloc((size_t)st.size);
    if (!data) goto done;
    zip_file_t *manifest_file = zip_fopen(archive, "BuildManifest.plist", 0);
    if (!manifest_file) {
        free(data);
        goto done;
    }
    uint64_t have = 0;
    while (have < st.size) {
        zip_int64_t n = zip_fread(manifest_file, data + have, st.size - have);
        if (n <= 0) break;
        have += (uint64_t)n;
    }
    char extra;
    int complete = have == st.size && zip_fread(manifest_file, &extra, 1) == 0;
    if (zip_fclose(manifest_file) != 0) complete = 0;
    if (complete) {
        plist_t manifest = NULL;
        if (plist_from_memory(data, (uint32_t)st.size, &manifest, NULL) == PLIST_ERR_SUCCESS &&
            has_valid_manifest(archive, manifest, expected_build)) result = 0;
        if (manifest) plist_free(manifest);
    }
    free(data);
done:
    zip_discard(archive);
    return result;
}

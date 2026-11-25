#include "ipsw_validate.h"

#include <fcntl.h>
#include <plist/plist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zip.h>

static int checks, failures;
static char root[] = "/tmp/henge-ipsw-validation-XXXXXX";
static const char *names[] = {"valid.ipsw", "binary.ipsw", "missing.ipsw", "invalid.ipsw",
                              "wrong-product.ipsw", "missing-payload.ipsw", "truncated.ipsw", "crc.ipsw"};

static void check(int condition, const char *name) {
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", name);
    }
}

static void path(char *out, size_t capacity, const char *name) {
    snprintf(out, capacity, "%s/%s", root, name);
}

static void cleanup(void) {
    char file[1024];
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        path(file, sizeof file, names[i]);
        unlink(file);
    }
    rmdir(root);
}

static void add_file(zip_t *archive, const char *name, const void *data, size_t size) {
    zip_source_t *source = zip_source_buffer(archive, data, size, 0);
    if (!source) exit(2);
    zip_int64_t index = zip_file_add(archive, name, source, 0);
    if (index < 0) {
        zip_source_free(source);
        exit(2);
    }
    if (zip_set_file_compression(archive, (zip_uint64_t)index, ZIP_CM_STORE, 0) != 0) exit(2);
}

static void make_archive(const char *name, const void *manifest, size_t size, const char *payload_name) {
    char file[1024];
    path(file, sizeof file, name);
    int error = 0;
    zip_t *archive = zip_open(file, ZIP_CREATE | ZIP_TRUNCATE, &error);
    if (!archive) exit(2);
    if (manifest) add_file(archive, "BuildManifest.plist", manifest, size);
    const char payload[] = "small restore payload";
    add_file(archive, payload_name, payload, sizeof payload);
    if (zip_close(archive) != 0) {
        zip_discard(archive);
        exit(2);
    }
}

static void copy_and_damage(const char *name, int truncate_tail) {
    char original[1024], target[1024];
    path(original, sizeof original, "valid.ipsw");
    path(target, sizeof target, name);
    FILE *input = fopen(original, "rb");
    if (!input) exit(2);
    fseek(input, 0, SEEK_END);
    long length = ftell(input);
    rewind(input);
    unsigned char *data = malloc((size_t)length);
    if (!data || fread(data, 1, (size_t)length, input) != (size_t)length) exit(2);
    fclose(input);
    if (truncate_tail) {
        length -= 9;
    } else {
        const char needle[] = "<string>15.6.1</string>";
        int damaged = 0;
        for (long i = 0; i + (long)strlen(needle) < length; i++) {
            if (memcmp(data + i, needle, strlen(needle)) == 0) {
                data[i + 8] ^= 1;
                damaged = 1;
                break;
            }
        }
        if (!damaged) exit(2);
    }
    FILE *output = fopen(target, "wb");
    if (!output || fwrite(data, 1, (size_t)length, output) != (size_t)length) exit(2);
    fclose(output);
    free(data);
}

int main(void) {
    if (!mkdtemp(root)) return 2;
    atexit(cleanup);
    const char manifest[] =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
        "<key>ProductVersion</key><string>15.6.1</string>"
        "<key>ProductBuildVersion</key><string>24G90</string>"
        "<key>SupportedProductTypes</key><array><string>VirtualMac2,1</string></array>"
        "<key>BuildIdentities</key><array><dict><key>Manifest</key><dict><key>OS</key>"
        "<dict><key>Info</key><dict><key>Path</key><string>OS.dmg</string></dict></dict>"
        "</dict></dict></array></dict></plist>";
    make_archive("valid.ipsw", manifest, strlen(manifest), "OS.dmg");
    char file[1024];
    path(file, sizeof file, "valid.ipsw");
    check(hv_ipsw_validate(file, "24G90") == 0, "complete XML-manifest ZIP accepted");
    check(hv_ipsw_validate(file, NULL) == 0, "optional expected build");
    check(hv_ipsw_validate(file, "23G93") != 0, "wrong build rejected");
    check(hv_ipsw_validate(NULL, NULL) != 0, "NULL source rejected");

    plist_t parsed = NULL;
    char *binary = NULL;
    uint32_t binary_size = 0;
    if (plist_from_memory(manifest, (uint32_t)strlen(manifest), &parsed, NULL) != PLIST_ERR_SUCCESS) return 2;
    plist_to_bin(parsed, &binary, &binary_size);
    if (!binary || !binary_size) return 2;
    make_archive("binary.ipsw", binary, binary_size, "OS.dmg");
    free(binary);
    path(file, sizeof file, "binary.ipsw");
    check(hv_ipsw_validate(file, "24G90") == 0, "binary manifest accepted");

    plist_t types = plist_dict_get_item(parsed, "SupportedProductTypes");
    plist_set_string_val(plist_array_get_item(types, 0), "iPhone14,5");
    char *wrong_product = NULL;
    uint32_t wrong_size = 0;
    plist_to_xml(parsed, &wrong_product, &wrong_size);
    if (!wrong_product || !wrong_size) return 2;
    make_archive("wrong-product.ipsw", wrong_product, wrong_size, "OS.dmg");
    free(wrong_product);
    plist_free(parsed);
    path(file, sizeof file, "wrong-product.ipsw");
    check(hv_ipsw_validate(file, "24G90") != 0, "non-Mac manifest rejected");

    make_archive("missing.ipsw", NULL, 0, "OS.dmg");
    path(file, sizeof file, "missing.ipsw");
    check(hv_ipsw_validate(file, "24G90") != 0, "missing BuildManifest rejected");
    const char invalid[] = "not a property list";
    make_archive("invalid.ipsw", invalid, sizeof invalid, "OS.dmg");
    path(file, sizeof file, "invalid.ipsw");
    check(hv_ipsw_validate(file, "24G90") != 0, "invalid BuildManifest rejected");
    make_archive("missing-payload.ipsw", manifest, strlen(manifest), "Other.dmg");
    path(file, sizeof file, "missing-payload.ipsw");
    check(hv_ipsw_validate(file, "24G90") != 0, "missing referenced payload rejected");
    copy_and_damage("truncated.ipsw", 1);
    path(file, sizeof file, "truncated.ipsw");
    check(hv_ipsw_validate(file, "24G90") != 0, "truncated central directory rejected");
    copy_and_damage("crc.ipsw", 0);
    path(file, sizeof file, "crc.ipsw");
    check(hv_ipsw_validate(file, "24G90") != 0, "damaged manifest CRC rejected");
    printf("IPSW validation: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}

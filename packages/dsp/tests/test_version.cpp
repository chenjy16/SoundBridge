/**
 * @file test_version.cpp
 * @brief Tests for soundbridge_dsp_get_version() (audit finding F-20)
 *
 * The library used to report its CMake project version, which was pinned at
 * 1.0.0 while the release said 1.2.0: two independent sources of truth, and the
 * one a user can query was the wrong one. The version is now derived from the
 * repository VERSION file at configure time, and the tests get the expected
 * value from that same file, so this test fails if the two ever diverge - that
 * is the point of it, not the string comparison itself.
 */

#include "test_utils.h"
#include "soundbridge_dsp.h"

#include <cstring>

TEST(version_is_a_dotted_numeric_string) {
    const char* version = soundbridge_dsp_get_version();

    ASSERT(version != nullptr);
    ASSERT(version[0] != '\0');

    // "1.2.0" and "1.2" are versions; "1.2.0-rc1" and "v1.2.0" are not. The
    // public contract is a plain dotted number so a caller can split it.
    bool last_was_dot = true;   // a leading dot is invalid, so start "after" one
    for (const char* p = version; *p != '\0'; ++p) {
        if (*p == '.') {
            ASSERT(!last_was_dot);
            last_was_dot = true;
        } else {
            ASSERT(*p >= '0' && *p <= '9');
            last_was_dot = false;
        }
    }
    ASSERT(!last_was_dot);   // no trailing dot

    PASS();
}

// SOUNDBRIDGE_EXPECTED_VERSION is defined by tests/CMakeLists.txt from the
// repository's VERSION file - the same file the library derives its project
// version from. Equality therefore proves the library reports the product
// version, not a number someone forgot to bump.
TEST(version_matches_the_repository_product_version) {
    ASSERT(std::strcmp(soundbridge_dsp_get_version(), SOUNDBRIDGE_EXPECTED_VERSION) == 0);

    PASS();
}

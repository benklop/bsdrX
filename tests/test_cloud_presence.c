/*
 * bsdrX — Bigscreen Remote Desktop agent.
 * Copyright (C) 2026 Stefy Lanza <stefy@nexlab.net>
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3 or (at your option) any
 * later version. See <https://www.gnu.org/licenses/>.
 */
/* Presence-WS recovery: /rooms 5xx must reopen, but not every 1s tick. */
#include "bsdr/cloud.h"
#include <stdio.h>

static int fail = 0;
#define CHECK(cond, name) do { \
    if (cond) printf("PASS %s\n", name); \
    else { printf("FAIL %s\n", name); fail++; } } while (0)

int main(void) {
    CHECK(!bsdr_cloud_ws_alive(NULL), "null_ws_dead");
    CHECK(!bsdr_cloud_presence_retry_5xx(200, 0, 1000), "ok_no_reopen");
    CHECK(!bsdr_cloud_presence_retry_5xx(403, 0, 1000), "expired_token_is_renew_not_5xx");
    CHECK(bsdr_cloud_presence_retry_5xx(500, 0, 1000), "first_5xx_reopens");
    CHECK(!bsdr_cloud_presence_retry_5xx(500, 1000, 14000), "debounce_inside_grace");
    CHECK(bsdr_cloud_presence_retry_5xx(500, 1000, 16000), "debounce_after_grace");
    CHECK(bsdr_cloud_presence_retry_5xx(503, 1000, 20000), "other_5xx_too");
    CHECK(bsdr_cloud_token_refresh_due(0, 1000), "unknown_issue_time_renews");
    CHECK(!bsdr_cloud_token_refresh_due(1000, 1000 + 9 * 60 * 1000), "fresh_under_10min");
    CHECK(bsdr_cloud_token_refresh_due(1000, 1000 + 10 * 60 * 1000), "renew_at_10min");

    printf(fail ? "\nFAILED (%d)\n" : "\nOK - cloud_presence passed\n", fail);
    return fail ? 1 : 0;
}

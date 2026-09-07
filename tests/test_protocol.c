/*
 * bsdrX — Bigscreen Remote Desktop agent.
 * Copyright (C) 2026 Stefy Lanza <stefy@nexlab.net>
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <https://www.gnu.org/licenses/>.
 */
/* Unit tests for protocol header check, discovery buffer, JSON, pairing, reconfig, login. */
#include "bsdr/protocol.h"
#include "bsdr/discovery.h"
#include "bsdr/json.h"
#include "bsdr/capture.h"
#include "bsdr/control.h"
#include "bsdr/app.h"
#include "bsdr/cloud.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL %s\n", msg); failures++; } \
    else printf("PASS %s\n", msg); } while (0)

int main(void) {
    /* header check */
    uint8_t bad[5] = { 0, 0, 0, 0, 0 };
    CHECK(bsdr_check_message_header(BSDR_BROADCAST_HEADER, 5), "header_match");
    CHECK(!bsdr_check_message_header(bad, 5), "header_mismatch");
    CHECK(!bsdr_check_message_header(BSDR_BROADCAST_HEADER, 4), "header_len");

    /* discovery buffer */
    bsdr_discovery_info info = {0};
    snprintf(info.session_id, sizeof(info.session_id), "sid");
    snprintf(info.version, sizeof(info.version), "0.950.2");
    snprintf(info.device_name, sizeof(info.device_name), "host");
    snprintf(info.device_id, sizeof(info.device_id), "did");
    snprintf(info.pairing_request_code, sizeof(info.pairing_request_code), "123456");

    uint8_t buf[512];
    size_t n = bsdr_discovery_build(&info, buf, sizeof(buf));
    CHECK(n > 5 && memcmp(buf, BSDR_BROADCAST_HEADER, 5) == 0, "discovery_header");

    const char *json = (const char *)buf + 5;
    char val[64];
    CHECK(bsdr_json_get_str(json, "pairingRequestCode", val, sizeof(val)) &&
          strcmp(val, "123456") == 0, "discovery_pairing_code");
    CHECK(bsdr_json_get_str(json, "deviceName", val, sizeof(val)) &&
          strcmp(val, "host") == 0, "discovery_device_name");
    CHECK(bsdr_json_get_str(json, "version", val, sizeof(val)) &&
          strcmp(val, "0.950.2") == 0, "discovery_version");

    /* JSON parse: string + number, escapes */
    const char *body = "{\"deviceName\":\"a\\\"b\",\"fps\": 90,\"x\":-1.5}";
    CHECK(bsdr_json_get_str(body, "deviceName", val, sizeof(val)) &&
          strcmp(val, "a\"b") == 0, "json_escaped_string");
    double d;
    CHECK(bsdr_json_get_double(body, "fps", &d) && d == 90.0, "json_number");
    CHECK(bsdr_json_get_double(body, "x", &d) && d == -1.5, "json_negative");
    CHECK(!bsdr_json_get_str(body, "missing", val, sizeof(val)), "json_missing");

    /* NULL-safe escape (login / rooms fields can be unset) */
    char esc[16];
    CHECK(bsdr_json_escape(esc, sizeof(esc), NULL) == 0 && esc[0] == '\0', "json_escape_null");

    /* Finding 1: bitrate/resolution retunes; region reopens; cancel never kills the worker */
    CHECK(bsdr_live_reconfig_kind(0, 1) == BSDR_RECONFIG_RETUNE, "reconfig_quality_retunes");
    CHECK(bsdr_live_reconfig_kind(1, 1) == BSDR_RECONFIG_REOPEN, "reconfig_region_reopens");
    CHECK(bsdr_live_reconfig_kind(0, 0) == BSDR_RECONFIG_NONE, "reconfig_none");
    CHECK(!bsdr_live_reconfig_fatal(1, 1), "reconfig_fail_keeps_prev");
    CHECK(!bsdr_live_reconfig_fatal(1, 0), "reconfig_fail_no_prev_retries");

    /* VAAPI device rank: Arc (xe) beats iGPU (i915); a connected display beats rank. */
    CHECK(bsdr_vaapi_drv_rank("xe") > bsdr_vaapi_drv_rank("i915"), "vaapi_rank_arc_over_igpu");
    CHECK(bsdr_vaapi_drv_rank("i915") > bsdr_vaapi_drv_rank("amdgpu"), "vaapi_rank_igpu_over_amd");
    CHECK(bsdr_vaapi_drv_rank("nvidia") < 0, "vaapi_rank_skip_nvidia");
    CHECK(bsdr_vaapi_dev_better(0, 4, 1, 3), "vaapi_pick_connected_over_arc");
    CHECK(!bsdr_vaapi_dev_better(1, 3, 0, 4), "vaapi_keep_connected_igpu");
    CHECK(bsdr_vaapi_dev_better(1, 3, 1, 4), "vaapi_pick_arc_when_both_connected");

    /* Finding 2: host disconnect revokes the id; stale heartbeat is 410; /pair can succeed */
    CHECK(bsdr_control_auth_status(1, "abc", "", "abc") == 0, "pair_auth_ok");
    CHECK(bsdr_control_auth_status(0, "abc", "abc", "abc") == 410, "pair_auth_revoked");
    CHECK(bsdr_control_auth_status(0, "", "", "abc") == 404, "pair_auth_none");
    CHECK(bsdr_control_auth_status(1, "new", "old", "old") == 410, "pair_auth_stale_while_repaired");
    CHECK(bsdr_control_auth_status(1, "new", "old", "zzz") == 403, "pair_auth_wrong_id");

    /* Finding 3: Use on the already-selected IP after disconnect bumps gen and lifts the block */
    {
        bsdr_app app;
        bsdr_app_init(&app);
        unsigned g0 = bsdr_app_select_gen(&app);
        bsdr_app_select_quest(&app, "192.168.4.58");
        CHECK(bsdr_app_select_gen(&app) == g0 + 1, "select_first_bumps");
        bsdr_app_select_quest(&app, "192.168.4.58");
        CHECK(bsdr_app_select_gen(&app) == g0 + 2, "select_same_ip_restarts");
        bsdr_app_block_quest(&app, "192.168.4.58");
        bsdr_app_select_quest(&app, "192.168.4.58");
        CHECK(bsdr_app_select_gen(&app) == g0 + 3, "select_after_block_bumps");
        CHECK(app.blocked_quest_ip[0] == '\0', "select_lifts_block");
    }

    /* Finding 4: empty creds are not success; login reports failure */
    {
        bsdr_cloud_result res;
        CHECK(!bsdr_cloud_login(0, "", "pw", &res) && !res.ok, "login_empty_email");
        CHECK(!bsdr_cloud_login(0, "a@b.c", "", &res) && !res.ok, "login_empty_password");
        CHECK(!bsdr_cloud_login(0, NULL, NULL, &res) && !res.ok, "login_null_creds");
    }

    printf(failures ? "\nFAILED (%d)\n" : "\nOK - all protocol tests passed\n",
           failures);
    return failures ? 1 : 0;
}

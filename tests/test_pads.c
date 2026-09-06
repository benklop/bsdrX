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
/* Pad routing + assignment: LAN/cloud slot mapping, per-headset pad, Big Picture. */
#include "bsdr/app.h"
#include "bsdr/events.h"
#include "bsdr/input_decode.h"
#include "bsdr/protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL %s\n", msg); failures++; } \
    else printf("PASS %s\n", msg); } while (0)

static void put_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

static int isolate_config(void) {
    char tmpl[] = "/tmp/bsdr-pad-test-XXXXXX";
    if (!mkdtemp(tmpl)) return 0;
    setenv("XDG_CONFIG_HOME", tmpl, 1);
    unsetenv("HOME");   /* force the XDG path so we never touch ~/.config */
    return 1;
}

int main(void) {
    CHECK(bsdr_pad_route_lan(0, 0) == 0, "lan_default_p1");
    CHECK(bsdr_pad_route_lan(2, 0) == 2, "lan_assigned_p3");
    CHECK(bsdr_pad_route_lan(1, 1) == 2, "lan_assigned_plus_decoded");
    CHECK(bsdr_pad_route_lan(-1, 0) == -1, "lan_off_drops");
    CHECK(bsdr_pad_route_lan(2, 2) == -1, "lan_past_p4_drops");
    CHECK(bsdr_pad_route_lan(0, 3) == 3, "lan_decoded_p4");

    CHECK(bsdr_pad_route_cloud(0, 0) == -1, "cloud_off_drops");
    CHECK(bsdr_pad_route_cloud(1, 0) == 1, "cloud_skips_headset_p1");
    CHECK(bsdr_pad_route_cloud(1, 1) == 2, "cloud_skips_headset_p2");
    CHECK(bsdr_pad_route_cloud(1, 2) == 1, "cloud_skips_p3_uses_p2");
    CHECK(bsdr_pad_route_cloud(1, 3) == 1, "cloud_skips_p4_uses_p2");
    CHECK(bsdr_pad_route_cloud(1, -1) == 1, "cloud_headset_off_is_p2");

    uint8_t gp[13];
    memset(gp, 0, sizeof gp);
    gp[0] = BSDR_MSG_GAMEPAD;
    put_u16(gp + 1, BSDR_XINPUT_A);
    bsdr_input_event ev[4];
    CHECK(bsdr_decode_binary(gp, sizeof gp, ev, 4) == 1 && ev[0].u.gamepad.slot == 0,
          "route_decode_one_pad");
    CHECK(bsdr_pad_route_cloud(1, (int)ev[0].u.gamepad.slot) == 1, "route_cloud_to_p2");
    CHECK(bsdr_pad_route_lan(0, (int)ev[0].u.gamepad.slot) == 0, "route_lan_stays_p1");
    uint8_t unk[13];
    memcpy(unk, gp, 13); unk[0] = 0x21;
    CHECK(bsdr_decode_binary(unk, sizeof unk, ev, 4) == 0, "route_0x21_not_gamepad");

    if (!isolate_config()) { printf("FAIL isolate_config\n"); return 1; }

    bsdr_app a;
    bsdr_app_init(&a);
    CHECK(!bsdr_app_get_cloud_as_pad(&a), "cloud_as_pad_default_off");
    CHECK(!bsdr_app_get_cloud_auto_share(&a), "auto_share_default_off");
    CHECK(!bsdr_app_get_internet_sharing(&a), "share_default_off");
    bsdr_app_set_paired(&a, true, "q", "10.0.0.5");
    CHECK(!bsdr_app_get_internet_sharing(&a), "pair_does_not_share_when_auto_off");
    bsdr_app_set_cloud_auto_share(&a, true);
    CHECK(bsdr_app_get_cloud_auto_share(&a), "auto_share_on");
    CHECK(bsdr_app_get_internet_sharing(&a), "checkbox_shares_when_already_paired");
    bsdr_app_set_internet_sharing(&a, false);
    bsdr_app_set_paired(&a, false, NULL, NULL);
    bsdr_app_set_paired(&a, true, "q", "10.0.0.5");
    CHECK(bsdr_app_get_internet_sharing(&a), "re_pair_auto_shares");
    bsdr_app_set_cloud_auto_share(&a, false);
    bsdr_app_set_internet_sharing(&a, false);
    bsdr_app_set_paired(&a, false, NULL, NULL);
    CHECK(bsdr_app_headset_pad(&a, NULL) == 0, "headset_pad_null_default");
    CHECK(bsdr_app_headset_pad(&a, "10.0.0.5") == 0, "headset_pad_unknown_default");

    bsdr_app_set_cloud_as_pad(&a, true);
    CHECK(bsdr_app_get_cloud_as_pad(&a), "cloud_as_pad_on");
    bsdr_app_set_cloud_as_pad(&a, false);
    CHECK(!bsdr_app_get_cloud_as_pad(&a), "cloud_as_pad_off");

    bsdr_app_register_quest(&a, "10.0.0.5");
    CHECK(strcmp(a.selected_quest_ip, "10.0.0.5") == 0, "first_quest_auto_use");
    bsdr_app_register_quest(&a, "10.0.0.6");
    CHECK(strcmp(a.selected_quest_ip, "10.0.0.5") == 0, "second_quest_does_not_steal");
    {
        bsdr_app c;
        bsdr_app_init(&c);
        bsdr_app_block_quest(&c, "10.0.0.7");
        bsdr_app_register_quest(&c, "10.0.0.7");
        CHECK(c.selected_quest_ip[0] == '\0', "blocked_quest_not_auto_use");
        bsdr_app_free(&c);
    }
    CHECK(bsdr_app_headset_pad(&a, "10.0.0.5") == 0, "registered_default_p1");
    bsdr_app_set_quest_pad(&a, "10.0.0.5", 2);
    CHECK(bsdr_app_headset_pad(&a, "10.0.0.5") == 2, "set_quest_pad_p3");
    bsdr_app_set_quest_pad(&a, "10.0.0.5", -1);
    CHECK(bsdr_app_headset_pad(&a, "10.0.0.5") == -1, "set_quest_pad_off");
    bsdr_app_set_quest_pad(&a, "10.0.0.5", 99);
    CHECK(bsdr_app_headset_pad(&a, "10.0.0.5") == BSDR_MAX_PADS - 1, "set_quest_pad_clamped");
    bsdr_app_set_quest_pad(&a, "10.0.0.5", -8);
    CHECK(bsdr_app_headset_pad(&a, "10.0.0.5") == -1, "set_quest_pad_clamp_off");

    /* Big Picture takes the first free slot after the live (selected) headset */
    bsdr_app_select_quest(&a, "10.0.0.5");
    bsdr_app_set_quest_pad(&a, "10.0.0.5", 0);
    bsdr_app_set_cloud_as_pad(&a, true);
    CHECK(bsdr_app_cloud_pad(&a) == 1, "cloud_pad_p2_when_headset_p1");
    bsdr_app_set_quest_pad(&a, "10.0.0.5", 1);
    CHECK(bsdr_app_cloud_pad(&a) == 2, "cloud_pad_p3_when_headset_p2");
    bsdr_app_set_cloud_as_pad(&a, false);
    CHECK(bsdr_app_cloud_pad(&a) == -1, "cloud_pad_off");
    bsdr_app_vacate_cloud_pad(&a);   /* no-op when off */

    /* prefix-adjacent IPs must not share a slot */
    bsdr_app_set_quest_pad(&a, "10.0.0.1", 1);
    bsdr_app_set_quest_pad(&a, "10.0.0.10", 3);
    CHECK(bsdr_app_headset_pad(&a, "10.0.0.1") == 1, "pad_ip_short");
    CHECK(bsdr_app_headset_pad(&a, "10.0.0.10") == 3, "pad_ip_long");

    /* saved blob applies when a headset is (re)discovered */
    bsdr_app_set_quest_pad(&a, "192.168.4.20", 2);
    bsdr_app_register_quest(&a, "192.168.4.20");
    CHECK(bsdr_app_headset_pad(&a, "192.168.4.20") == 2, "register_applies_saved_slot");

    /* persist + reload */
    bsdr_app_set_cloud_as_pad(&a, true);
    bsdr_app_set_cloud_auto_share(&a, true);
    bsdr_app_set_quest_pad(&a, "10.0.0.5", 2);
    bsdr_app b;
    bsdr_app_init(&b);
    bsdr_app_load_settings(&b);
    CHECK(bsdr_app_get_cloud_as_pad(&b), "reload_cloud_as_pad");
    CHECK(bsdr_app_get_cloud_auto_share(&b), "reload_auto_share");
    CHECK(bsdr_app_headset_pad(&b, "10.0.0.5") == 2, "reload_quest_pad_via_blob");
    bsdr_app_register_quest(&b, "10.0.0.5");
    CHECK(bsdr_app_headset_pad(&b, "10.0.0.5") == 2, "reload_then_register");

    bsdr_app_free(&a);
    bsdr_app_free(&b);

    printf(failures ? "\nFAILED (%d)\n" : "\nOK - all pad tests passed\n", failures);
    return failures ? 1 : 0;
}

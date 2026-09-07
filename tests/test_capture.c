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
/* Capture-path policy (no display / no encoder): VAAPI device pick, GPU-encode
 * fallback, and the x11grab rawvideo wrap. These are the decisions the Linux X11
 * + Intel Arc path uses; a break here silently falls back to x264 or the wrong GPU. */
#include "bsdr/capture.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL %s\n", msg); failures++; } \
    else printf("PASS %s\n", msg); } while (0)

int main(void) {
    /* Driver rank: Arc (xe) > iGPU (i915) > AMD > nouveau; NVIDIA and junk are skipped. */
    CHECK(bsdr_vaapi_drv_rank("xe") == 4, "rank_xe");
    CHECK(bsdr_vaapi_drv_rank("i915") == 3, "rank_i915");
    CHECK(bsdr_vaapi_drv_rank("amdgpu") == 2, "rank_amdgpu");
    CHECK(bsdr_vaapi_drv_rank("radeon") == 2, "rank_radeon_ties_amdgpu");
    CHECK(bsdr_vaapi_drv_rank("nouveau") == 1, "rank_nouveau");
    CHECK(bsdr_vaapi_drv_rank("nvidia") < 0, "rank_skip_nvidia");
    CHECK(bsdr_vaapi_drv_rank("nvidia-drm") < 0, "rank_skip_nvidia_drm");
    CHECK(bsdr_vaapi_drv_rank("") < 0, "rank_empty");
    CHECK(bsdr_vaapi_drv_rank(NULL) < 0, "rank_null");
    CHECK(bsdr_vaapi_drv_rank("xe") > bsdr_vaapi_drv_rank("i915"), "rank_arc_over_igpu");

    /* Display-first (kmsgrab): a connected iGPU beats a disconnected Arc. */
    CHECK(bsdr_vaapi_pick_better(1, 0, 4, 1, 3), "kms_connected_igpu_over_arc");
    CHECK(!bsdr_vaapi_pick_better(1, 1, 3, 0, 4), "kms_keep_connected_igpu");
    CHECK(bsdr_vaapi_pick_better(1, 1, 3, 1, 4), "kms_arc_when_both_connected");
    CHECK(!bsdr_vaapi_pick_better(1, 1, 4, 1, 3), "kms_keep_connected_arc");
    CHECK(bsdr_vaapi_pick_better(1, 0, 2, 0, 4), "kms_arc_when_neither_connected");
    CHECK(!bsdr_vaapi_pick_better(1, 0, 4, 0, 4), "kms_tie_same_rank");

    /* Rank-first (x11grab encode): Arc wins even if the iGPU is the display. */
    CHECK(bsdr_vaapi_pick_better(0, 1, 3, 0, 4), "x11_arc_over_connected_igpu");
    CHECK(!bsdr_vaapi_pick_better(0, 0, 4, 1, 3), "x11_keep_arc");
    CHECK(bsdr_vaapi_pick_better(0, 0, 3, 0, 4), "x11_arc_over_igpu");
    CHECK(bsdr_vaapi_pick_better(0, 0, 4, 1, 4), "x11_tie_prefers_connected");
    CHECK(!bsdr_vaapi_pick_better(0, 1, 4, 0, 4), "x11_tie_keeps_connected");

    /* GPU encode: VAAPI when forced, or when GPU is on and there is no NVIDIA. */
    CHECK(bsdr_want_vaapi(1, 0, 1), "want_forced_even_with_cuda");
    CHECK(bsdr_want_vaapi(1, 1, 0), "want_forced_even_on_cpu");
    CHECK(bsdr_want_vaapi(0, 0, 0), "want_gpu_no_nvidia");
    CHECK(!bsdr_want_vaapi(0, 0, 1), "want_not_when_cuda");
    CHECK(!bsdr_want_vaapi(0, 1, 0), "want_not_on_cpu");
    CHECK(!bsdr_want_vaapi(0, 1, 1), "want_not_cpu_with_cuda");

    /* Raw wrap: desktop rawvideo only. Files, webcams, and DRM/hw frames stay on the decoder. */
    CHECK(bsdr_raw_wrap_ok(0, 0, 1, 0), "wrap_x11grab");
    CHECK(!bsdr_raw_wrap_ok(1, 0, 1, 0), "wrap_not_file");
    CHECK(!bsdr_raw_wrap_ok(0, 1, 1, 0), "wrap_not_webcam");
    CHECK(!bsdr_raw_wrap_ok(0, 0, 0, 0), "wrap_not_encoded");
    CHECK(!bsdr_raw_wrap_ok(0, 0, 1, 1), "wrap_not_kmsgrab");
    CHECK(!bsdr_raw_wrap_ok(1, 1, 1, 1), "wrap_not_everything");

    printf(failures ? "\nFAILED (%d)\n" : "\nOK - all capture tests passed\n",
           failures);
    return failures ? 1 : 0;
}

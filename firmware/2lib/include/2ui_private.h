/* Copyright 2020 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Private declarations for 2ui.c. Defined here for testing purposes.
 */

#include "2api.h"

#ifndef VBOOT_REFERENCE_2UI_PRIVATE_H_
#define VBOOT_REFERENCE_2UI_PRIVATE_H_

vb2_error_t check_shutdown_request(struct vb2_ui_context *ui);

struct input_action {
	int key;
	vb2_error_t (*action)(struct vb2_ui_context *ui);
};

vb2_error_t menu_up_action(struct vb2_ui_context *ui);
vb2_error_t menu_down_action(struct vb2_ui_context *ui);
vb2_error_t ctrl_d_action(struct vb2_ui_context *ui);
vb2_error_t change_to_dev_screen_action(struct vb2_ui_context *ui);
vb2_error_t (*input_action_lookup(int key))(struct vb2_ui_context *ui);

vb2_error_t ui_loop(struct vb2_context *ctx, enum vb2_screen root_screen_id,
		    vb2_error_t (*global_action)(struct vb2_ui_context *ui));

vb2_error_t try_recovery_action(struct vb2_ui_context *ui);

/* From 2ui_screens.c */
vb2_error_t advanced_options_init(struct vb2_ui_context *ui);
vb2_error_t recovery_select_init(struct vb2_ui_context *ui);
vb2_error_t recovery_to_dev_init(struct vb2_ui_context *ui);
vb2_error_t developer_mode_init(struct vb2_ui_context *ui);
vb2_error_t developer_mode_action(struct vb2_ui_context *ui);
vb2_error_t developer_to_norm_action(struct vb2_ui_context *ui);

#endif  /* VBOOT_REFERENCE_2UI_PRIVATE_H_ */
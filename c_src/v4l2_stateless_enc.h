/* SPDX-License-Identifier: ((GPL-2.0+ WITH Linux-syscall-note) OR BSD-3-Clause) */
/*
 * The V4L2 stateless encode uAPI of the board's kernel, for toolchains whose
 * kernel headers predate it: H.264 from "media: Add V4L2 H.264 stateless
 * encode and VC8000E support" (not merged upstream yet) and the HEVC encode
 * parameters added next to it. It has to match the running kernel.
 */
#ifndef V4L2_STATELESS_ENC_H
#define V4L2_STATELESS_ENC_H

#include <linux/v4l2-controls.h>

#ifndef V4L2_CID_STATELESS_H264_ENCODE_PARAMS
#define V4L2_H264_ENCODE_FLAG_IDR_PIC				0x01
#define V4L2_H264_ENCODE_FLAG_FIELD_PIC				0x02
#define V4L2_H264_ENCODE_FLAG_BOTTOM_FIELD			0x04
#define V4L2_H264_ENCODE_FLAG_DIRECT_SPATIAL_MV_PRED		0x08
#define V4L2_H264_ENCODE_FLAG_NUM_REF_IDX_ACTIVE_OVERRIDE	0x10
#define V4L2_H264_ENCODE_FLAG_NO_OUTPUT_OF_PRIOR_PICS		0x20
#define V4L2_H264_ENCODE_FLAG_LONG_TERM_REFERENCE		0x40

#define V4L2_CID_STATELESS_H264_ENCODE_PARAMS	(V4L2_CID_CODEC_STATELESS_BASE + 8)
struct v4l2_ctrl_h264_encode_params {
	__u8 nal_ref_idc;
	__u8 slice_type;
	__u8 pic_parameter_set_id;
	__u8 colour_plane_id;
	__u16 frame_num;
	__u16 idr_pic_id;
	__u16 pic_order_cnt_lsb;
	__u8 reserved0[2];
	__s32 delta_pic_order_cnt_bottom;
	__s32 delta_pic_order_cnt0;
	__s32 delta_pic_order_cnt1;
	__u8 num_ref_idx_l0_active_minus1;
	__u8 num_ref_idx_l1_active_minus1;
	__u8 cabac_init_idc;
	__s8 slice_qp_delta;
	__u8 disable_deblocking_filter_idc;
	__s8 slice_alpha_c0_offset_div2;
	__s8 slice_beta_offset_div2;
	__u8 reserved1[6];
	__u32 flags;
};
#endif

#ifndef V4L2_CID_STATELESS_HEVC_ENCODE_PARAMS
#define V4L2_HEVC_ENCODE_FLAG_IDR_PIC				0x01
#define V4L2_HEVC_ENCODE_FLAG_NO_OUTPUT_OF_PRIOR_PICS		0x02
#define V4L2_HEVC_ENCODE_FLAG_SLICE_SAO_LUMA			0x04
#define V4L2_HEVC_ENCODE_FLAG_SLICE_SAO_CHROMA			0x08
#define V4L2_HEVC_ENCODE_FLAG_CABAC_INIT			0x10
#define V4L2_HEVC_ENCODE_FLAG_SLICE_DEBLOCKING_FILTER_DISABLED	0x20

#define V4L2_CID_STATELESS_HEVC_ENCODE_PARAMS	(V4L2_CID_CODEC_STATELESS_BASE + 410)
struct v4l2_ctrl_hevc_encode_params {
	__u8	slice_type;
	__u8	pic_parameter_set_id;
	__u16	slice_pic_order_cnt_lsb;
	__u8	reserved[4];
	__u64	flags;
};
#endif

#endif

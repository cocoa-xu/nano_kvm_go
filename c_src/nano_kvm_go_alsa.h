// SPDX-License-Identifier: Apache-2.0
/*
 * The controls of the USB audio function's card, for nano_kvm_go_audio and
 * nano_kvm_go_playback: the rate the target chose for a direction ("Capture
 * Rate", "Playback Rate": 0 while the target does not stream), and the
 * volume and mute the target sets ("PCM Capture Volume", "PCM Capture
 * Switch"...), which the programs apply to the samples as a USB sound card
 * does. Cards without them, as the HDMI audio's, have no controls here.
 */
#ifndef NANO_KVM_ALSA_H
#define NANO_KVM_ALSA_H

#include <alsa/asoundlib.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct controls {
	snd_ctl_t *ctl;
	/* numids, 0 for none */
	unsigned int rate, volume, on;
	/* applied to the samples: 0 muted, 1 as they are */
	double gain;
};

static unsigned int find_control(snd_ctl_t *ctl, const char *name)
{
	snd_ctl_elem_list_t *list;
	unsigned int numid = 0, i, count;

	snd_ctl_elem_list_alloca(&list);
	if (snd_ctl_elem_list(ctl, list) < 0)
		return 0;
	count = snd_ctl_elem_list_get_count(list);
	if (snd_ctl_elem_list_alloc_space(list, count) < 0)
		return 0;
	if (snd_ctl_elem_list(ctl, list) == 0)
		for (i = 0; i < count && !numid; i++)
			if (!strcmp(snd_ctl_elem_list_get_name(list, i), name))
				numid = snd_ctl_elem_list_get_numid(list, i);
	snd_ctl_elem_list_free_space(list);
	return numid;
}

static long read_control(snd_ctl_t *ctl, unsigned int numid)
{
	snd_ctl_elem_value_t *value;

	snd_ctl_elem_value_alloca(&value);
	snd_ctl_elem_value_set_numid(value, numid);
	if (snd_ctl_elem_read(ctl, value) < 0)
		return -1;
	return snd_ctl_elem_value_get_integer(value, 0);
}

/* The gain of the volume and mute controls. */
static void read_gain(struct controls *c)
{
	snd_ctl_elem_id_t *id;
	long value, centibels;

	c->gain = 1;
	if (c->on && read_control(c->ctl, c->on) == 0) {
		c->gain = 0;
		return;
	}
	if (!c->volume || (value = read_control(c->ctl, c->volume)) < 0)
		return;
	snd_ctl_elem_id_alloca(&id);
	snd_ctl_elem_id_set_numid(id, c->volume);
	if (snd_ctl_convert_to_dB(c->ctl, id, value, &centibels) == 0)
		c->gain = centibels <= -9999 ? 0 : pow(10, centibels / 2000.0);
}

/*
 * Opens the controls of the PCM's card for a direction, "Capture" or
 * "Playback". Returns 0 without a card's controls to follow.
 */
static int open_controls(struct controls *c, snd_pcm_t *pcm, const char *direction)
{
	snd_pcm_info_t *info;
	char name[64];

	memset(c, 0, sizeof(*c));
	c->gain = 1;
	snd_pcm_info_alloca(&info);
	if (snd_pcm_info(pcm, info) < 0)
		return 0;
	snprintf(name, sizeof(name), "hw:%d", snd_pcm_info_get_card(info));
	if (snd_ctl_open(&c->ctl, name, SND_CTL_NONBLOCK) < 0)
		return 0;

	snprintf(name, sizeof(name), "%s Rate", direction);
	c->rate = find_control(c->ctl, name);
	snprintf(name, sizeof(name), "PCM %s Volume", direction);
	c->volume = find_control(c->ctl, name);
	snprintf(name, sizeof(name), "PCM %s Switch", direction);
	c->on = find_control(c->ctl, name);

	if ((!c->rate && !c->volume && !c->on) || snd_ctl_subscribe_events(c->ctl, 1) < 0) {
		snd_ctl_close(c->ctl);
		c->ctl = NULL;
		return 0;
	}
	read_gain(c);
	return 1;
}

/* Takes the events in; the gain follows. Returns the rate the target chose. */
static long controls_changed(struct controls *c)
{
	snd_ctl_event_t *event;

	snd_ctl_event_alloca(&event);
	while (snd_ctl_read(c->ctl, event) > 0)
		;
	read_gain(c);
	return c->rate ? read_control(c->ctl, c->rate) : 0;
}

/* Scales interleaved samples by the gain, saturating. */
static void apply_gain(const struct controls *c, snd_pcm_format_t format, uint8_t *data,
		       size_t samples)
{
	size_t i;

	if (c->gain == 1)
		return;

	switch (format) {
	case SND_PCM_FORMAT_S16_LE:
		for (i = 0; i < samples; i++, data += 2) {
			double v = (int16_t)(data[0] | data[1] << 8) * c->gain;
			int32_t x = v > 32767 ? 32767 : v < -32768 ? -32768 : (int32_t)lround(v);

			data[0] = x & 0xff;
			data[1] = (x >> 8) & 0xff;
		}
		break;
	case SND_PCM_FORMAT_S24_3LE:
		for (i = 0; i < samples; i++, data += 3) {
			int32_t s = (int32_t)((uint32_t)data[0] << 8 | (uint32_t)data[1] << 16 |
					      (uint32_t)data[2] << 24) >> 8;
			double v = s * c->gain;
			int32_t x = v > 8388607 ? 8388607 : v < -8388608 ? -8388608 : (int32_t)lround(v);

			data[0] = x & 0xff;
			data[1] = (x >> 8) & 0xff;
			data[2] = (x >> 16) & 0xff;
		}
		break;
	case SND_PCM_FORMAT_S32_LE:
		for (i = 0; i < samples; i++, data += 4) {
			int32_t s = (int32_t)((uint32_t)data[0] | (uint32_t)data[1] << 8 |
					      (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24);
			double v = s * c->gain;
			int64_t x = v > 2147483647.0 ? 2147483647 : v < -2147483648.0 ? -2147483648LL :
				    llround(v);

			data[0] = x & 0xff;
			data[1] = (x >> 8) & 0xff;
			data[2] = (x >> 16) & 0xff;
			data[3] = (x >> 24) & 0xff;
		}
		break;
	default:
		break;
	}
}

#endif

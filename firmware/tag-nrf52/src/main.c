/*
 * YAK-TAG BLE tag — nRF52 (nRF52832 / nRF52810 / nRF52805)
 * Protocol: BLE_TAG_SPEC.md (v1).
 *
 * Broadcasts, every ~1.5 s, non-connectable:
 *   Flags 06 · Complete Local Name "YT-H#####" · Manufacturer data
 *   FF FF (test company id) · 01 (version) · battery % · flags
 * The number ##### is written into UICR CUSTOMER[0] when the tag is
 * programmed (flash_tag.ps1), so one firmware file serves every tag.
 * Battery: the chip's own supply voltage (VDD), read once an hour.
 *
 * NOT YET BUILT on hardware (written 2026-10-24, before the boards
 * arrived) — expect small fixes on the first build.
 */
#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/drivers/adc.h>
#include <stdio.h>
#include <nrf.h>

#define ADV_MIN_UNITS  2400        /* 1500 ms in 0.625 ms units */
#define ADV_MAX_UNITS  2560        /* 1600 ms */
#define VDD_FULL_MV    3000        /* fresh CR2032 under load */
#define VDD_EMPTY_MV   2200        /* the radio stops being reliable */

static char name[10];                                       /* "YT-H00012" */
static uint8_t mfg[5] = { 0xFF, 0xFF, 0x01, 0xFF, 0x01 };   /* battery unknown; just restarted */

static struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA(BT_DATA_NAME_COMPLETE, name, 9),
	BT_DATA(BT_DATA_MANUFACTURER_DATA, mfg, sizeof(mfg)),
};

/* the tag's number: UICR CUSTOMER[0]; an unwritten tag is YT-H00000 */
static void make_name(void)
{
	uint32_t n = NRF_UICR->CUSTOMER[0];
	if (n == 0xFFFFFFFFu || n > 99999u) {
		n = 0;
	}
	snprintf(name, sizeof(name), "YT-H%05u", (unsigned)n);
}

/* VDD through the SAADC (channel in app.overlay) → 0–100 % */
static const struct adc_dt_spec vdd = ADC_DT_SPEC_GET_BY_IDX(DT_PATH(zephyr_user), 0);

static uint8_t battery_percent(void)
{
	int16_t raw = 0;
	int32_t mv;
	struct adc_sequence seq = { .buffer = &raw, .buffer_size = sizeof(raw) };

	if (!adc_is_ready_dt(&vdd) || adc_channel_setup_dt(&vdd) < 0 ||
	    adc_sequence_init_dt(&vdd, &seq) < 0 || adc_read_dt(&vdd, &seq) < 0) {
		return 0xFF;                                    /* unknown */
	}
	mv = raw;
	if (adc_raw_to_millivolts_dt(&vdd, &mv) < 0) {
		return 0xFF;
	}
	if (mv >= VDD_FULL_MV) {
		return 100;
	}
	if (mv <= VDD_EMPTY_MV) {
		return 0;
	}
	return (uint8_t)((mv - VDD_EMPTY_MV) * 100 / (VDD_FULL_MV - VDD_EMPTY_MV));
}

int main(void)
{
	/* non-connectable, no scan response: as little radio time as possible */
	const struct bt_le_adv_param *param =
		BT_LE_ADV_PARAM(BT_LE_ADV_OPT_NONE, ADV_MIN_UNITS, ADV_MAX_UNITS, NULL);

	make_name();
	mfg[3] = battery_percent();

	if (bt_enable(NULL) != 0) {
		return 0;
	}
	if (bt_le_adv_start(param, ad, ARRAY_SIZE(ad), NULL, 0) != 0) {
		return 0;
	}

	for (;;) {
		k_sleep(K_HOURS(1));
		mfg[3] = battery_percent();
		mfg[4] = 0x00;                                  /* no longer "just restarted" */
		bt_le_adv_update_data(ad, ARRAY_SIZE(ad), NULL, 0);
	}
	return 0;
}

#ifndef ZCU111_V20_DPD_APP_CONFIG_H
#define ZCU111_V20_DPD_APP_CONFIG_H

#include "xparameters.h"

#define RFDC_DEVICE_ID XPAR_XRFDC_0_DEVICE_ID
#define RFDC_BASE      XPAR_XRFDC_0_BASEADDR
#define FIFO_DEVICE_ID XPAR_AXI_FIFO_0_DEVICE_ID

/* Fixed PL apertures. Regenerate xparameters.h from the V20 XSA when the
 * software platform is refreshed, then these can be replaced by XPAR names. */
#define DPD_BASE_ADDRESS     0xA0080000U
#define DPD_LAB_BASE_ADDRESS 0xA00C0000U

#define DAC_TILE_ID    1U
#define ADC_TILE_ID    1U
#define BLOCK_0        0U
#define BLOCK_1        1U

#define DEFAULT_DAC_MHZ 2400.0
#define DEFAULT_ADC_MHZ 2390.0

#define MAX_PAYLOAD_BYTES 256U
#define SYNC_WORD          0xD391C5A7U

#endif


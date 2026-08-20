#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "platform.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"
#include "xstatus.h"
#include "xllfifo.h"
#include "xuartps_hw.h"
#include "xrfdc.h"
#include "xrfdc_clk.h"
#include "app_config.h"
#include "dpd_runtime.h"

#define PREAMBLE_BYTES       4U
#define SYNC_BYTES           4U
#define LENGTH_BYTES         2U
#define CRC_BYTES            2U
#define MAX_FRAME_WORDS      (PREAMBLE_BYTES + SYNC_BYTES + LENGTH_BYTES + \
                              MAX_PAYLOAD_BYTES + CRC_BYTES)
#define MAX_RX_WORDS         (MAX_PAYLOAD_BYTES + 1U)
#define COMMAND_BUFFER_BYTES 2304U
#define RX_PACKETS_PER_POLL  8U

static XLlFifo FifoInstance;
static XRFdc RFdcInstance;
static u32 TxFrameWords[MAX_FRAME_WORDS];
static u32 RxFrameWords[MAX_RX_WORDS];
static char CommandBuffer[COMMAND_BUFFER_BYTES];
static unsigned int CommandLength;
static u8 LoopPayload[MAX_PAYLOAD_BYTES];
static u16 LoopPayloadLength;
static u32 LoopFramesQueued;
static u32 LoopRxOk;
static u32 LoopRxCrcFail;
static u32 LoopRxErrors;
static int LoopEnabled;

static double CurrentDacMHz = DEFAULT_DAC_MHZ;
static double CurrentAdcMHz = DEFAULT_ADC_MHZ;
static double CurrentPhaseDifferenceDeg = 0.0;

static unsigned int LMK04208_CKin[1][26] = {
    {0x00160040,0x80140320,0x80140321,0x80140322,
     0xC0140023,0x40140024,0x80141E05,0x03300006,0x01300007,0x06010008,
     0x55555549,0x9102410A,0x0401100B,0x1B0C006C,0x2302886D,0x0200000E,
     0x8000800F,0xC1550410,0x00000058,0x02C9C419,0x8FA8001A,0x10001E1B,
     0x0021201C,0x0180033D,0x0200033E,0x003F001F}
};

static u16 Crc16Byte(u16 crc, u8 data)
{
    int bit;
    crc ^= (u16)data << 8;
    for (bit = 0; bit < 8; ++bit) {
        if ((crc & 0x8000U) != 0U)
            crc = (u16)((crc << 1) ^ 0x1021U);
        else
            crc = (u16)(crc << 1);
    }
    return crc;
}

static int ConfigNco(u32 type, u32 tile, u32 block, double requestedMHz)
{
    XRFdc_Mixer_Settings mixer;
    double sampleRateGHz;
    double sampleRateMHz;
    double actualMHz = requestedMHz;
    u32 nyquistZone = 1U;
    int status;

    sampleRateGHz = (type == XRFDC_DAC_TILE)
        ? RFdcInstance.DAC_Tile[tile].PLL_Settings.SampleRate
        : RFdcInstance.ADC_Tile[tile].PLL_Settings.SampleRate;
    sampleRateMHz = sampleRateGHz * 1000.0;

    if (requestedMHz >= sampleRateMHz / 2.0) {
        nyquistZone = 2U;
        actualMHz = -requestedMHz;
    }

    status = XRFdc_GetMixerSettings(&RFdcInstance, type, tile, block, &mixer);
    if (status != XST_SUCCESS)
        return status;

    status = XRFdc_SetNyquistZone(&RFdcInstance, type, tile, block, nyquistZone);
    if (status != XST_SUCCESS)
        return status;

    mixer.Freq = actualMHz;
    mixer.EventSource = XRFDC_EVNT_SRC_TILE;
    mixer.MixerType = XRFDC_MIXER_TYPE_FINE;
    mixer.MixerMode = (type == XRFDC_DAC_TILE)
        ? XRFDC_MIXER_MODE_C2R : XRFDC_MIXER_MODE_R2C;
    if (type == XRFDC_DAC_TILE)
        mixer.FineMixerScale = XRFDC_MIXER_SCALE_1P0;

    return XRFdc_SetMixerSettings(&RFdcInstance, type, tile, block, &mixer);
}

static int SetDacFrequency(double frequencyMHz)
{
    int status = ConfigNco(XRFDC_DAC_TILE, DAC_TILE_ID, BLOCK_0, frequencyMHz);
    if (status == XST_SUCCESS)
        status = ConfigNco(XRFDC_DAC_TILE, DAC_TILE_ID, BLOCK_1, frequencyMHz);
    if (status == XST_SUCCESS)
        status = XRFdc_UpdateEvent(&RFdcInstance, XRFDC_DAC_TILE,
                                   DAC_TILE_ID, BLOCK_0, XRFDC_EVENT_MIXER);
    if (status == XST_SUCCESS)
        CurrentDacMHz = frequencyMHz;
    return status;
}

static int SetAdcFrequency(double frequencyMHz)
{
    int status = ConfigNco(XRFDC_ADC_TILE, ADC_TILE_ID, BLOCK_0, frequencyMHz);
    if (status == XST_SUCCESS)
        status = ConfigNco(XRFDC_ADC_TILE, ADC_TILE_ID, BLOCK_1, frequencyMHz);
    if (status == XST_SUCCESS)
        status = XRFdc_UpdateEvent(&RFdcInstance, XRFDC_ADC_TILE,
                                   ADC_TILE_ID, BLOCK_0, XRFDC_EVENT_MIXER);
    if (status == XST_SUCCESS)
        CurrentAdcMHz = frequencyMHz;
    return status;
}

static int SetOutphasing(double phaseDifferenceDeg)
{
    XRFdc_Mixer_Settings mixer0;
    XRFdc_Mixer_Settings mixer1;
    int status;

    if (phaseDifferenceDeg > 180.0)
        phaseDifferenceDeg = 180.0;
    if (phaseDifferenceDeg < -180.0)
        phaseDifferenceDeg = -180.0;

    status = XRFdc_GetMixerSettings(&RFdcInstance, XRFDC_DAC_TILE,
                                    DAC_TILE_ID, BLOCK_0, &mixer0);
    if (status != XST_SUCCESS)
        return status;
    status = XRFdc_GetMixerSettings(&RFdcInstance, XRFDC_DAC_TILE,
                                    DAC_TILE_ID, BLOCK_1, &mixer1);
    if (status != XST_SUCCESS)
        return status;

    mixer0.PhaseOffset = -phaseDifferenceDeg / 2.0;
    mixer1.PhaseOffset =  phaseDifferenceDeg / 2.0;
    mixer0.EventSource = XRFDC_EVNT_SRC_TILE;
    mixer1.EventSource = XRFDC_EVNT_SRC_TILE;

    status = XRFdc_SetMixerSettings(&RFdcInstance, XRFDC_DAC_TILE,
                                    DAC_TILE_ID, BLOCK_0, &mixer0);
    if (status == XST_SUCCESS)
        status = XRFdc_SetMixerSettings(&RFdcInstance, XRFDC_DAC_TILE,
                                        DAC_TILE_ID, BLOCK_1, &mixer1);
    if (status == XST_SUCCESS)
        status = XRFdc_UpdateEvent(&RFdcInstance, XRFDC_DAC_TILE,
                                   DAC_TILE_ID, BLOCK_0, XRFDC_EVENT_MIXER);
    if (status == XST_SUCCESS)
        CurrentPhaseDifferenceDeg = phaseDifferenceDeg;
    return status;
}

static int SetAmplitude(double scale)
{
    XRFdc_QMC_Settings qmc;
    u32 block;
    int status = XST_SUCCESS;

    if (scale < 0.0)
        scale = 0.0;
    if (scale > 1.0)
        scale = 1.0;

    for (block = BLOCK_0; block <= BLOCK_1; ++block) {
        status = XRFdc_GetQMCSettings(&RFdcInstance, XRFDC_DAC_TILE,
                                      DAC_TILE_ID, block, &qmc);
        if (status != XST_SUCCESS)
            return status;
        qmc.EnableGain = 1U;
        qmc.GainCorrectionFactor = scale;
        qmc.EventSource = XRFDC_EVNT_SRC_TILE;
        status = XRFdc_SetQMCSettings(&RFdcInstance, XRFDC_DAC_TILE,
                                      DAC_TILE_ID, block, &qmc);
        if (status != XST_SUCCESS)
            return status;
    }
    return XRFdc_UpdateEvent(&RFdcInstance, XRFDC_DAC_TILE,
                             DAC_TILE_ID, BLOCK_0, XRFDC_EVENT_QMC);
}

static void PrintMixer(u32 type, u32 tile, u32 block)
{
    XRFdc_Mixer_Settings mixer;
    const char *name = (type == XRFDC_DAC_TILE) ? "DAC" : "ADC";
    if (XRFdc_GetMixerSettings(&RFdcInstance, type, tile, block, &mixer)
        == XST_SUCCESS) {
        xil_printf("[MIXER] %s T%u B%u NCO=%d MHz phase=%d mode=%u scale=%u\r\n",
                   name, tile, block, (int)mixer.Freq, (int)mixer.PhaseOffset,
                   mixer.MixerMode, mixer.FineMixerScale);
    }
}

static void PrintStatus(void)
{
    XRFdc_IPStatus ipStatus;
    XRFdc_PLL_Settings pll;
    XRFdc_BlockStatus blockStatus;
    u32 block;

    memset(&ipStatus, 0, sizeof(ipStatus));
    if (XRFdc_GetIPStatus(&RFdcInstance, &ipStatus) != XST_SUCCESS) {
        xil_printf("[ERR] RFDC status read failed\r\n");
        return;
    }

    xil_printf("[STATUS] DAC T1 enabled=%u state=0x%x blocks=0x%x\r\n",
               ipStatus.DACTileStatus[DAC_TILE_ID].IsEnabled,
               ipStatus.DACTileStatus[DAC_TILE_ID].TileState,
               ipStatus.DACTileStatus[DAC_TILE_ID].BlockStatusMask);
    xil_printf("[STATUS] ADC T1 enabled=%u state=0x%x blocks=0x%x\r\n",
               ipStatus.ADCTileStatus[ADC_TILE_ID].IsEnabled,
               ipStatus.ADCTileStatus[ADC_TILE_ID].TileState,
               ipStatus.ADCTileStatus[ADC_TILE_ID].BlockStatusMask);

    if (XRFdc_GetPLLConfig(&RFdcInstance, XRFDC_DAC_TILE,
                           DAC_TILE_ID, &pll) == XST_SUCCESS)
        xil_printf("[CLOCK] DAC ref=%d MHz sample=%d MHz pll_enable=%u\r\n",
                   (int)pll.RefClkFreq, (int)(pll.SampleRate * 1000.0), pll.Enabled);
    if (XRFdc_GetPLLConfig(&RFdcInstance, XRFDC_ADC_TILE,
                           ADC_TILE_ID, &pll) == XST_SUCCESS)
        xil_printf("[CLOCK] ADC ref=%d MHz sample=%d MHz pll_enable=%u\r\n",
                   (int)pll.RefClkFreq, (int)(pll.SampleRate * 1000.0), pll.Enabled);

    for (block = 0; block < 2; ++block) {
        if (XRFdc_GetBlockStatus(&RFdcInstance, XRFDC_DAC_TILE,
                                 DAC_TILE_ID, block, &blockStatus) == XST_SUCCESS)
            xil_printf("[BLOCK] DAC B%u fs=%d MHz data_clk=%u fifo_alarm=%u\r\n",
                       block, (int)(blockStatus.SamplingFreq * 1000.0),
                       blockStatus.DataPathClocksStatus,
                       blockStatus.IsFIFOFlagsAsserted);
        if (XRFdc_GetBlockStatus(&RFdcInstance, XRFDC_ADC_TILE,
                                 ADC_TILE_ID, block, &blockStatus) == XST_SUCCESS)
            xil_printf("[BLOCK] ADC B%u fs=%d MHz data_clk=%u fifo_alarm=%u\r\n",
                       block, (int)(blockStatus.SamplingFreq * 1000.0),
                       blockStatus.DataPathClocksStatus,
                       blockStatus.IsFIFOFlagsAsserted);
    }

    PrintMixer(XRFDC_DAC_TILE, DAC_TILE_ID, BLOCK_0);
    PrintMixer(XRFDC_DAC_TILE, DAC_TILE_ID, BLOCK_1);
    PrintMixer(XRFDC_ADC_TILE, ADC_TILE_ID, BLOCK_0);
    PrintMixer(XRFDC_ADC_TILE, ADC_TILE_ID, BLOCK_1);
    xil_printf("[MODE] requested DAC=%d MHz ADC=%d MHz IF=%d MHz phase_diff=%d deg\r\n",
               (int)CurrentDacMHz, (int)CurrentAdcMHz,
               (int)(CurrentDacMHz - CurrentAdcMHz),
               (int)CurrentPhaseDifferenceDeg);
}

static void PrintStartupStatus(const char *stage)
{
    XRFdc_IPStatus ipStatus;

    memset(&ipStatus, 0, sizeof(ipStatus));
    if (XRFdc_GetIPStatus(&RFdcInstance, &ipStatus) != XST_SUCCESS) {
        xil_printf("[RFDC] %s: status read failed\r\n", stage);
        return;
    }

    xil_printf("[RFDC] %s DAC T%u: enabled=%u state=0x%x power=%u "
               "pll=%u blocks=0x%x\r\n",
               stage, DAC_TILE_ID,
               ipStatus.DACTileStatus[DAC_TILE_ID].IsEnabled,
               ipStatus.DACTileStatus[DAC_TILE_ID].TileState,
               ipStatus.DACTileStatus[DAC_TILE_ID].PowerUpState,
               ipStatus.DACTileStatus[DAC_TILE_ID].PLLState,
               ipStatus.DACTileStatus[DAC_TILE_ID].BlockStatusMask);
    xil_printf("[RFDC] %s ADC T%u: enabled=%u state=0x%x power=%u "
               "pll=%u blocks=0x%x\r\n",
               stage, ADC_TILE_ID,
               ipStatus.ADCTileStatus[ADC_TILE_ID].IsEnabled,
               ipStatus.ADCTileStatus[ADC_TILE_ID].TileState,
               ipStatus.ADCTileStatus[ADC_TILE_ID].PowerUpState,
               ipStatus.ADCTileStatus[ADC_TILE_ID].PLLState,
               ipStatus.ADCTileStatus[ADC_TILE_ID].BlockStatusMask);
}

static int StartRfDataConverter(void)
{
    XRFdc_IPStatus ipStatus;
    int status;

    memset(&ipStatus, 0, sizeof(ipStatus));
    status = XRFdc_GetIPStatus(&RFdcInstance, &ipStatus);
    if (status != XST_SUCCESS) {
        xil_printf("[RFDC] initial status read failed: status=%d\r\n", status);
        return status;
    }

    PrintStartupStatus("before restart");

    Xil_Out32(RFDC_BASE + 0x0004U, 1U);
    sleep(1);

    if (ipStatus.DACTileStatus[DAC_TILE_ID].IsEnabled == 0U) {
        xil_printf("[RFDC] configured DAC Tile%u is not enabled\r\n",
                   DAC_TILE_ID);
        return XST_FAILURE;
    }
    xil_printf("[RFDC] starting DAC Tile%u...\r\n", DAC_TILE_ID);
    status = XRFdc_StartUp(&RFdcInstance, XRFDC_DAC_TILE, DAC_TILE_ID);
    if (status != XST_SUCCESS) {
        xil_printf("[RFDC] DAC Tile%u startup failed: status=%d\r\n",
                   DAC_TILE_ID, status);
        PrintStartupStatus("after DAC failure");
        return status;
    }
    xil_printf("[RFDC] DAC Tile%u startup complete\r\n", DAC_TILE_ID);

    if (ipStatus.ADCTileStatus[ADC_TILE_ID].IsEnabled == 0U) {
        xil_printf("[RFDC] configured ADC Tile%u is not enabled\r\n",
                   ADC_TILE_ID);
        return XST_FAILURE;
    }
    xil_printf("[RFDC] starting ADC Tile%u...\r\n", ADC_TILE_ID);
    status = XRFdc_StartUp(&RFdcInstance, XRFDC_ADC_TILE, ADC_TILE_ID);
    if (status != XST_SUCCESS) {
        xil_printf("[RFDC] ADC Tile%u startup failed: status=%d\r\n",
                   ADC_TILE_ID, status);
        PrintStartupStatus("after ADC failure");
        return status;
    }
    xil_printf("[RFDC] ADC Tile%u startup complete\r\n", ADC_TILE_ID);
    PrintStartupStatus("startup complete");
    return XST_SUCCESS;
}

static int QueuePayload(const u8 *payload, u16 payloadLength, int verbose)
{
    u16 crc = 0xFFFFU;
    unsigned int index = 0U;
    unsigned int payloadIndex;
    unsigned int frameWords;

    if (payloadLength > MAX_PAYLOAD_BYTES)
        return XST_INVALID_PARAM;

    TxFrameWords[index++] = 0xFFU;
    TxFrameWords[index++] = 0xFFU;
    TxFrameWords[index++] = 0xFFU;
    TxFrameWords[index++] = 0xFFU;
    TxFrameWords[index++] = (SYNC_WORD >> 24) & 0xFFU;
    TxFrameWords[index++] = (SYNC_WORD >> 16) & 0xFFU;
    TxFrameWords[index++] = (SYNC_WORD >> 8) & 0xFFU;
    TxFrameWords[index++] = SYNC_WORD & 0xFFU;

    TxFrameWords[index++] = (payloadLength >> 8) & 0xFFU;
    crc = Crc16Byte(crc, (u8)(payloadLength >> 8));
    TxFrameWords[index++] = payloadLength & 0xFFU;
    crc = Crc16Byte(crc, (u8)payloadLength);

    for (payloadIndex = 0; payloadIndex < payloadLength; ++payloadIndex) {
        TxFrameWords[index++] = payload[payloadIndex];
        crc = Crc16Byte(crc, payload[payloadIndex]);
    }
    TxFrameWords[index++] = (crc >> 8) & 0xFFU;
    TxFrameWords[index++] = crc & 0xFFU;
    frameWords = index;

    if (XLlFifo_TxVacancy(&FifoInstance) < frameWords + 1U) {
        if (verbose) {
            xil_printf("[ERR] TX FIFO has %u words free; frame needs %u\r\n",
                       XLlFifo_TxVacancy(&FifoInstance), frameWords + 1U);
        }
        return XST_DEVICE_BUSY;
    }

    XLlFifo_Write(&FifoInstance, TxFrameWords, frameWords * sizeof(u32));
    XLlFifo_TxSetLen(&FifoInstance, frameWords * sizeof(u32));
    if (verbose) {
        xil_printf("[TX] payload=%u bytes frame=%u symbols CRC=0x%04x\r\n",
                   payloadLength, frameWords * 8U, crc);
    }
    return XST_SUCCESS;
}

static int SendPayload(const u8 *payload, u16 payloadLength)
{
    return QueuePayload(payload, payloadLength, 1);
}

static void ServiceLoopTransmission(void)
{
    int status;

    if (!LoopEnabled)
        return;

    status = QueuePayload(LoopPayload, LoopPayloadLength, 0);
    if (status == XST_SUCCESS) {
        ++LoopFramesQueued;
    } else if (status != XST_DEVICE_BUSY) {
        LoopEnabled = 0;
        xil_printf("\r\n[LOOP ERR] continuous transmission stopped: status=%d\r\n> ",
                   status);
    }
}

static void PollReceiveFifo(void)
{
    u32 packetBytes;
    u32 packetWords;
    u32 status;
    u32 payloadLength;
    u32 index;
    u32 packetsProcessed = 0U;

    if (XLlFifo_IsRxDone(&FifoInstance) == 0)
        return;

    while (XLlFifo_RxOccupancy(&FifoInstance) != 0U &&
           packetsProcessed < RX_PACKETS_PER_POLL) {
        ++packetsProcessed;
        packetBytes = XLlFifo_RxGetLen(&FifoInstance);
        packetWords = (packetBytes + sizeof(u32) - 1U) / sizeof(u32);
        if (packetWords > MAX_RX_WORDS) {
            u32 discard;
            ++LoopRxErrors;
            if (!LoopEnabled)
                xil_printf("\r\n[RX ERR] oversized FIFO packet: %u bytes\r\n", packetBytes);
            while (packetBytes != 0U) {
                XLlFifo_Read(&FifoInstance, &discard, sizeof(discard));
                packetBytes = (packetBytes > sizeof(discard))
                    ? packetBytes - sizeof(discard) : 0U;
            }
            continue;
        }

        XLlFifo_Read(&FifoInstance, RxFrameWords, packetBytes);
        if (packetWords == 0U || ((RxFrameWords[0] >> 24) & 0xFFU) != 0xD5U) {
            ++LoopRxErrors;
            if (!LoopEnabled)
                xil_printf("\r\n[RX ERR] invalid receiver packet\r\n");
            continue;
        }

        status = (RxFrameWords[0] >> 16) & 0xFFU;
        payloadLength = RxFrameWords[0] & 0xFFFFU;
        if (status == 0U) {
            ++LoopRxCrcFail;
            if (!LoopEnabled)
                xil_printf("\r\n[RX CRC FAIL] decoded_length=%u\r\n", payloadLength);
            continue;
        }
        if (payloadLength + 1U > packetWords) {
            ++LoopRxErrors;
            if (!LoopEnabled) {
                xil_printf("\r\n[RX ERR] truncated packet: length=%u words=%u\r\n",
                           payloadLength, packetWords);
            }
            continue;
        }

        if (LoopEnabled) {
            ++LoopRxOk;
            continue;
        }

        xil_printf("\r\n[RX CRC OK] %u byte(s)\r\n[RX ASCII] ", payloadLength);
        for (index = 0; index < payloadLength; ++index) {
            u8 value = (u8)(RxFrameWords[index + 1U] & 0xFFU);
            outbyte((value >= 32U && value <= 126U) ? (char)value : '.');
        }
        xil_printf("\r\n[RX HEX]  ");
        for (index = 0; index < payloadLength; ++index)
            xil_printf("%02x ", (u8)(RxFrameWords[index + 1U] & 0xFFU));
        xil_printf("\r\n> ");
    }

    if (XLlFifo_RxOccupancy(&FifoInstance) == 0U)
        XLlFifo_IntClear(&FifoInstance, XLLF_INT_RC_MASK);
}

static void PrintHelp(void)
{
    xil_printf("\r\nCommands:\r\n");
    xil_printf("  SEND <text>       transmit ASCII text with framing and CRC\r\n");
    xil_printf("  LOOP <text>       continuously transmit framed ASCII text\r\n");
    xil_printf("  STOP              stop continuous transmission\r\n");
    xil_printf("  TRAS <bits>       transmit binary bytes, MSB first\r\n");
    xil_printf("  DACF <MHz>        set both DAC NCOs\r\n");
    xil_printf("  ADCF <MHz>        set both ADC NCOs\r\n");
    xil_printf("  PASE <deg>        symmetric phase: DAC10=-deg/2, DAC11=+deg/2\r\n");
    xil_printf("  AMPL <0..1>       set equal QMC gain on both DAC channels\r\n");
    xil_printf("  DACR / ADCR       mixer readback\r\n");
    xil_printf("  STAT              RFDC clock and block status\r\n");
    DpdPrintHelp();
    xil_printf("  HELP              show this text\r\n");
    xil_printf("Receiver expects DAC-ADC frequency difference of +10 MHz.\r\n");
}

static void ProcessCommand(char *line)
{
    char command[8];
    char *argument;
    unsigned int commandIndex = 0U;
    double value;
    int status;

    while (*line == ' ' || *line == '\t')
        ++line;
    argument = line;
    while (*argument != '\0' && *argument != ' ' && *argument != '\t') {
        if (commandIndex < sizeof(command) - 1U)
            command[commandIndex++] = (char)toupper((unsigned char)*argument);
        ++argument;
    }
    command[commandIndex] = '\0';
    while (*argument == ' ' || *argument == '\t')
        ++argument;

    if (strcmp(command, "SEND") == 0) {
        size_t length = strlen(argument);
        if (length == 0U || length > MAX_PAYLOAD_BYTES)
            xil_printf("\r\n[ERR] SEND length must be 1..%u bytes\r\n",
                       MAX_PAYLOAD_BYTES);
        else
            SendPayload((const u8 *)argument, (u16)length);
    } else if (strcmp(command, "LOOP") == 0) {
        size_t length = strlen(argument);
        if (length == 0U || length > MAX_PAYLOAD_BYTES) {
            xil_printf("\r\n[ERR] LOOP length must be 1..%u bytes\r\n",
                       MAX_PAYLOAD_BYTES);
        } else {
            memcpy(LoopPayload, argument, length);
            LoopPayloadLength = (u16)length;
            LoopFramesQueued = 0U;
            LoopRxOk = 0U;
            LoopRxCrcFail = 0U;
            LoopRxErrors = 0U;
            LoopEnabled = 1;
            xil_printf("\r\n[OK] continuous TX started: payload=%u bytes; use STOP to end\r\n",
                       LoopPayloadLength);
        }
    } else if (strcmp(command, "STOP") == 0) {
        if (LoopEnabled) {
            LoopEnabled = 0;
            xil_printf("\r\n[OK] continuous TX stopped: queued=%u rx_ok=%u "
                       "crc_fail=%u rx_err=%u\r\n",
                       LoopFramesQueued, LoopRxOk, LoopRxCrcFail,
                       LoopRxErrors);
        } else {
            xil_printf("\r\n[OK] continuous TX is not active\r\n");
        }
    } else if (strcmp(command, "TRAS") == 0) {
        static u8 binaryPayload[MAX_PAYLOAD_BYTES];
        size_t bitLength = strlen(argument);
        size_t byteIndex;
        int bitIndex;
        int valid = (bitLength != 0U) && ((bitLength % 8U) == 0U) &&
                    (bitLength <= MAX_PAYLOAD_BYTES * 8U);
        for (byteIndex = 0; valid && byteIndex < bitLength / 8U; ++byteIndex) {
            u8 byteValue = 0U;
            for (bitIndex = 0; bitIndex < 8; ++bitIndex) {
                char bit = argument[byteIndex * 8U + (unsigned int)bitIndex];
                if (bit != '0' && bit != '1') {
                    valid = 0;
                    break;
                }
                byteValue = (u8)((byteValue << 1) | (u8)(bit - '0'));
            }
            binaryPayload[byteIndex] = byteValue;
        }
        if (!valid)
            xil_printf("\r\n[ERR] TRAS requires 8..2048 binary digits in groups of 8\r\n");
        else
            SendPayload(binaryPayload, (u16)(bitLength / 8U));
    } else if (strcmp(command, "DACF") == 0) {
        value = atof(argument);
        status = SetDacFrequency(value);
        xil_printf(status == XST_SUCCESS ? "\r\n[OK] DAC NCO updated\r\n"
                                         : "\r\n[ERR] DAC NCO update failed\r\n");
    } else if (strcmp(command, "ADCF") == 0) {
        value = atof(argument);
        status = SetAdcFrequency(value);
        xil_printf(status == XST_SUCCESS ? "\r\n[OK] ADC NCO updated\r\n"
                                         : "\r\n[ERR] ADC NCO update failed\r\n");
    } else if (strcmp(command, "PASE") == 0) {
        value = atof(argument);
        status = SetOutphasing(value);
        xil_printf(status == XST_SUCCESS ? "\r\n[OK] symmetric phase updated\r\n"
                                         : "\r\n[ERR] phase update failed\r\n");
    } else if (strcmp(command, "AMPL") == 0) {
        value = atof(argument);
        status = SetAmplitude(value);
        xil_printf(status == XST_SUCCESS ? "\r\n[OK] equal DAC amplitude updated\r\n"
                                         : "\r\n[ERR] amplitude update failed\r\n");
    } else if (strcmp(command, "DACR") == 0) {
        PrintMixer(XRFDC_DAC_TILE, DAC_TILE_ID, BLOCK_0);
        PrintMixer(XRFDC_DAC_TILE, DAC_TILE_ID, BLOCK_1);
    } else if (strcmp(command, "ADCR") == 0) {
        PrintMixer(XRFDC_ADC_TILE, ADC_TILE_ID, BLOCK_0);
        PrintMixer(XRFDC_ADC_TILE, ADC_TILE_ID, BLOCK_1);
    } else if (strcmp(command, "STAT") == 0) {
        PrintStatus();
        xil_printf("[LOOP] enabled=%u payload=%u queued=%u rx_ok=%u "
                   "crc_fail=%u rx_err=%u\r\n",
                   (unsigned int)LoopEnabled, LoopPayloadLength,
                   LoopFramesQueued, LoopRxOk, LoopRxCrcFail,
                   LoopRxErrors);
    } else if (strcmp(command, "HELP") == 0 || command[0] == '\0') {
        PrintHelp();
    } else if (DpdProcessCommand(command, argument)) {
        /* Command handled by the DPD/LAB runtime. */
    } else {
        xil_printf("\r\n[ERR] unknown command: %s\r\n", command);
        PrintHelp();
    }
}

static void PollConsole(void)
{
    while (XUartPs_IsReceiveData(STDIN_BASEADDRESS)) {
        char character = (char)(XUartPs_ReadReg(STDIN_BASEADDRESS,
                                                XUARTPS_FIFO_OFFSET) & 0xFFU);
        if (character == '\r' || character == '\n') {
            if (CommandLength != 0U) {
                CommandBuffer[CommandLength] = '\0';
                xil_printf("\r\n");
                ProcessCommand(CommandBuffer);
                CommandLength = 0U;
                xil_printf("> ");
            }
        } else if (character == '\b' || character == 0x7F) {
            if (CommandLength != 0U) {
                --CommandLength;
                xil_printf("\b \b");
            }
        } else if (CommandLength < COMMAND_BUFFER_BYTES - 1U) {
            CommandBuffer[CommandLength++] = character;
            outbyte(character);
        }
    }
}

int main(void)
{
    XLlFifo_Config *fifoConfig;
    XRFdc_Config *rfdcConfig;
    int status;

    init_platform();
    xil_printf("\r\nZCU111 V20 DBPSK + software/hardware MP-DPD laboratory\r\n");
    xil_printf("Configuring LMK/LMX clocks...\r\n");
    LMK04208ClockConfig(1, LMK04208_CKin);
    status = LMX2594ClockConfig(1, 2949120, 5898240);
    if (status != XST_SUCCESS) {
        xil_printf("[FATAL] clock configuration failed\r\n");
        return XST_FAILURE;
    }

    fifoConfig = XLlFfio_LookupConfig(FIFO_DEVICE_ID);
    if (fifoConfig == NULL)
        return XST_FAILURE;
    status = XLlFifo_CfgInitialize(&FifoInstance, fifoConfig,
                                   fifoConfig->BaseAddress);
    if (status != XST_SUCCESS)
        return XST_FAILURE;
    XLlFifo_IntClear(&FifoInstance, XLLF_INT_ALL_MASK);

    rfdcConfig = XRFdc_LookupConfig(RFDC_DEVICE_ID);
    if (rfdcConfig == NULL)
        return XST_FAILURE;
    status = XRFdc_CfgInitialize(&RFdcInstance, rfdcConfig);
    if (status != XST_SUCCESS)
        return XST_FAILURE;
    status = StartRfDataConverter();
    if (status != XST_SUCCESS) {
        xil_printf("[FATAL] RFDC startup failed\r\n");
        return XST_FAILURE;
    }

    status = SetDacFrequency(DEFAULT_DAC_MHZ);
    if (status == XST_SUCCESS)
        status = SetAdcFrequency(DEFAULT_ADC_MHZ);
    if (status == XST_SUCCESS)
        status = SetOutphasing(0.0);
    if (status == XST_SUCCESS)
        status = SetAmplitude(1.0);
    if (status != XST_SUCCESS) {
        xil_printf("[FATAL] default RF configuration failed\r\n");
        return XST_FAILURE;
    }

    DpdRuntimePrintVersions();

    PrintStatus();
    PrintHelp();
    xil_printf("\r\n> ");

    while (1) {
        PollConsole();
        PollReceiveFifo();
        ServiceLoopTransmission();
    }

    cleanup_platform();
    return 0;
}

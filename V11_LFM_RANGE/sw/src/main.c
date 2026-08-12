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

#define COMMAND_BUFFER_BYTES 128U
#define RX_PACKETS_PER_POLL  16U

static XLlFifo FifoInstance;
static XRFdc RFdcInstance;
static char CommandBuffer[COMMAND_BUFFER_BYTES];
static unsigned int CommandLength;

static double CurrentDacMHz = DEFAULT_DAC_MHZ;
static double CurrentAdcMHz = DEFAULT_ADC_MHZ;
static double RangeOffsetMm;
static u32 PeakThreshold = DEFAULT_THRESHOLD;
static u32 PrintDivisor = DEFAULT_PRINT_DIV;
static u32 ResultCount;
static u32 DroppedPackets;
static int RadarRunning;
static int RangeCalibrationPending;
static double RangeCalibrationKnownMm;

static unsigned int LMK04208_CKin[1][26] = {
    {0x00160040,0x80140320,0x80140321,0x80140322,
     0xC0140023,0x40140024,0x80141E05,0x03300006,0x01300007,0x06010008,
     0x55555549,0x9102410A,0x0401100B,0x1B0C006C,0x2302886D,0x0200000E,
     0x8000800F,0xC1550410,0x00000058,0x02C9C419,0x8FA8001A,0x10001E1B,
     0x0021201C,0x0180033D,0x0200033E,0x003F001F}
};

static int ConfigNco(u32 type, u32 tile, u32 block, double requestedMHz)
{
    XRFdc_Mixer_Settings mixer;
    double sampleRateMHz;
    double actualMHz = requestedMHz;
    u32 nyquistZone = 1U;
    int status;

    sampleRateMHz = ((type == XRFDC_DAC_TILE)
        ? RFdcInstance.DAC_Tile[tile].PLL_Settings.SampleRate
        : RFdcInstance.ADC_Tile[tile].PLL_Settings.SampleRate) * 1000.0;

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

static void PrintStartupStatus(const char *stage)
{
    XRFdc_IPStatus ipStatus;
    memset(&ipStatus, 0, sizeof(ipStatus));
    if (XRFdc_GetIPStatus(&RFdcInstance, &ipStatus) != XST_SUCCESS) {
        xil_printf("[RFDC] %s: status read failed\r\n", stage);
        return;
    }
    xil_printf("[RFDC] %s DAC T%u: enabled=%u state=0x%x power=%u pll=%u blocks=0x%x\r\n",
               stage, DAC_TILE_ID,
               ipStatus.DACTileStatus[DAC_TILE_ID].IsEnabled,
               ipStatus.DACTileStatus[DAC_TILE_ID].TileState,
               ipStatus.DACTileStatus[DAC_TILE_ID].PowerUpState,
               ipStatus.DACTileStatus[DAC_TILE_ID].PLLState,
               ipStatus.DACTileStatus[DAC_TILE_ID].BlockStatusMask);
    xil_printf("[RFDC] %s ADC T%u: enabled=%u state=0x%x power=%u pll=%u blocks=0x%x\r\n",
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
    if (status != XST_SUCCESS)
        return status;
    PrintStartupStatus("before restart");

    Xil_Out32(RFDC_BASE + 0x0004U, 1U);
    sleep(1);

    if (ipStatus.DACTileStatus[DAC_TILE_ID].IsEnabled == 0U)
        return XST_FAILURE;
    xil_printf("[RFDC] starting DAC Tile%u...\r\n", DAC_TILE_ID);
    status = XRFdc_StartUp(&RFdcInstance, XRFDC_DAC_TILE, DAC_TILE_ID);
    if (status != XST_SUCCESS) {
        PrintStartupStatus("after DAC failure");
        return status;
    }

    if (ipStatus.ADCTileStatus[ADC_TILE_ID].IsEnabled == 0U)
        return XST_FAILURE;
    xil_printf("[RFDC] starting ADC Tile%u...\r\n", ADC_TILE_ID);
    status = XRFdc_StartUp(&RFdcInstance, XRFDC_ADC_TILE, ADC_TILE_ID);
    if (status != XST_SUCCESS) {
        PrintStartupStatus("after ADC failure");
        return status;
    }
    PrintStartupStatus("startup complete");
    return XST_SUCCESS;
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

    for (block = 0U; block < 2U; ++block) {
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
    xil_printf("[RANGE] running=%u DAC=%d MHz ADC=%d MHz offset=%d mm threshold=%u print_div=%u results=%u dropped=%u\r\n",
               (unsigned int)RadarRunning, (int)CurrentDacMHz,
               (int)CurrentAdcMHz, (int)RangeOffsetMm, PeakThreshold,
               PrintDivisor, ResultCount, DroppedPackets);
}

static int SendRadarCommand(u32 command)
{
    if (XLlFifo_TxVacancy(&FifoInstance) < 2U)
        return XST_DEVICE_BUSY;
    XLlFifo_Write(&FifoInstance, &command, sizeof(command));
    XLlFifo_TxSetLen(&FifoInstance, sizeof(command));
    return XST_SUCCESS;
}

static double PeakFraction(u32 left, u32 peak, u32 right)
{
    double denominator = (double)left - 2.0 * (double)peak + (double)right;
    double fraction;
    if (denominator > -1.0 && denominator < 1.0)
        return 0.0;
    fraction = 0.5 * ((double)left - (double)right) / denominator;
    if (fraction > 0.5)
        fraction = 0.5;
    if (fraction < -0.5)
        fraction = -0.5;
    return fraction;
}

static void HandleRangePacket(const u32 *words)
{
    u32 sequence = words[1] >> 16;
    u32 lag = words[1] & 0xFFFFU;
    u32 peak = words[2];
    u32 left = words[3];
    u32 right = words[4];
    u32 flags = words[5];
    double lagSamples;
    double distanceMm;
    int distanceIntegerMm;

    if ((flags & 0x2U) != 0U) {
        xil_printf("\r\n[BGCAL] leakage/background calibration complete; seq=%u\r\n> ",
                   sequence);
        return;
    }
    ++ResultCount;
    if (peak < PeakThreshold)
        return;

    lagSamples = (double)lag + PeakFraction(left, peak, right);
    distanceMm = lagSamples * RANGE_MM_PER_SAMPLE + RangeOffsetMm;

    if (RangeCalibrationPending) {
        RangeOffsetMm = RangeCalibrationKnownMm -
                        lagSamples * RANGE_MM_PER_SAMPLE;
        RangeCalibrationPending = 0;
        xil_printf("\r\n[RCAL] complete: offset=%d mm, reference=%d mm\r\n> ",
                   (int)RangeOffsetMm, (int)RangeCalibrationKnownMm);
        return;
    }
    if (distanceMm < 0.0)
        return;
    if ((ResultCount % PrintDivisor) != 0U)
        return;

    distanceIntegerMm = (int)(distanceMm + 0.5);
    xil_printf("\r\n[RANGE] %d.%03d m  (%d mm) peak=%u lag=%u seq=%u\r\n> ",
               distanceIntegerMm / 1000, distanceIntegerMm % 1000,
               distanceIntegerMm, peak, lag, sequence);
}

static void PollRangeFifo(void)
{
    u32 words[RADAR_RESULT_WORDS];
    u32 packetBytes;
    u32 packetsProcessed = 0U;

    if (XLlFifo_IsRxDone(&FifoInstance) == 0)
        return;
    while (XLlFifo_RxOccupancy(&FifoInstance) != 0U &&
           packetsProcessed < RX_PACKETS_PER_POLL) {
        ++packetsProcessed;
        packetBytes = XLlFifo_RxGetLen(&FifoInstance);
        if (packetBytes != sizeof(words)) {
            u32 discard;
            ++DroppedPackets;
            while (packetBytes != 0U) {
                XLlFifo_Read(&FifoInstance, &discard, sizeof(discard));
                packetBytes = (packetBytes > sizeof(discard))
                    ? packetBytes - sizeof(discard) : 0U;
            }
            continue;
        }
        XLlFifo_Read(&FifoInstance, words, sizeof(words));
        if (words[0] == RADAR_RESULT_MAGIC)
            HandleRangePacket(words);
        else
            ++DroppedPackets;
    }
    if (XLlFifo_RxOccupancy(&FifoInstance) == 0U)
        XLlFifo_IntClear(&FifoInstance, XLLF_INT_RC_MASK);
}

static void PrintHelp(void)
{
    xil_printf("\r\nCommands:\r\n");
    xil_printf("  BGCAL             capture no-target leakage/background (run first)\r\n");
    xil_printf("  START             start 10 kHz LFM pulse transmission and ranging\r\n");
    xil_printf("  STOP              stop LFM pulse transmission\r\n");
    xil_printf("  RCAL <mm>         use next valid target as known-distance calibration\r\n");
    xil_printf("  CALCLR            clear range offset\r\n");
    xil_printf("  THRE <score>      set minimum peak score (default 1000)\r\n");
    xil_printf("  PRINT <N>         print one of every N valid results (default 9)\r\n");
    xil_printf("  DACF <MHz>        set both DAC NCOs\r\n");
    xil_printf("  ADCF <MHz>        set both ADC NCOs\r\n");
    xil_printf("  DACR / ADCR       mixer readback\r\n");
    xil_printf("  STAT              RFDC and ranging status\r\n");
    xil_printf("  HELP              show this text\r\n");
    xil_printf("Default RF: 2400 MHz, 400 MHz LFM, 4096 samples, 10 kHz PRF.\r\n");
}

static void ProcessCommand(char *line)
{
    char command[12];
    char *argument;
    unsigned int commandIndex = 0U;
    double value;
    unsigned long integerValue;
    int status = XST_SUCCESS;

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

    if (strcmp(command, "BGCAL") == 0) {
        status = SendRadarCommand(RADAR_CMD_BGCAL);
        if (status == XST_SUCCESS && !RadarRunning) {
            status = SendRadarCommand(RADAR_CMD_START);
            if (status == XST_SUCCESS)
                RadarRunning = 1;
        }
        xil_printf(status == XST_SUCCESS
            ? "\r\n[OK] background calibration requested; remove targets until [BGCAL] appears\r\n"
            : "\r\n[ERR] background calibration command failed\r\n");
    } else if (strcmp(command, "START") == 0) {
        status = SendRadarCommand(RADAR_CMD_START);
        if (status == XST_SUCCESS)
            RadarRunning = 1;
        xil_printf(status == XST_SUCCESS ? "\r\n[OK] ranging started\r\n"
                                         : "\r\n[ERR] START failed\r\n");
    } else if (strcmp(command, "STOP") == 0) {
        status = SendRadarCommand(RADAR_CMD_STOP);
        if (status == XST_SUCCESS)
            RadarRunning = 0;
        xil_printf(status == XST_SUCCESS ? "\r\n[OK] ranging stopped\r\n"
                                         : "\r\n[ERR] STOP failed\r\n");
    } else if (strcmp(command, "RCAL") == 0) {
        value = atof(argument);
        if (value < 0.0) {
            xil_printf("\r\n[ERR] RCAL distance must be >= 0 mm\r\n");
        } else {
            RangeCalibrationKnownMm = value;
            RangeCalibrationPending = 1;
            xil_printf("\r\n[OK] waiting for next peak for %d mm calibration\r\n",
                       (int)value);
        }
    } else if (strcmp(command, "CALCLR") == 0) {
        RangeOffsetMm = 0.0;
        RangeCalibrationPending = 0;
        xil_printf("\r\n[OK] range offset cleared\r\n");
    } else if (strcmp(command, "THRE") == 0) {
        PeakThreshold = (u32)strtoul(argument, NULL, 0);
        xil_printf("\r\n[OK] threshold=%u\r\n", PeakThreshold);
    } else if (strcmp(command, "PRINT") == 0) {
        integerValue = strtoul(argument, NULL, 0);
        if (integerValue == 0UL)
            xil_printf("\r\n[ERR] PRINT divisor must be >= 1\r\n");
        else {
            PrintDivisor = (u32)integerValue;
            xil_printf("\r\n[OK] print divisor=%u\r\n", PrintDivisor);
        }
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
    } else if (strcmp(command, "DACR") == 0) {
        PrintMixer(XRFDC_DAC_TILE, DAC_TILE_ID, BLOCK_0);
        PrintMixer(XRFDC_DAC_TILE, DAC_TILE_ID, BLOCK_1);
    } else if (strcmp(command, "ADCR") == 0) {
        PrintMixer(XRFDC_ADC_TILE, ADC_TILE_ID, BLOCK_0);
        PrintMixer(XRFDC_ADC_TILE, ADC_TILE_ID, BLOCK_1);
    } else if (strcmp(command, "STAT") == 0) {
        PrintStatus();
    } else if (strcmp(command, "HELP") == 0 || command[0] == '\0') {
        PrintHelp();
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
    xil_printf("\r\nZCU111 V11 LFM short-range radar\r\n");
    xil_printf("Configuring verified V10 LMK/LMX clock path...\r\n");
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
    if (status != XST_SUCCESS) {
        xil_printf("[FATAL] default RF configuration failed\r\n");
        return XST_FAILURE;
    }

    PrintStatus();
    PrintHelp();
    xil_printf("\r\nSafety: never connect the 30 dBm PA output directly to an RFSoC ADC.\r\n");
    xil_printf("Run BGCAL with the target removed, then place target and use START.\r\n> ");

    while (1) {
        PollConsole();
        PollRangeFifo();
    }

    cleanup_platform();
    return 0;
}

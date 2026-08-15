#include <stdlib.h>
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "sleep.h"
#include "xstatus.h"
#include "app_config.h"
#include "dpd_runtime.h"

#define DPD_CONTROL_OFFSET       0x00000U
#define DPD_STATUS_OFFSET        0x00004U
#define DPD_CLIP_COUNT_OFFSET    0x00008U
#define DPD_VERSION_OFFSET       0x0000CU
#define DPD_LUT_WINDOW_OFFSET    0x20000U

#define LAB_CONTROL_OFFSET       0x00000U
#define LAB_STATUS_OFFSET        0x00004U
#define LAB_PLAY_LENGTH_OFFSET   0x00008U
#define LAB_CAPTURE_TARGET_OFFSET 0x0000CU
#define LAB_CAPTURE_COUNT_OFFSET 0x00010U
#define LAB_VERSION_OFFSET       0x00014U
#define LAB_WAVEFORM_OFFSET      0x10000U
#define LAB_CAPTURE_OFFSET       0x20000U

#define DPD_EXPECTED_VERSION     0x44504401U
#define LAB_EXPECTED_VERSION     0x4C414202U
#define DPD_LUT_DEPTH            4096U
#define DPD_TAPS                 4U

static u32 ReadRegister(UINTPTR base, u32 offset)
{
    return Xil_In32(base + (UINTPTR)offset);
}

static void WriteRegister(UINTPTR base, u32 offset, u32 value)
{
    Xil_Out32(base + (UINTPTR)offset, value);
}

static void SkipSpaces(const char **cursor)
{
    while (**cursor == ' ' || **cursor == '\t')
        ++(*cursor);
}

static int ParseUnsigned(const char **cursor, int base, u32 *value)
{
    char *end;
    unsigned long parsed;
    SkipSpaces(cursor);
    if (**cursor == '\0')
        return 0;
    parsed = strtoul(*cursor, &end, base);
    if (end == *cursor)
        return 0;
    *cursor = end;
    *value = (u32)parsed;
    return 1;
}

static u32 DpdControl(void)
{
    return ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_CONTROL_OFFSET) & 1U;
}

static u32 LabControl(void)
{
    return ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_CONTROL_OFFSET) & 1U;
}

static void PrintDpdStatus(void)
{
    u32 control = ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_CONTROL_OFFSET);
    u32 status = ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_STATUS_OFFSET);
    xil_printf("[DPD] version=%08x enable_req=%u enable_active=%u active_bank=%u clip_beats=%u\r\n",
               ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_VERSION_OFFSET),
               control & 1U, (status >> 1) & 1U, status & 1U,
               ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_CLIP_COUNT_OFFSET));
}

static void PrintLabStatus(void)
{
    u32 status = ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_STATUS_OFFSET);
    xil_printf("[LAB] version=%08x playback=%u busy=%u done=%u play_len=%u target=%u count=%u\r\n",
               ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_VERSION_OFFSET),
               status & 1U, (status >> 1) & 1U, (status >> 2) & 1U,
               ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_PLAY_LENGTH_OFFSET),
               ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_CAPTURE_TARGET_OFFSET),
               ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_CAPTURE_COUNT_OFFSET));
}

void DpdRuntimePrintVersions(void)
{
    u32 dpdVersion = ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_VERSION_OFFSET);
    u32 labVersion = ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_VERSION_OFFSET);
    xil_printf("[DPD PL] core=%08x (%s), lab=%08x (%s)\r\n",
               dpdVersion, dpdVersion == DPD_EXPECTED_VERSION ? "OK" : "MISMATCH",
               labVersion, labVersion == LAB_EXPECTED_VERSION ? "OK" : "MISMATCH");
}

void DpdPrintHelp(void)
{
    xil_printf("  DPDS              DPD status/version/clip count\r\n");
    xil_printf("  DPDE <0|1>        disable/enable hardware MP-DPD\r\n");
    xil_printf("  DPDC              atomically commit the loaded inactive bank\r\n");
    xil_printf("  DPDX              clear the clipping counter\r\n");
    xil_printf("  DPDW <b> <t> <start> <hex...>  load LUT words\r\n");
    xil_printf("  LABS              waveform/capture status\r\n");
    xil_printf("  LABP <0|1>        select DBPSK input or waveform playback\r\n");
    xil_printf("  LABL <4..4096>    set playback length (multiple of four)\r\n");
    xil_printf("  LABW <start> <hex...>           load packed IQ waveform\r\n");
    xil_printf("  LABC <even_count> trigger a 2..4096 sample capture\r\n");
    xil_printf("  LABR <start> <count> print LABD index tx_hex feedback_hex\r\n");
}

int DpdProcessCommand(const char *command, const char *argument)
{
    const char *cursor = argument;
    u32 first, second, third, word, count;

    if (strcmp(command, "DPDS") == 0) {
        PrintDpdStatus();
    } else if (strcmp(command, "DPDE") == 0) {
        if (!ParseUnsigned(&cursor, 0, &first) || first > 1U) {
            xil_printf("[ERR] DPDE requires 0 or 1\r\n");
        } else {
            WriteRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_CONTROL_OFFSET, first);
            xil_printf("[OK] DPD enable request=%u\r\n", first);
        }
    } else if (strcmp(command, "DPDC") == 0) {
        u32 oldBank = ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_STATUS_OFFSET) & 1U;
        WriteRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_CONTROL_OFFSET, DpdControl() | 2U);
        for (count = 0U; count < 100U; ++count) {
            if ((ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_STATUS_OFFSET) & 1U) != oldBank)
                break;
            usleep(1000U);
        }
        if (count < 100U)
            xil_printf("[OK] DPD active bank=%u\r\n",
                       ReadRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_STATUS_OFFSET) & 1U);
        else
            xil_printf("[ERR] DPD bank commit timeout\r\n");
    } else if (strcmp(command, "DPDX") == 0) {
        WriteRegister((UINTPTR)DPD_BASE_ADDRESS, DPD_CONTROL_OFFSET, DpdControl() | 4U);
        xil_printf("[OK] DPD clipping counter clear requested\r\n");
    } else if (strcmp(command, "DPDW") == 0) {
        if (!ParseUnsigned(&cursor, 0, &first) ||
            !ParseUnsigned(&cursor, 0, &second) ||
            !ParseUnsigned(&cursor, 0, &third) ||
            first > 1U || second >= DPD_TAPS || third >= DPD_LUT_DEPTH) {
            xil_printf("[ERR] DPDW requires bank(0..1) tap(0..3) start(0..4095) hex words\r\n");
        } else {
            count = 0U;
            while (ParseUnsigned(&cursor, 16, &word)) {
                u32 index = third + count;
                u32 offset;
                if (index >= DPD_LUT_DEPTH)
                    break;
                offset = DPD_LUT_WINDOW_OFFSET | (first << 16) | (second << 14) | (index << 2);
                WriteRegister((UINTPTR)DPD_BASE_ADDRESS, offset, word);
                ++count;
            }
            if (count == 0U)
                xil_printf("[ERR] DPDW did not contain coefficient words\r\n");
            else
                xil_printf("[OK] DPDW bank=%u tap=%u start=%u count=%u\r\n",
                           first, second, third, count);
        }
    } else if (strcmp(command, "LABS") == 0) {
        PrintLabStatus();
    } else if (strcmp(command, "LABP") == 0) {
        if (!ParseUnsigned(&cursor, 0, &first) || first > 1U) {
            xil_printf("[ERR] LABP requires 0 or 1\r\n");
        } else {
            WriteRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_CONTROL_OFFSET, first);
            xil_printf("[OK] LAB playback request=%u\r\n", first);
        }
    } else if (strcmp(command, "LABL") == 0) {
        if (!ParseUnsigned(&cursor, 0, &first) || first < 4U || first > 4096U || (first & 3U)) {
            xil_printf("[ERR] LABL requires a multiple of four from 4 to 4096\r\n");
        } else {
            WriteRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_PLAY_LENGTH_OFFSET, first);
            xil_printf("[OK] LAB playback length=%u\r\n", first);
        }
    } else if (strcmp(command, "LABW") == 0) {
        if (!ParseUnsigned(&cursor, 0, &first) || first >= DPD_LUT_DEPTH) {
            xil_printf("[ERR] LABW requires start(0..4095) and packed IQ hex words\r\n");
        } else {
            count = 0U;
            while (ParseUnsigned(&cursor, 16, &word)) {
                if (first + count >= DPD_LUT_DEPTH)
                    break;
                WriteRegister((UINTPTR)DPD_LAB_BASE_ADDRESS,
                              LAB_WAVEFORM_OFFSET + ((first + count) << 2), word);
                ++count;
            }
            if (count == 0U)
                xil_printf("[ERR] LABW did not contain waveform words\r\n");
            else
                xil_printf("[OK] LABW start=%u count=%u\r\n", first, count);
        }
    } else if (strcmp(command, "LABC") == 0) {
        if (!ParseUnsigned(&cursor, 0, &first) || first < 2U || first > 4096U || (first & 1U)) {
            xil_printf("[ERR] LABC requires an even sample count from 2 to 4096\r\n");
        } else {
            u32 playback = LabControl();
            WriteRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_CAPTURE_TARGET_OFFSET, first);
            WriteRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_CONTROL_OFFSET, playback | 4U);
            WriteRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_CONTROL_OFFSET, playback | 2U);
            xil_printf("[OK] LAB capture triggered for %u samples\r\n", first);
        }
    } else if (strcmp(command, "LABR") == 0) {
        if (!ParseUnsigned(&cursor, 0, &first) || !ParseUnsigned(&cursor, 0, &second) ||
            first >= 4096U || second == 0U || second > 4096U || first + second > 4096U) {
            xil_printf("[ERR] LABR requires start,count within 0..4095\r\n");
        } else {
            u32 available = ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, LAB_CAPTURE_COUNT_OFFSET);
            if (first >= available) {
                xil_printf("[ERR] LABR start=%u but capture_count=%u\r\n", first, available);
            } else {
                if (first + second > available)
                    second = available - first;
                for (count = 0U; count < second; ++count) {
                    u32 index = first + count;
                    u32 offset = LAB_CAPTURE_OFFSET + (index << 3);
                    u32 tx = ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, offset);
                    u32 feedback = ReadRegister((UINTPTR)DPD_LAB_BASE_ADDRESS, offset + 4U);
                    xil_printf("LABD %u %08x %08x\r\n", index, tx, feedback);
                }
                xil_printf("LABE %u\r\n", second);
            }
        }
    } else {
        return 0;
    }
    return 1;
}

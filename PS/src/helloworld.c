/******************************************************************************
*
* Copyright (C) 2009 - 2014 Xilinx, Inc.  All rights reserved.
*
******************************************************************************/

#include "helloworld.h"
#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xrfdc_clk.h"
#include "xil_io.h"
#include "sleep.h"
#include "xrfdc.h"
#include <stdlib.h>

// ***************** 用户配置区 *****************
double Mixer_ADC_NCO_Freq;
double Mixer_DAC_NCO_Freq;

// 目标 Tile: Tile 229 对应 ID 1
#define TARGET_TILE_ID  1
// ********************************************

unsigned int LMK04208_CKin[1][26] = {
        {0x00160040,0x80140320,0x80140321,0x80140322,
        0xC0140023,0x40140024,0x80141E05,0x03300006,0x01300007,0x06010008,
        0x55555549,0x9102410A,0x0401100B,0x1B0C006C,0x2302886D,0x0200000E,
        0x8000800F,0xC1550410,0x00000058,0x02C9C419,0x8FA8001A,0x10001E1B,
        0x0021201C,0x0180033D,0x0200033E,0x003F001F }};
XRFdc RFdcInst;      /* RFdc driver instance */

// 前置声明
void rfdcStartup(u32 *cmdVals);

/******************************************************************************
* [修复版] ConfigNCOPhase 函数 (兼容 Vitis 2020.2)
* 专门用于设置指定通道 NCO 的绝对相位偏移 (单位: 度)
*******************************************************************************/
int ConfigNCOPhase(u32 Type, u32 Tile_Id, u32 Block_Id, double PhaseOffset_Deg) {
    int Status;
    XRFdc_Mixer_Settings Mixer_Settings;
    char *typeName = (Type == XRFDC_DAC_TILE) ? "DAC" : "ADC";

    xil_printf("  -> Configuring %s Tile %d, Block %d Phase Offset to %d Deg... ",
               typeName, Tile_Id, Block_Id, (int)PhaseOffset_Deg);

    // 1. 获取当前的混频器设置 (为了不覆盖现有的频率和模式)
    Status = XRFdc_GetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: GetMixerSettings, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    // 2. 修改相位偏移量
    Mixer_Settings.PhaseOffset = PhaseOffset_Deg;

    // 3. 将新的设置写回硬件
    Status = XRFdc_SetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: SetMixerSettings, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    // 4. 触发事件使相位更新立即生效 (使用 MIXER 事件触发 NCO 更新)
    Status = XRFdc_UpdateEvent(&RFdcInst, Type, Tile_Id, Block_Id, XRFDC_EVENT_MIXER);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: UpdateEvent, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    xil_printf("[OK]\r\n");
    return XST_SUCCESS;
}

/******************************************************************************
* 封装后的 ConfigNCO 函数
*******************************************************************************/
int ConfigNCO(u32 Type, u32 Tile_Id, u32 Block_Id, double Freq_MHz) {
    int Status;
    XRFdc_Mixer_Settings Mixer_Settings;
    char *typeName = (Type == XRFDC_DAC_TILE) ? "DAC" : "ADC";

    // 1. 获取对应 Converter 的采样率 (Hz)
    double SampleRate_Hz = 0;
    if (Type == XRFDC_DAC_TILE) {
        SampleRate_Hz = RFdcInst.DAC_Tile[Tile_Id].PLL_Settings.SampleRate * 1e9;
    } else {
        SampleRate_Hz = RFdcInst.ADC_Tile[Tile_Id].PLL_Settings.SampleRate * 1e9;
    }

    u32 Nyquist_Zone = 1;
    double Actual_NCO_Freq = Freq_MHz;

    // 如果目标频率大于等于 采样率/2，则处于第二奈奎斯特区
    if ((Actual_NCO_Freq * 1e6) >= (SampleRate_Hz / 2.0)) {
        Nyquist_Zone = 2;
        Actual_NCO_Freq = -Actual_NCO_Freq;
    }

    xil_printf("  -> Configuring %s Tile %d, Block %d to %d MHz (Nyquist Zone: %d)... ",
               typeName, Tile_Id, Block_Id, (int)Freq_MHz, Nyquist_Zone);

    Status = XRFdc_GetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: GetMixer, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    Status = XRFdc_SetNyquistZone(&RFdcInst, Type, Tile_Id, Block_Id, Nyquist_Zone);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: SetNyquistZone, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    Mixer_Settings.Freq = Actual_NCO_Freq;

    // [修复] 删除了 Mixer_Settings.PhaseOffset = 0;
    // 这样在改变频率时，就会保留 XRFdc_GetMixerSettings 获取到的现有校准相位

    if (Type == XRFDC_DAC_TILE) {
        Mixer_Settings.MixerMode = XRFDC_MIXER_MODE_C2R;
    } else {
        Mixer_Settings.MixerMode = XRFDC_MIXER_MODE_R2C;
    }

    Mixer_Settings.MixerType = XRFDC_MIXER_TYPE_FINE;

    Status = XRFdc_SetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: SetMixer, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    Status = XRFdc_UpdateEvent(&RFdcInst, Type, Tile_Id, Block_Id, XRFDC_EVENT_MIXER);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: UpdateEvent, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    xil_printf("[OK]\r\n");
    return XST_SUCCESS;
}


int main()
{
    int Status;
    init_platform();
    XRFdc_Config *ConfigPtr;

    print("\n\rHello RFSoC World!\n\r");

    printf("\nConfiguring Clocks...\r\n");
    LMK04208ClockConfig(1, LMK04208_CKin);
    LMX2594ClockConfig(1, 5898240);          //Set DAC/ADC clk to 5898.24 MHz
    xil_printf("  The clocks are now programmed.\r\n");

    /* Initialize the RFdc driver. */
    ConfigPtr = XRFdc_LookupConfig(RFDC_DEVICE_ID);
    if (ConfigPtr == NULL) {
        xil_printf("Failed to init RFdc driver\r\n");
        return XST_FAILURE;
    }

    Status = XRFdc_CfgInitialize(&RFdcInst, ConfigPtr);
    if (Status != XST_SUCCESS) {
        xil_printf("Failed to init RFdc controller\r\n");
        return XST_FAILURE;
    }

    rfdcStartup(NULL);

    // ============================================================
    //  配置 DAC (发射端)
    // ============================================================
    xil_printf("\n\r--- Configuring DAC (TX) Frequency ---\r\n");
    Mixer_DAC_NCO_Freq = -1000.0;

    ConfigNCO(XRFDC_DAC_TILE, 1, 0, Mixer_DAC_NCO_Freq); // Tile 229, Block 0
    ConfigNCO(XRFDC_DAC_TILE, 1, 2, Mixer_DAC_NCO_Freq); // Tile 229, Block 2


    // ============================================================
    //  [新增] 开机静态相位校准
    // ============================================================
    xil_printf("\n\r--- Performing Static NCO Phase Calibration ---\r\n");

    // 假设通过示波器测量，你发现两路信号开机差了 73.5 度
    // 你可以在这里填入补偿值。一般把通道0作为基准(0度)，对通道2做补偿
    double static_phase_compensation = 73.5;

    ConfigNCOPhase(XRFDC_DAC_TILE, 1, 0, 0.0);                       // 基准通道设为 0
    ConfigNCOPhase(XRFDC_DAC_TILE, 1, 2, static_phase_compensation); // 补偿通道写入测量值


    // ============================================================
	//  配置 ADC (接收端)
	// ============================================================
	xil_printf("\n\r--- Configuring ADC (RX) ---\r\n");
	Mixer_ADC_NCO_Freq = 2000.0;
	ConfigNCO(XRFDC_ADC_TILE, 0, 0, Mixer_ADC_NCO_Freq);
	ConfigNCO(XRFDC_ADC_TILE, 0, 1, Mixer_ADC_NCO_Freq);

	// ============================================================
    //  交互式手动变频逻辑
    // ============================================================
    xil_printf("\n\r--- Interactive DAC Control ---\r\n");
    xil_printf("Ready to receive commands.\r\n");
    xil_printf("  Type 'F <freq>' to set frequency (e.g., F -2000)\r\n");
    xil_printf("  Type 'P <phase>' to adjust phase of Block 2 (e.g., P 90)\r\n");

    double target_val = 0.0;
    char input_buf[32];
    int buf_idx = 0;
    char c;
    char mode = 'F'; // 默认模式

    while(1) {
        xil_printf("\r\n>> Enter Cmd (F/P value): ");
        buf_idx = 0;
        mode = ' ';

        while(1) {
            c = inbyte();

            if (c == '\b' || c == 0x7F) {
                if (buf_idx > 0) {
                    outbyte('\b'); outbyte(' '); outbyte('\b');
                    buf_idx--;
                }
                continue;
            }

            outbyte(c);

            if (c == '\r' || c == '\n') {
                input_buf[buf_idx] = '\0';
                break;
            }

            if (buf_idx == 0 && (c == 'F' || c == 'f' || c == 'P' || c == 'p')) {
                mode = (c == 'f') ? 'F' : ((c == 'p') ? 'P' : c);
            }

            if (buf_idx < 31) {
                input_buf[buf_idx++] = c;
            }
        }

        if (buf_idx > 1) {
            // 解析指令后面的数值，跳过第一个字母和空格
            char *val_str = input_buf + 1;
            while(*val_str == ' ') val_str++;
            target_val = atof(val_str);

            if (mode == 'F') {
                xil_printf("\n\rUpdating Frequency to: %d MHz\r\n", (int)target_val);
                ConfigNCO(XRFDC_DAC_TILE, 1, 0, target_val);
                ConfigNCO(XRFDC_DAC_TILE, 1, 2, target_val);
            }
            else if (mode == 'P') {
                xil_printf("\n\rUpdating Phase of Block 2 to: %d Deg\r\n", (int)target_val);
                // 动态调整 Block 2 相位
                ConfigNCOPhase(XRFDC_DAC_TILE, 1, 2, target_val);
            }
        }
    }

	cleanup_platform();
	return 0;
}

// rfdcStartup 函数内容保持不变
void rfdcStartup (u32 *cmdVals) {
	int Tile_Id;
	XRFdc_IPStatus ipStatus;
	XRFdc* RFdcInstPtr = &RFdcInst;
	u32 val;

	XRFdc_GetIPStatus(RFdcInstPtr, &ipStatus);
	xil_printf("Data Converter startup up is in progress...\n\r");
	Xil_Out32(RFDC_BASE + 0x0004, 1);
	sleep(1);

	for ( Tile_Id=0; Tile_Id<=3; Tile_Id++) {
		if (ipStatus.DACTileStatus[Tile_Id].IsEnabled == 1) {
			val = XRFdc_ReadReg16(RFdcInstPtr, XRFDC_ADC_TILE_CTRL_STATS_ADDR(Tile_Id), XRFDC_ADC_DEBUG_RST_OFFSET);
			if(val & XRFDC_DBG_RST_CAL_MASK) {
				xil_printf("  Tile: %d NOT ready.\r\n", Tile_Id);
			} else {
				XRFdc_StartUp(RFdcInstPtr, 1, Tile_Id);
				usleep(200000);
			}
		}
	}

	for ( Tile_Id=0; Tile_Id<=3; Tile_Id++) {
		if (ipStatus.ADCTileStatus[Tile_Id].IsEnabled == 1) {
			val = XRFdc_ReadReg16(RFdcInstPtr, XRFDC_ADC_TILE_CTRL_STATS_ADDR(Tile_Id), XRFDC_ADC_DEBUG_RST_OFFSET);
			if(val & XRFDC_DBG_RST_CAL_MASK) {
				xil_printf("  ADC Tile%d NOT ready.\r\n", Tile_Id);
			} else {
				XRFdc_StartUp(RFdcInstPtr, 0, Tile_Id);
				usleep(200000);
			}
		}
	}

	xil_printf("\r\nThe Power-on sequence step. 0xF is complete.\r\n");

	for ( Tile_Id=0; Tile_Id<=3; Tile_Id++) {
		if (ipStatus.DACTileStatus[Tile_Id].IsEnabled == 1) {
			val = XRFdc_ReadReg16(RFdcInstPtr, XRFDC_ADC_TILE_CTRL_STATS_ADDR(Tile_Id), XRFDC_ADC_DEBUG_RST_OFFSET);
			if(val & XRFDC_DBG_RST_CAL_MASK) {
				xil_printf("  Tile: %d NOT ready.\r\n", Tile_Id);
			} else {
				xil_printf("   DAC Tile%d Power-on Sequence Step: 0x%08x\r\n",Tile_Id,
						Xil_In32(RFDC_BASE + 0x0000C + 0x04000 + Tile_Id * 0x4000));
			}
		}
	}

	for ( Tile_Id=0; Tile_Id<=3; Tile_Id++) {
		if (ipStatus.ADCTileStatus[Tile_Id].IsEnabled == 1) {
			val = XRFdc_ReadReg16(RFdcInstPtr, XRFDC_ADC_TILE_CTRL_STATS_ADDR(Tile_Id), XRFDC_ADC_DEBUG_RST_OFFSET);
			if(val & XRFDC_DBG_RST_CAL_MASK) {
				xil_printf("  ADC Tile%d NOT ready.\r\n", Tile_Id);
			} else {
				xil_printf("   ADC Tile%d Power-on Sequence Step: 0x%08x\r\n",Tile_Id,
						Xil_In32(RFDC_BASE + 0x0000C + 0x14000 + Tile_Id * 0x4000));
			}
		}
	}
	xil_printf("\n\rData Converter start up is complete!");
	return;
}

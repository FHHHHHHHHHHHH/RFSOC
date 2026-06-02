/******************************************************************************
*
* Copyright (C) 2009 - 2014 Xilinx, Inc.  All rights reserved.
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* Use of the Software is limited solely to applications:
* (a) running on a Xilinx device, or
* (b) that interact with a Xilinx device through a bus or interconnect.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
* XILINX  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
* WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
* OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*
* Except as contained in this notice, the name of the Xilinx shall not be used
* in advertising or otherwise to promote the sale, use or other dealings in
* this Software without prior written authorization from Xilinx.
*
******************************************************************************/

/*
 * helloworld.c: simple test application
 *
 * This application configures UART 16550 to baud rate 9600.
 * PS7 UART (Zynq) is not initialized by this application, since
 * bootrom/bsp configures it to baud rate 115200
 *
 * ------------------------------------------------
 * | UART TYPE   BAUD RATE                        |
 * ------------------------------------------------
 *   uartns550   9600
 *   uartlite    Configurable only in HW design
 *   ps7_uart    115200 (configured by bootrom/bsp)
 */

#include "helloworld.h"
#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xrfdc_clk.h"
#include "xil_io.h"
#include "sleep.h"
#include "xrfdc.h"
#include <stdlib.h> // 添加这个头文件用于 atof()

// ***************** 用户配置区 *****************
double Mixer_ADC_NCO_Freq;
double Mixer_DAC_NCO_Freq;
// 注意：移除了原本在这里的 ADC_FS, DAC_FS, dac_nco_nyquist 等全局变量，使其更加纯粹

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
* 封装后的 ConfigNCO 函数
* 包含：动态获取采样率 -> 计算奈奎斯特区 -> 配置 Nyquist Zone -> 更新 NCO 频率
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

    // 2. 计算奈奎斯特区并调整 NCO 频率
    u32 Nyquist_Zone = 1;
    double Actual_NCO_Freq = Freq_MHz;

    // 如果目标频率大于等于 采样率/2，则处于第二奈奎斯特区
    if ((Actual_NCO_Freq * 1e6) >= (SampleRate_Hz / 2.0)) {
        Nyquist_Zone = 2;
        Actual_NCO_Freq = -Actual_NCO_Freq; // 处于第二奈奎斯特区时，NCO频率取反
    }

    xil_printf("  -> Configuring %s Tile %d, Block %d to %d MHz (Nyquist Zone: %d)... ",
               typeName, Tile_Id, Block_Id, (int)Freq_MHz, Nyquist_Zone);

    // 3. 获取当前混频器设置 (先 Get 再 Set 是为了保留其他默认配置不变)
    Status = XRFdc_GetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: GetMixer, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    // 4. 设置奈奎斯特区
    Status = XRFdc_SetNyquistZone(&RFdcInst, Type, Tile_Id, Block_Id, Nyquist_Zone);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: SetNyquistZone, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    // 5. 修改频率及混频模式
    Mixer_Settings.Freq = Actual_NCO_Freq; // 写入计算后的实际 NCO 频率
    Mixer_Settings.PhaseOffset = 0;

    if (Type == XRFDC_DAC_TILE) {
        Mixer_Settings.MixerMode = XRFDC_MIXER_MODE_C2R; // DAC 模式
    } else {
        Mixer_Settings.MixerMode = XRFDC_MIXER_MODE_R2C; // ADC 模式
    }

    Mixer_Settings.MixerType = XRFDC_MIXER_TYPE_FINE;

    // 6. 写入混频器设置
    Status = XRFdc_SetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) {
        xil_printf("[FAILED: SetMixer, Error Code: %d]\r\n", Status);
        return XST_FAILURE;
    }

    // 7. 触发事件使更新生效
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
    //LMX2594ClockConfig(1, 1474560);         //Set DAC/ADC clk to 1474.560 MHz
    LMX2594ClockConfig(1, 5898240);          //Set DAC/ADC clk to 5898.24 MHz
    xil_printf("  The clocks are now programmed.\r\n");

    /* Initialize the RFdc driver. */
    ConfigPtr = XRFdc_LookupConfig(RFDC_DEVICE_ID);
    if (ConfigPtr == NULL) {
        xil_printf("Failed to init RFdc driver\r\n");
        return XST_FAILURE;
    } else {
        xil_printf("\r\nSilicon Revision: %d\r\n\n", ConfigPtr->SiRevision);
    }

    /* Initializes the controller */
    Status = XRFdc_CfgInitialize(&RFdcInst, ConfigPtr);
    if (Status != XST_SUCCESS) {
        xil_printf("Failed to init RFdc controller\r\n");
        return XST_FAILURE;
    } else {
        xil_printf("The RFDC controller is initialized.\r\n");
    }

    // Display the Power-on Status
    rfdcStartup(NULL);

    // ============================================================
    //  配置 DAC (发射端)
    // ============================================================
    xil_printf("\n\r--- Configuring DAC (TX) ---\r\n");
    Mixer_DAC_NCO_Freq = -1000.0; // 你可以在这里随意修改目标频率，ConfigNCO 会自动处理

    // 一键调用：自动获取采样率 -> 判断奈奎斯特区 -> 配置 NCO
    ConfigNCO(XRFDC_DAC_TILE, 1, 0, Mixer_DAC_NCO_Freq); // Tile 229, Block 0
    ConfigNCO(XRFDC_DAC_TILE, 1, 2, Mixer_DAC_NCO_Freq); // Tile 229, Block 2


    // ============================================================
	//  配置 ADC (接收端)
	// ============================================================
	xil_printf("\n\r--- Configuring ADC (RX) ---\r\n");
	Mixer_ADC_NCO_Freq = 2000.0;
	ConfigNCO(XRFDC_ADC_TILE, 0, 0, Mixer_ADC_NCO_Freq);
	ConfigNCO(XRFDC_ADC_TILE, 0, 1, Mixer_ADC_NCO_Freq);

	/// ============================================================
    //  交互式手动变频逻辑 (修复版)
    // ============================================================
    xil_printf("\n\r--- Interactive DAC Frequency Control ---\r\n");
    xil_printf("Ready to receive frequency commands via UART.\r\n");

    double target_freq = 0.0;
    char input_buf[32]; // 接收缓冲字符串
    int buf_idx = 0;
    char c;

    /* 交互式主循环 */
    while(1) {
        xil_printf("\r\n>> Enter new DAC NCO frequency in MHz: ");

        buf_idx = 0;

        // 逐个字符读取串口输入，直到按下回车
        while(1) {
            c = inbyte(); // 阻塞等待串口发来一个字符

            // 处理退格键 (Backspace)
            if (c == '\b' || c == 0x7F) {
                if (buf_idx > 0) {
                    outbyte('\b'); outbyte(' '); outbyte('\b'); // 在终端上抹掉字符
                    buf_idx--;
                }
                continue;
            }

            // 回显字符到终端，让你能看到自己输入了什么
            outbyte(c);

            // 如果按下回车键 ('\r' 或 '\n')，则结束本次输入
            if (c == '\r' || c == '\n') {
                input_buf[buf_idx] = '\0'; // 给字符串加上结束符
                break;
            }

            // 存入缓冲区 (防止溢出)
            if (buf_idx < 31) {
                input_buf[buf_idx++] = c;
            }
        }

        // 只有当用户确实输入了内容时，才进行处理
        if (buf_idx > 0) {
            // 将字符串转换为 double 双精度浮点数
            target_freq = atof(input_buf);

            xil_printf("\n\rReceived request to change to: %d MHz\r\n", (int)target_freq);

            // 更新底层硬件
            ConfigNCO(XRFDC_DAC_TILE, 1, 0, target_freq);
            ConfigNCO(XRFDC_DAC_TILE, 1, 2, target_freq);

            xil_printf(">> Frequency updated successfully! Watch the spectrum analyzer.\r\n");
        }
    }

	cleanup_platform();
	return 0;
}

//    /// ============================================================
//    //  配置 ADC (接收端)
//    // ============================================================
//    xil_printf("\n\r--- Configuring ADC (RX) ---\r\n");
//    Mixer_ADC_NCO_Freq = 2000.0;
//    ConfigNCO(XRFDC_ADC_TILE, 0, 0, Mixer_ADC_NCO_Freq);
//    ConfigNCO(XRFDC_ADC_TILE, 0, 1, Mixer_ADC_NCO_Freq);
//
//    // ============================================================
//    //  动态连续扫频逻辑 (取代原来的死循环)
//    // ============================================================
//    xil_printf("\n\r--- Starting Continuous DAC Frequency Sweep ---\r\n");
//
//    // 设置扫频参数
//    double start_freq = -1000.0;  // 起始频率 (MHz)
//    double stop_freq  = -2600.0;   // 终止频率 (MHz)
//    double step_freq  = 20.0;     // 每次步进频率 (MHz)
//    double current_freq = start_freq;
//
//    // 声明结构体用于静默更新
//    XRFdc_Mixer_Settings Mixer_Settings_B0;
//    XRFdc_Mixer_Settings Mixer_Settings_B2;
//
//    // 在进入高速循环前，先获取 Tile 1 Block 0 和 Block 2 的现有配置
//    XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, 1, 0, &Mixer_Settings_B0);
//    XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, 1, 2, &Mixer_Settings_B2);
//
//    /* 高速扫频循环 */
//    while(1) {
//        // --- 更新 Block 0 ---
//        Mixer_Settings_B0.Freq = current_freq;
//        XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, 1, 0, &Mixer_Settings_B0);
//        XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, 1, 0, XRFDC_EVENT_MIXER);
//
//        // --- 更新 Block 2 ---
//        Mixer_Settings_B2.Freq = current_freq;
//        XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, 1, 2, &Mixer_Settings_B2);
//        XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, 1, 2, XRFDC_EVENT_MIXER);
//
//        // --- 计算下一个频点 ---
//        current_freq -= step_freq;
//        if (current_freq < stop_freq) {
//            current_freq = start_freq;
//            // 每扫完一轮，在串口打印一次提示，作为保活心跳
//            xil_printf("Sweep restarted from %d MHz\r\n", (int)start_freq);
//        }
//
//        // --- 延时控制 ---
//        // 延时 50000 微秒 (50 毫秒)。配合频谱仪的 Sweep Time 可以看到平滑移动的峰值
//        usleep(500000);
//    }
//
//    cleanup_platform();
//    return 0;
//}


/*****************************************************************************/
/**
*
* Startup DAC's and ADC's
*
* @param	None
*
* @return	None
*
* @note		TBD
*
******************************************************************************/
void rfdcStartup (u32 *cmdVals) {

	int Tile_Id;
	XRFdc_IPStatus ipStatus;
	XRFdc* RFdcInstPtr = &RFdcInst;
	u32 val;

	// Calling this function gets the status of the IP
	XRFdc_GetIPStatus(RFdcInstPtr, &ipStatus);

//	xil_printf("\r\n###############################################\r\n");
	xil_printf("Data Converter startup up is in progress...\n\r");

	// Master Reset
	Xil_Out32(RFDC_BASE + 0x0004, 1);

//	xil_printf("RF Data Converters Powered up.\r\n");
	sleep(1);

	// startup
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
//	xil_printf("\r\n###############################################\r\n");

	return;
}









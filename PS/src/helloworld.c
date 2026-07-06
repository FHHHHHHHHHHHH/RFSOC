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
#include "xllfifo.h"
XLlFifo FifoInstance;

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
int ConfigNCOPhase(u32 Type, u32 Tile_Id, u32 Block_Id, double PhaseOffset_Deg);
int ConfigNCO(u32 Type, u32 Tile_Id, u32 Block_Id, double Freq_MHz);

/******************************************************************************
* ConfigNCOPhase 函数 (保持保留，可供独立调用)
*******************************************************************************/
int ConfigNCOPhase(u32 Type, u32 Tile_Id, u32 Block_Id, double PhaseOffset_Deg) {
    int Status;
    XRFdc_Mixer_Settings Mixer_Settings;
    char *typeName = (Type == XRFDC_DAC_TILE) ? "DAC" : "ADC";

    xil_printf("  -> Configuring %s Tile %d, Block %d Phase Offset to %d Deg... ",
               typeName, Tile_Id, Block_Id, (int)PhaseOffset_Deg);

    Status = XRFdc_GetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    Mixer_Settings.PhaseOffset = PhaseOffset_Deg;
    Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE; // 默认采用同Tile同步事件

    Status = XRFdc_SetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    Status = XRFdc_UpdateEvent(&RFdcInst, Type, Tile_Id, Block_Id, XRFDC_EVENT_MIXER);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    xil_printf("[OK]\r\n");
    return XST_SUCCESS;
}

/******************************************************************************
* ConfigNCO 函数 (保持保留，可供单通道独立调频)
*******************************************************************************/
int ConfigNCO(u32 Type, u32 Tile_Id, u32 Block_Id, double Freq_MHz) {
    int Status;
    XRFdc_Mixer_Settings Mixer_Settings;
    char *typeName = (Type == XRFDC_DAC_TILE) ? "DAC" : "ADC";

    double SampleRate_Hz = 0;
    if (Type == XRFDC_DAC_TILE) {
        SampleRate_Hz = RFdcInst.DAC_Tile[Tile_Id].PLL_Settings.SampleRate * 1e9;
    } else {
        SampleRate_Hz = RFdcInst.ADC_Tile[Tile_Id].PLL_Settings.SampleRate * 1e9;
    }

    u32 Nyquist_Zone = 1;
    double Actual_NCO_Freq = Freq_MHz;

    if ((Actual_NCO_Freq * 1e6) >= (SampleRate_Hz / 2.0)) {
        Nyquist_Zone = 2;
        Actual_NCO_Freq = -Actual_NCO_Freq;
    }

    xil_printf("  -> Configuring %s Tile %d, Block %d to %d MHz... ", typeName, Tile_Id, Block_Id, (int)Freq_MHz);

    Status = XRFdc_GetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    Status = XRFdc_SetNyquistZone(&RFdcInst, Type, Tile_Id, Block_Id, Nyquist_Zone);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    Mixer_Settings.Freq = Actual_NCO_Freq;
    Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE; // 默认采用同Tile同步事件

    if (Type == XRFDC_DAC_TILE) {
        Mixer_Settings.MixerMode = XRFDC_MIXER_MODE_C2R;
    } else {
        Mixer_Settings.MixerMode = XRFDC_MIXER_MODE_R2C;
    }
    Mixer_Settings.MixerType = XRFDC_MIXER_TYPE_FINE;

    Status = XRFdc_SetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    Status = XRFdc_UpdateEvent(&RFdcInst, Type, Tile_Id, Block_Id, XRFDC_EVENT_MIXER);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    xil_printf("[OK]\r\n");
    return XST_SUCCESS;
}



int main()
{
    int Status;
    init_platform();
    XRFdc_Config *ConfigPtr;
    XRFdc_Mixer_Settings Mixer_Settings;

    print("\n\rHello RFSoC World (Direct RF Mode)!\n\r");

    printf("\nConfiguring Clocks...\r\n");
    LMK04208ClockConfig(1, LMK04208_CKin);
    LMX2594ClockConfig(1, 5898240);          // 设定 DAC/ADC 采样率时钟
    xil_printf("  The clocks are now programmed.\r\n");


    /* 0629 初始化 AXI4-Stream FIFO */
	XLlFifo_Config *FifoConfig;
	// 这里的宏定义名称可能因你的 BD 命名而异，通常是 XPAR_AXI_FIFO_0_DEVICE_ID
	FifoConfig = XLlFfio_LookupConfig(XPAR_AXI_FIFO_0_DEVICE_ID);
	if (!FifoConfig) {
		xil_printf("No FIFO config found.\r\n");
		return XST_FAILURE;
	}
	Status = XLlFifo_CfgInitialize(&FifoInstance, FifoConfig, FifoConfig->BaseAddress);
	if (Status != XST_SUCCESS) {
		xil_printf("FIFO Initialization failed\n\r");
		return XST_FAILURE;
	}

    /* 初始化 RFdc 驱动 */
    ConfigPtr = XRFdc_LookupConfig(RFDC_DEVICE_ID);
    if (ConfigPtr == NULL) { return XST_FAILURE; }

    Status = XRFdc_CfgInitialize(&RFdcInst, ConfigPtr);
    if (Status != XST_SUCCESS) { return XST_FAILURE; }

    rfdcStartup(NULL);

    // ============================================================
	// 动作 1：开机全自动【同Tile同步】初始化两路 DAC 到 2400 MHz (2.4GHz)
	// ============================================================
	xil_printf("\n\r--- Synchronous DAC (TX) Initialization (2.4GHz) ---\r\n");
	Mixer_DAC_NCO_Freq = 2400.0; // 直接设定射频直采发射目标为 2400MHz

	// 动态计算奈奎斯特区与实际 NCO 频率（2.4GHz 此时处于第一区）
	double SampleRate_Hz = RFdcInst.DAC_Tile[TARGET_TILE_ID].PLL_Settings.SampleRate * 1e9;
	u32 Nyquist_Zone = 1;
	double Actual_NCO_Freq = Mixer_DAC_NCO_Freq;
	if ((Actual_NCO_Freq * 1e6) >= (SampleRate_Hz / 2.0)) {
		Nyquist_Zone = 2;
		Actual_NCO_Freq = -Actual_NCO_Freq; // 偶数区需反转频率
	}

	// 1. 静默配置 Block 0 (DAC0)
	XRFdc_SetNyquistZone(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 0, Nyquist_Zone);
	XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 0, &Mixer_Settings);
	Mixer_Settings.Freq = Actual_NCO_Freq;
	Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE; // 锁定 Tile 级触发源
	XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 0, &Mixer_Settings);

	// 2. 静默配置 Block 1 (DAC1) 并直接赋予开机基础对齐相位
	XRFdc_SetNyquistZone(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 1, Nyquist_Zone);
	XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 1, &Mixer_Settings);
	Mixer_Settings.Freq = Actual_NCO_Freq;
	Mixer_Settings.PhaseOffset = 0.0;                 // 初始相位差为 0
	Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE; // 锁定 Tile 级触发源
	XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 1, &Mixer_Settings);

	// 3. 统一触发：让 Block 0 和 Block 1 在同一个射频时钟沿无缝同步起振
	XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 0, XRFDC_EVENT_MIXER);
	xil_printf("  -> Both DAC0 and DAC1 successfully initialized to 2.4GHz synchronously!\r\n");

    // ============================================================
	//  配置 ADC (接收端保持不变)
	// ============================================================
	xil_printf("\n\r--- Configuring ADC (RX) ---\r\n");
	Mixer_ADC_NCO_Freq = 2000.0;
	ConfigNCO(XRFDC_ADC_TILE, 0, 0, Mixer_ADC_NCO_Freq);
	ConfigNCO(XRFDC_ADC_TILE, 0, 1, Mixer_ADC_NCO_Freq);


	// ============================================================
    //  交互式手动【频/相联动同步控制】逻辑
    // ============================================================
    xil_printf("\n\r--- Synchronized Interactive DAC Control ---\r\n");
    xil_printf("Ready to receive commands.\r\n");
    xil_printf("  Type 'F <freq>' to change both carriers seamlessly (e.g., F 2450)\r\n");
    xil_printf("  Type 'P <phase>' to shift Block 2 relative to Block 0 (e.g., P 90)\r\n");


    // ==========================================================
	// 串口交互终端主循环 (应该放在 main 函数末尾的无限循环中)
	// ==========================================================
    while (1) {

        char input_buf[32] = {0};
        int buf_idx = 0;
        char c;

        xil_printf("\r\n>> Enter Cmd (F/P/T value): ");

        // =========================
        // 1. 接收输入
        // =========================
        while (1) {
            c = inbyte();

            if (c == '\r' || c == '\n') {
                break;
            }

            if (c == '\b' || c == 0x7F) {
                if (buf_idx > 0) {
                    buf_idx--;
                    xil_printf("\b \b");
                }
                continue;
            }

            if (buf_idx < sizeof(input_buf) - 1) {
                input_buf[buf_idx++] = c;
                outbyte(c);
            }
        }

        input_buf[buf_idx] = '\0';

        // =========================
        // 2. 跳过前导空格
        // =========================
        int i = 0;
        while (input_buf[i] == ' ' && input_buf[i] != '\0') {
            i++;
        }

        if (input_buf[i] == '\0') {
            continue;
        }

        // =========================
        // 3. 解析命令
        // =========================
        char mode = input_buf[i];

        if (mode >= 'a' && mode <= 'z') {
            mode -= 32;
        }

        char *msg_str = input_buf + i + 1;

        while (*msg_str == ' ') {
            msg_str++;
        }

        double target_val = 0.0;

        if (strlen(msg_str) > 0) {
            target_val = atof(msg_str);
        }

        // =========================
        // 4. 执行命令
        // =========================

        if (mode == 'F') {
        	xil_printf("\r\n[CMD] Freq = %s MHz\r\n", msg_str);

            XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 0, &Mixer_Settings);
            Mixer_Settings.Freq = target_val;
            Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE;
            XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 0, &Mixer_Settings);

            XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 1, &Mixer_Settings);
            Mixer_Settings.Freq = target_val;
            Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE;
            XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 1, &Mixer_Settings);

            XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 0, XRFDC_EVENT_MIXER);

            xil_printf("[OK] Frequency updated\r\n");
        }

        else if (mode == 'P') {

            xil_printf("\r\n[CMD] Phase = %s deg\r\n", msg_str);

            XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 1, &Mixer_Settings);
            Mixer_Settings.PhaseOffset = target_val;
            Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE;
            XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 1, &Mixer_Settings);

            XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, TARGET_TILE_ID, 0, XRFDC_EVENT_MIXER);

            xil_printf("[OK] Phase updated\r\n");
        }

        else if (mode == 'T') {

            int len = strlen(msg_str);

            if (len <= 0) {
                xil_printf("\r\n[ERR] T missing payload\r\n");
                continue;
            }

            if (XLlFifo_TxVacancy(&FifoInstance) >= len) {
                XLlFifo_Write(&FifoInstance, msg_str, len);
                XLlFifo_TxSetLen(&FifoInstance, len);

                xil_printf("\r\n[OK] TX %d bytes: %s\r\n", len, msg_str);
            } else {
                xil_printf("\r\n[ERR] FIFO full\r\n");
            }
        }

        // 在 if (mode == 'T') 的同级，加上这段代码
		else if (mode == 'C') {
			int len = strlen(msg_str);
			if (len > 0) {
				xil_printf("\r\n[System] WARNING: Entering CONTINUOUS TX MODE!\r\n");
				xil_printf("[System] Sending %d bytes FOREVER. Reboot board to stop.\r\n", len);

				// 死循环：疯狂往 FIFO 灌入基带数据
				while(1) {
					if (XLlFifo_TxVacancy(&FifoInstance) > 0) {
						XLlFifo_Write(&FifoInstance, msg_str, len);
						XLlFifo_TxSetLen(&FifoInstance, len);
						usleep(10); // 微小延时，防止 ARM 彻底卡死
					}
				}
			}
		}

        else {
            xil_printf("\r\n[ERR] Unknown cmd: %c\r\n", mode);
            xil_printf("      Use F <freq>, P <phase>, T <data>\r\n");
        }
    }

	cleanup_platform();
	return 0;
}

/******************************************************************************
* rfdcStartup 底层启动函数 (保持原样不动)
*******************************************************************************/
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

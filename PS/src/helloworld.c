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

// DAC 目标 Tile: Tile 229 对应 ID 1
#define DAC_TARGET_TILE_ID  1
#define DAC_TARGET_BLOCK_ID_0  0
#define DAC_TARGET_BLOCK_ID_1  1
// ADC 目标Tile: Tile
#define ADC_TARGET_TILE_ID 0
#define ADC_TARGET_BLOCK_ID_0  0
#define ADC_TARGET_BLOCK_ID_1  1
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
int ConfigNCO(u32 Type, u32 Tile_Id, u32 Block_Id, double Freq_MHz);


/******************************************************************************
* ConfigNCO 函数 (保持保留，可供单通道独立调频)
// Type: XRFDC_DAC_TILE 或 XRFDC_ADC_TILE
// Tile_Id: 目标 Tile ID
// Block_Id: 目标 Block ID
// Freq_MHz: 目标 NCO 频率 (MHz)
*******************************************************************************/
int ConfigNCO(u32 Type, u32 Tile_Id, u32 Block_Id, double Freq_MHz) {
    int Status;
    XRFdc_Mixer_Settings Mixer_Settings;
    char *typeName = (Type == XRFDC_DAC_TILE) ? "DAC" : "ADC";

    // 计算采样率和奈奎斯特区
    //【修复1：单位错误】RFDC 驱动中的 SampleRate 单位本身就是 MHz！
    double SampleRate_GHz = 0;
    if (Type == XRFDC_DAC_TILE) {
        SampleRate_GHz = RFdcInst.DAC_Tile[Tile_Id].PLL_Settings.SampleRate;
    } else {
        SampleRate_GHz = RFdcInst.ADC_Tile[Tile_Id].PLL_Settings.SampleRate;
    }
    // SampleRate_GHz = 5.898240 GHz
    double SampleRate_kHz = SampleRate_GHz * 1000000; // 转换为 kHz

    xil_printf("[System] Sample Rate of %s Tile %d is %d kHz\r\n", typeName, Tile_Id, (int)SampleRate_kHz);

    u32 Nyquist_Zone = 1;
    double Actual_NCO_Freq = Freq_MHz;

    // 检查是否需要切换奈奎斯特区, 并调整实际 NCO 频率
     // 自动判定奈奎斯特区 (Fs/2)，全在 MHz 级别下比较
    if ((Actual_NCO_Freq*1000) >= (SampleRate_kHz / 2.0)) {
        Nyquist_Zone = 2;
        // // 第二区会自动发生频谱翻转(倒谱)，将 NCO 设为负频率可以完美补偿此翻转
        Actual_NCO_Freq = -Actual_NCO_Freq;
    }

    xil_printf("\n\r[System] Configuring %s Tile %d, Block %d to %d MHz (Actual NCO: %d MHz, Nyquist Zone: %d)\r\n",
               typeName, Tile_Id, Block_Id, (int)Freq_MHz, (int)Actual_NCO_Freq, Nyquist_Zone);

    // 获取当前混频器设置
    Status = XRFdc_GetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    // 设置奈奎斯特区
    Status = XRFdc_SetNyquistZone(&RFdcInst, Type, Tile_Id, Block_Id, Nyquist_Zone);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    Mixer_Settings.Freq = Actual_NCO_Freq;
    Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE; // 挂起，等待 Tile 级事件统一触发

    // 设置混频器模式和类型
    if (Type == XRFDC_DAC_TILE) {
        Mixer_Settings.MixerMode = XRFDC_MIXER_MODE_C2R; // DAC 采用 C2R 模式
    } else {
        Mixer_Settings.MixerMode = XRFDC_MIXER_MODE_R2C; // ADC 采用 R2C 模式
    }
    Mixer_Settings.MixerType = XRFDC_MIXER_TYPE_FINE; // 采用精细混频器

    // 应用混频器设置
    Status = XRFdc_SetMixerSettings(&RFdcInst, Type, Tile_Id, Block_Id, &Mixer_Settings);
    if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

    // 【修复2：移除 UpdateEvent】
    // 严禁在此处更新！必须在外部等多个 Block 都 Config 完毕后统一 Update，否则多通道相位将无法对齐！
    //Status = XRFdc_UpdateEvent(&RFdcInst, Type, Tile_Id, Block_Id, XRFDC_EVENT_MIXER);
    //if (Status != XST_SUCCESS) { xil_printf("[FAILED]\r\n"); return XST_FAILURE; }

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
    //  交互式手动【频/相联动同步控制】逻辑
    // ============================================================
    xil_printf("\n\r--- Synchronized Interactive DAC Control ---\r\n");
    xil_printf("Ready to receive commands.\r\n");
    xil_printf("  Type 'DACF <freq>' to set DAC NCO frequency (e.g., DACF 100)\r\n");
    xil_printf("  Type 'ADCF <freq>' to set ADC NCO frequency (e.g., ADCF 100)\r\n");
    xil_printf("  Type 'AMPL <scale>' to adjust DAC output amplitude (0.0 to 1.0)\r\n");
    xil_printf("  Type 'PASE <phase>' to set DAC Block 1 phase offset (degrees)\r\n");
    xil_printf("  Type 'TRAS <data>' to transmit data via FIFO (e.g., TRAS 010101)\r\n");
    xil_printf("  Type 'COST <data>' to continuously transmit data via FIFO (e.g., COST 010101)\r\n");

    // ==========================================================
	// 串口交互终端主循环 (应该放在 main 函数末尾的无限循环中)
	// ==========================================================
    while (1) {
        char input_buf[32] = {0};
        int buf_idx = 0;
        char c;
        xil_printf("\r\n>> Enter Cmd (DACF/ADCF/PASE/TRAS/COST value): ");
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
		// 3. 解析命令与参数 (修复核心)
		// =========================
		char *cmd_start = &input_buf[i];

		// 将整个输入统一转换为大写，这样输入 "pase 90" 也能正常识别
		for (int j = 0; cmd_start[j] != '\0'; j++) {
			if (cmd_start[j] >= 'a' && cmd_start[j] <= 'z') {
				cmd_start[j] -= 32;
			}
		}

		// 统一提取参数：因为现在所有命令统一是 4 个字母，直接偏移 4 个字节即可
		char *msg_str = "";
		double target_val = 0.0;

		if (strlen(cmd_start) > 4) {
			msg_str = cmd_start + 4;
			// 跳过命令和数值之间的空格
			while (*msg_str == ' ') {
				msg_str++;
			}
			// 将参数字符串转为浮点数备用
			if (strlen(msg_str) > 0) {
				target_val = atof(msg_str);
			}
		}


        // =========================
        // 4. 执行命令
        // =========================
        // DACF 模式：同时调整 DAC Block 0 和 Block 1 的 NCO 频率
        if (strncmp(cmd_start, "DACF", 4) == 0) {
            // 指针跳过 "DACF" 4个字符，指向数值部分
            msg_str = cmd_start + 4;
            // 跳过命令和数值之间的空格
            while (*msg_str == ' ') {
                msg_str++;
            }
            if (strlen(msg_str) > 0) {
                target_val = atof(msg_str);
            }
            xil_printf("\r\n[CMD] DAC Freq = %s MHz\r\n", msg_str);
            // ==========================================
            // 1. 配置并更新 DAC (发射端) NCO
            // ==========================================
            ConfigNCO(XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 0, target_val);
            ConfigNCO(XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 1, target_val);
            // 统一发出事件脉冲，触发同一 Tile 下的两个 Mixer 严格在同时更新！
            XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 0, XRFDC_EVENT_MIXER);
            XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 1, XRFDC_EVENT_MIXER);
            xil_printf("[OK] DAC Frequency updated to %d MHz!\r\n", (int)target_val);
        }
        // ADCF 模式：同时调整 ADC Block 0 和 Block 1 的 NCO 频率
        else if (strncmp(cmd_start, "ADCF", 4) == 0) {
            // 指针跳过 "ADCF" 4个字符，指向数值部分
            msg_str = cmd_start + 4;

            // 跳过命令和数值之间的空格
            while (*msg_str == ' ') {
                msg_str++;
            }

            if (strlen(msg_str) > 0) {
                target_val = atof(msg_str);
            }

            xil_printf("\r\n[CMD] ADC Freq = %s MHz\r\n", msg_str);

            // ==========================================
            // 2. 同步配置并更新 ADC (接收端) NCO
            // ==========================================
            ConfigNCO(XRFDC_ADC_TILE, ADC_TARGET_TILE_ID, 0, target_val);
            ConfigNCO(XRFDC_ADC_TILE, ADC_TARGET_TILE_ID, 1, target_val);

            XRFdc_UpdateEvent(&RFdcInst, XRFDC_ADC_TILE, ADC_TARGET_TILE_ID, 0, XRFDC_EVENT_MIXER);
            XRFdc_UpdateEvent(&RFdcInst, XRFDC_ADC_TILE, ADC_TARGET_TILE_ID, 1, XRFDC_EVENT_MIXER);

            xil_printf("[OK] ADC Frequency updated to %d MHz!\r\n", (int)target_val);
        }
        // AMPL 模式：调整 DAC 输出幅度，范围 0.0 到 1.0
        else if (strncmp(cmd_start, "AMPL", 4) == 0) {
			// target_val 输入范围：0.0 (完全静音) 到 1.0 (100% 满幅度)
			if(target_val < 0.0) target_val = 0.0;
			if(target_val > 1.0) target_val = 1.0;
			xil_printf("\r\n[CMD] Adjusting DAC Output Amplitude to: %s (Scale Factor)\r\n", msg_str);

			XRFdc_QMC_Settings QMC_Settings;

			// 配置通道 0
			XRFdc_GetQMCSettings(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 0, &QMC_Settings);
			QMC_Settings.EnableGain = 1;
			QMC_Settings.GainCorrectionFactor = target_val;
			QMC_Settings.EventSource = XRFDC_EVNT_SRC_TILE;
			XRFdc_SetQMCSettings(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 0, &QMC_Settings);

			// 配置通道 1
			XRFdc_GetQMCSettings(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 1, &QMC_Settings);
			QMC_Settings.EnableGain = 1;
			QMC_Settings.GainCorrectionFactor = target_val;
			QMC_Settings.EventSource = XRFDC_EVNT_SRC_TILE;
			XRFdc_SetQMCSettings(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 1, &QMC_Settings);

			// 统一触发配置生效
			XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 0, XRFDC_EVENT_QMC);
			XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, 1, XRFDC_EVENT_QMC);

			xil_printf("[OK] Output Amplitude updated to %.2f x Full Scale!\r\n", target_val);
		}
        // P 模式：相位调整模式，调整 DAC Block 1 相对于 Block 0 的相位差
        else if (strncmp(cmd_start, "PASE", 4) == 0) {
                xil_printf("\r\n[CMD] Phase = %s deg\r\n", msg_str);
                XRFdc_GetMixerSettings(&RFdcInst, DAC_TARGET_TILE_ID, DAC_TARGET_BLOCK_ID_1, 1, &Mixer_Settings);
                Mixer_Settings.PhaseOffset = target_val;
                Mixer_Settings.EventSource = XRFDC_EVNT_SRC_TILE;

                // 【已修复参数错位 Bug】：补充了缺失的 XRFDC_DAC_TILE 参数
				XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, DAC_TARGET_BLOCK_ID_1, &Mixer_Settings);
				// 【已修复参数错位 Bug】
				XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, DAC_TARGET_TILE_ID, DAC_TARGET_BLOCK_ID_1, XRFDC_EVENT_MIXER);
                xil_printf("[OK] Phase updated\r\n");
        }
        // T 模式：发送数据模式，将输入的二进制字符串通过 FIFO 发送出去
        else if (strncmp(cmd_start, "TRAS", 4) == 0) {
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
        // C 模式：连续发送模式，死循环往 FIFO 灌入数据
		else if (strncmp(cmd_start, "COST", 4) == 0) {
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
        // 未知命令处理
        else {
            xil_printf("\r\n[ERR] Unknown cmd: %c\r\n", cmd_start);
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

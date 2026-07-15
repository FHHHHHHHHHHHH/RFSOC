import sys
import os
# 移除可能来自 Vivado/Xilinx 的 Python 标准库路径，避免与本地 Python 版本冲突
sys.path = [p for p in sys.path if p is None or ("Vivado" not in p and "Xilinx" not in p and "python-3.8" not in p)]

import numpy as np

# 系统参数
Fs = 184.32e6  # 采样率 (184.32 MHz)
Rs = 10.0e6     # 符号率 (10 Mbps)
alpha = 0.8   # 滚降系数 (Roll-off factor)
span = 4       # 符号跨度 (取4个符号长度，保证成型效果且节省FPGA资源)

sps = int(Fs / Rs)
t = np.arange(-span*sps//2, span*sps//2 + 1) / Fs

# 计算 RRC 冲激响应
h = np.zeros(len(t))
for i, tc in enumerate(t):
    if tc == 0.0:
        h[i] = 1.0 - alpha + (4 * alpha / np.pi)
    elif alpha != 0 and np.isclose(np.abs(tc), 1 / (4 * alpha * Rs)):
        h[i] = (alpha / np.sqrt(2)) * (((1 + 2 / np.pi) * np.sin(np.pi / (4 * alpha))) + ((1 - 2 / np.pi) * np.cos(np.pi / (4 * alpha))))
    else:
        num = np.sin(np.pi * tc * Rs * (1 - alpha)) + 4 * alpha * tc * Rs * np.cos(np.pi * tc * Rs * (1 + alpha))
        den = np.pi * tc * Rs * (1 - (4 * alpha * tc * Rs)**2)
        h[i] = num / den

# 归一化并量化为 16-bit 有符号定点数 (供 FPGA 使用)
h = h / np.max(np.abs(h))
h_quant = np.round(h * 32767).astype(int)

# 写入 Xilinx COE 文件
with open("rrc_filter_10Mbps_alpha08.coe", "w") as f:
    f.write("radix=10;\n")
    f.write("coefdata=\n")
    f.write(",\n".join(map(str, h_quant)))
    f.write(";\n")
print(f"成功生成 rrc_filter_10Mbps_alpha08.coe，包含 {len(h_quant)} 个抽头 (Taps)。")


# 绘制冲激响应和频率响应


import matplotlib
matplotlib.use('Agg')   # 使用 Agg 后端（不依赖 GUI）
import matplotlib.pyplot as plt

plt.figure(figsize=(12, 5))

plt.subplot(1, 2, 1)
plt.plot(t * 1e6, h)
plt.xlabel("Time (μs)")
plt.ylabel("Amplitude")
plt.title("RRC Impulse Response")
plt.grid(True)

plt.subplot(1, 2, 2)
f = np.linspace(-Fs/2, Fs/2, len(h))
H = np.fft.fftshift(np.fft.fft(h))
plt.plot(f / 1e6, np.abs(H))
plt.xlabel("Frequency (MHz)")
plt.ylabel("Magnitude")
plt.title("RRC Frequency Response")
plt.grid(True)

plt.tight_layout()
plt.savefig("rrc_filter_response.png")
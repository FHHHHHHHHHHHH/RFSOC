
"""
以下 Python 脚本会生成 4096 个样本（完美契合您 LAB 模块的 BRAM 深度），模拟 PA 的失真，
并将数据量化为 16-bit 有符号整数保存，方便您的 C 语言代码直接读取。

运行上述脚本后，您会得到两个文件：
tx_reference.csv (您发送给 PA 的理想数据) 
rx_distorted.csv (被 PA 扭曲后 ADC 采样回来的数据)。
 同时，图表会显示出明显的增益压缩曲线和记忆效应带来的“散布现象”（Scatter Cloud）。
输入 DPD 算法：您可以直接将这 4096 对数据送入您在 PS 端 (ARM) 或者 PC 端编写的最小二乘法 (LS) 系数提取算法中。
计算预期：您的 DPD 算法计算出的预失真系数，其非线性特征应该恰好与上述图表展现的曲线相反（即预留出膨胀量来抵消压缩量）。

"""




import numpy as np
import matplotlib.pyplot as plt
from scipy.signal import firwin, lfilter

def export_c_header(filename, x_I, x_Q, y_I, y_Q):
    N = len(x_I)
    with open(filename, 'w') as f:
        f.write("#ifndef PA_SIM_DATA_H\n")
        f.write("#define PA_SIM_DATA_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write(f"#define DPD_SAMPLE_SIZE {N}\n\n")
        
        # 辅助写入数组的内部函数
        def write_array(name, data):
            f.write(f"const int16_t {name}[DPD_SAMPLE_SIZE] = {{\n")
            # 每行打印 8 个数据，方便阅读
            for i in range(0, N, 8):
                chunk = data[i:i+8]
                line_str = ", ".join(f"{val:>6}" for val in chunk)
                f.write(f"    {line_str},\n")
            f.write("};\n\n")
            
        write_array("tx_ref_i", x_I)
        write_array("tx_ref_q", x_Q)
        write_array("rx_distorted_i", y_I)
        write_array("rx_distorted_q", y_Q)
        
        f.write("#endif // PA_SIM_DATA_H\n")
    print(f"头文件已生成：{filename}")

def generate_pa_data():
    # 1. 基础参数设置
    N = 4096  # 样本数，契合硬件 LAB 模块的深度
    np.random.seed(42)

    # 2. 生成带限测试信号 (模拟通信基带信号)
    # 产生随机复高斯白噪声并通过低通滤波器，使其具有一定的带宽
    raw_syms = np.random.randn(N) + 1j * np.random.randn(N)
    taps = firwin(31, cutoff=0.25)
    x = lfilter(taps, 1.0, raw_syms)
    
    # 归一化输入信号幅值，留出一定的余量(0.8)以防 PA 输出溢出
    x = x / np.max(np.abs(x)) * 0.8 

    # 3. 模拟 PA 的记忆多项式 (Memory Polynomial) 模型
    y = np.zeros_like(x, dtype=complex)
    
    # 设定一些模拟的 PA 系数 (包含线性和非线性、无记忆和有记忆项)
    # 记忆深度 m=0 (当前时刻)
    c01 = 1.05 + 0.01j   # 线性主项
    c03 = -0.15 + 0.10j  # 3阶非线性 (导致压缩和相位扭转)
    c05 = 0.05 - 0.02j   # 5阶非线性
    
    # 记忆深度 m=1 (上一时刻，模拟记忆效应)
    c11 = 0.10 + 0.02j
    c13 = -0.05 + 0.01j

    for n in range(1, N):
        # 当前样本多项式
        term0 = c01*x[n] + c03*x[n]*np.abs(x[n])**2 + c05*x[n]*np.abs(x[n])**4
        # 历史样本多项式 (记忆效应)
        term1 = c11*x[n-1] + c13*x[n-1]*np.abs(x[n-1])**2
        y[n] = term0 + term1

    # 加入轻微的高斯白噪声 (AWGN) 增加真实感，信噪比约 40dB
    noise_power = np.mean(np.abs(y)**2) / (10**(40/10))
    noise = np.sqrt(noise_power/2) * (np.random.randn(N) + 1j*np.random.randn(N))
    y = y + noise

    # 4. 量化为 16-bit 有符号整数 (适配 PL 端逻辑)
    # 以 x 和 y 中的最大值为基准进行缩放，映射到 [-32767, 32767]
    max_val = max(np.max(np.abs(x)), np.max(np.abs(y)))
    scale_factor = 32767.0 / max_val * 0.95 # 0.95 防止取整溢出
    
    x_int = np.round(x * scale_factor)
    y_int = np.round(y * scale_factor)

    x_I, x_Q = x_int.real.astype(np.int16), x_int.imag.astype(np.int16)
    y_I, y_Q = y_int.real.astype(np.int16), y_int.imag.astype(np.int16)

    # 5. 保存为文本文件 (供 C 语言或 MATLAB 进一步处理)
    # 格式: I_val, Q_val
    np.savetxt("tx_reference.csv", np.column_stack((x_I, x_Q)), fmt="%d,%d", header="I,Q", comments='')
    np.savetxt("rx_distorted.csv", np.column_stack((y_I, y_Q)), fmt="%d,%d", header="I,Q", comments='')
    
    print("数据生成完毕：已保存为 tx_reference.csv 和 rx_distorted.csv")

    # 6. 可视化 AM-AM 和 AM-PM 特性
    plt.figure(figsize=(10, 4))
    
    # AM-AM (幅度到幅度)
    plt.subplot(1, 2, 1)
    plt.scatter(np.abs(x), np.abs(y), s=1, alpha=0.5)
    plt.title("AM-AM Characteristic")
    plt.xlabel("|x(n)| (Input Amplitude)")
    plt.ylabel("|y(n)| (Output Amplitude)")
    plt.grid(True)

    # AM-PM (幅度到相位)
    plt.subplot(1, 2, 2)
    phase_diff = np.angle(y * np.conj(x)) # 计算相位差
    plt.scatter(np.abs(x), np.degrees(phase_diff), s=1, alpha=0.5)
    plt.title("AM-PM Characteristic")
    plt.xlabel("|x(n)| (Input Amplitude)")
    plt.ylabel("Phase Shift (Degrees)")
    plt.grid(True)
    
    plt.tight_layout()
    plt.show()
    plt.savefig("pa_characteristics.png", dpi=300)

    # 7. 导出为 C 语言头文件，方便在 PL 端或 ARM 端直接使用
    export_c_header("pa_sim_data.h", x_I, x_Q, y_I, y_Q)

if __name__ == "__main__":
    generate_pa_data()
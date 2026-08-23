# RFSoC DPD 项目 PetaLinux 移植框架与执行步骤指南

## 一、 系统框架总结

在 ZCU111 等 RFSoC 平台上实现数字预失真 (DPD) 系统，标准架构分为可编程逻辑 (PL) 和处理系统 (PS) 两部分。将其从裸机 (Bare-metal) 迁移至 PetaLinux 环境，框架调整如下：

### 1. Programmable Logic (PL) 端
*   **核心任务**：负责高速数据路径，利用 RF-ADC 和 RF-DAC 进行直接射频采样。
*   **DPD 引擎**：由于严苛的实时性要求，DPD 算法的底层高频计算（如非线性校正）仍部署在 PL 端硬件中。
*   **数据交互**：通过 AXI 接口与 PS 端进行通信。

### 2. Processing System (PS) 端 (PetaLinux)
*   **核心任务**：运行基于 Linux 的操作系统，管理网络通信、硬件初始化以及非实时的复杂算法。
*   **驱动与控制**：通过 Linux 版本的 `xrfdc` 驱动 API（结合 `libmetal`）配置 RF-ADC/DAC。
*   **高层算法**：利用 Cortex-A53 多核处理器运行高层语言（如 Python），执行神经网络模型或复杂的 DPD 抽头系数提取算法。

### 3. PetaLinux 实现的优劣势分析
*   **优势 (Pros)**：
    *   **生态与工具链丰富**：支持原生运行 Python、TensorFlow 等工具，无需外部 PC 即可进行复杂的 DPD 算法模型训练与推理。
    *   **网络与扩展性**：借助千兆以太网 (GEM3) 和标准 TCP/IP 协议栈，轻松实现远程部署、监控和 DPD 系数的在线实时更新。
    *   **系统扩展性好**：支持 32/64 位多进程调度、内存管理、多级安全和文件系统（通过 SD 卡挂载根文件系统）。
*   **劣势 (Cons)**：
    *   **延迟与抖动 (Latency and Jitter)**：Linux 系统的非确定性线程调度和中断延迟会破坏裸机系统的实时性。如果 DPD 闭环需要严格的超低延迟系数更新，操作系统带来的开销将成为瓶颈。
    *   **开发门槛较高**：需要掌握设备树 (Device Tree)、内核裁剪、根文件系统配置以及 Linux 用户空间设备驱动 (UIO) 等操作。

---

## 二、 详细执行步骤 (AI 逐步搭建指南)

请按照以下阶段逐步执行系统搭建，每完成一个阶段请验证其功能。

### 阶段 1：Vivado 硬件平台构建与导出
1.  **PS 端外设配置**：在 Vivado Block Design 中，配置 Zynq UltraScale+ MPSoC IP。启用 GEM3 (千兆以太网)、I2C0/I2C1 (用于板载 RF PLL 配置)、UART 以及 SD 卡接口。
2.  **存储器配置**：配置 PS DDR4 控制器，用于 Linux 运行及与 PL 端的共享数据缓存。
3.  **PL 端逻辑集成**：集成 RF Data Converter (RFDC) IP 及 DPD 处理核心 IP。连接 AXI Interconnect 确保 PS 可通过 AXI 端口访问 PL 端寄存器。
4.  **生成与导出**：
    *   完成综合 (Synthesis)、实现 (Implementation) 并生成比特流 (Generate Bitstream)。
    *   通过 `File -> Export -> Export Hardware` 导出 `.xsa` 硬件描述文件，**必须勾选 "Include bitstream"**。

### 阶段 2：PetaLinux 工程初始化与配置
1.  **创建工程**：
    ```bash
    petalinux-create -t project --template zynqMP -n rfsoc_dpd_linux
    cd rfsoc_dpd_linux
    ```
2.  **导入硬件描述**：
    ```bash
    petalinux-config --get-hw-description=<path_to_xsa_directory>
    ```
3.  **系统配置**：在弹出的 menuconfig 中，配置 Image Packaging Configuration 为 SD card，设置 Root filesystem type 为 EXT4 或 INITRD。

### 阶段 3：内核 (Kernel) 与设备树 (Device Tree) 适配
1.  **配置 Kernel**：
    ```bash
    petalinux-config -c kernel
    ```
    *   启用 Userspace I/O (UIO) 驱动，用于在用户态读写 DPD IP 寄存器。
    *   确保 Xilinx RFDC 驱动和 `libmetal` 支持已启用。
2.  **修改设备树**：编辑 `project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`。
    *   将自定义 DPD IP 节点配置为 `compatible = "generic-uio";` 以绑定 UIO 驱动。
    *   确保 RFDC 节点与硬件资源正确映射。

### 阶段 4：根文件系统 (Rootfs) 配置
1.  **配置 Rootfs**：
    ```bash
    petalinux-config -c rootfs
    ```
2.  **添加依赖包**：
    *   勾选 `python3` 及所需科学计算库（如进行系数提取或机器学习）。
    *   勾选网络工具 (ssh, iperf3)。
    *   勾选 `libmetal` 以支持 RFDC 驱动在虚拟内存系统中的地址转换和调用。

### 阶段 5：用户空间应用程序移植 (Bare-metal to Linux App)
1.  **创建 Linux App**：
    ```bash
    petalinux-create -t apps --template c --name dpd-control --enable
    ```
2.  **代码移植重构** (替换裸机逻辑)：
    *   去除裸机特有的打印函数，替换为标准 C 的 `printf`。
    *   放弃裸机裸读写操作，改用 `/dev/uioX` 或 `/dev/mem`，通过 `mmap()` 函数将 PL 端 DPD 引擎的物理地址映射到用户态的虚拟地址空间。
    *   调用 Linux 环境下的 `xrfdc` 库函数来初始化 RF-ADC/DAC 的 NCO 配置。

### 阶段 6：编译、打包与 SD 卡部署
1.  **整体编译**：
    ```bash
    petalinux-build
    ```
2.  **生成启动镜像 (BOOT.BIN)**：
    ```bash
    petalinux-package --boot --fsbl images/linux/zynqmp_fsbl.elf --fpga images/linux/system.bit --pmufw images/linux/pmufw.elf --u-boot
    ```
3.  **烧录部署**：
    *   格式化 SD 卡（根据文件系统类型，通常划分 FAT32 分区用于存放启动文件，EXT4 用于根文件系统）。
    *   将生成的 `BOOT.BIN`, `image.ub`, `boot.scr` 拷贝至 SD 卡。
    *   将 ZCU111 拨码开关设置为 SD 卡启动模式，插入 SD 卡并上电，由 FSBL 初始化 PS 端并完成 PL 端比特流的加载。

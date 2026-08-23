#ifndef DPD_ALGORITHM_H
#define DPD_ALGORITHM_H

#include <complex.h>

// 声明外部所需的常量
#define M_DEPTH 2   // 记忆深度 (m=0, 1)
#define K_ORDER 3   // 非线性阶数数量 (使用 1阶, 3阶, 5阶)
#define NUM_COEFFS (M_DEPTH * K_ORDER) // 总系数个数 (6)

// 声明提取系数的函数
void extract_dpd_coefficients(double complex *w);

#endif // DPD_ALGORITHM_H

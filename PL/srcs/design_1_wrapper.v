//Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
//Date        : Tue Mar  3 15:44:15 2026
//Host        : LAPTOP-VL0GMO35 running 64-bit major release  (build 9200)
//Command     : generate_target design_1_wrapper.bd
//Design      : design_1_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module design_1_wrapper
   (CLK_IN_D_0_clk_n,
    CLK_IN_D_0_clk_p,
    adc0_clk_0_clk_n,
    adc0_clk_0_clk_p,
    dac1_clk_0_clk_n,
    dac1_clk_0_clk_p,
    vin0_01_0_v_n,
    vin0_01_0_v_p,
    vin0_23_0_v_n,
    vin0_23_0_v_p,
    vout12_0_v_n,
    vout12_0_v_p,
    vout10_0_v_n,
    vout10_0_v_p);
  input CLK_IN_D_0_clk_n;
  input CLK_IN_D_0_clk_p;
  input adc0_clk_0_clk_n;
  input adc0_clk_0_clk_p;
  input dac1_clk_0_clk_n;
  input dac1_clk_0_clk_p;
  input vin0_01_0_v_n;
  input vin0_01_0_v_p;
  input vin0_23_0_v_n;
  input vin0_23_0_v_p;
  output vout12_0_v_n;
  output vout12_0_v_p;
  output vout10_0_v_n;
  output vout10_0_v_p;

  wire CLK_IN_D_0_clk_n;
  wire CLK_IN_D_0_clk_p;
  wire adc0_clk_0_clk_n;
  wire adc0_clk_0_clk_p;
  wire dac1_clk_0_clk_n;
  wire dac1_clk_0_clk_p;
  wire vin0_01_0_v_n;
  wire vin0_01_0_v_p;
  wire vin0_23_0_v_n;
  wire vin0_23_0_v_p;
  wire vout12_0_v_n;
  wire vout12_0_v_p;
  wire vout10_0_v_n;
  wire vout10_0_v_p;

  design_1 design_1_i
       (.CLK_IN_D_0_clk_n(CLK_IN_D_0_clk_n),
        .CLK_IN_D_0_clk_p(CLK_IN_D_0_clk_p),
        .adc0_clk_0_clk_n(adc0_clk_0_clk_n),
        .adc0_clk_0_clk_p(adc0_clk_0_clk_p),
        .dac1_clk_0_clk_n(dac1_clk_0_clk_n),
        .dac1_clk_0_clk_p(dac1_clk_0_clk_p),
        .vin0_01_0_v_n(vin0_01_0_v_n),
        .vin0_01_0_v_p(vin0_01_0_v_p),
        .vin0_23_0_v_n(vin0_23_0_v_n),
        .vin0_23_0_v_p(vin0_23_0_v_p),
        .vout12_0_v_n(vout12_0_v_n),
        .vout12_0_v_p(vout12_0_v_p),
        .vout10_0_v_n(vout10_0_v_n),
        .vout10_0_v_p(vout10_0_v_p));
endmodule

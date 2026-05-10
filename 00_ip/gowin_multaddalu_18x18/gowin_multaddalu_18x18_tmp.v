//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW2AR-LV18QN88C8/I7
//Device: GW2AR-18
//Device Version: C
//Created Time: Thu May  7 08:20:06 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    gowin_multaddalu_18x18 your_instance_name(
        .dout(dout), //output [16:0] dout
        .caso(caso), //output [54:0] caso
        .a0(a0), //input [7:0] a0
        .b0(b0), //input [7:0] b0
        .a1(a1), //input [7:0] a1
        .b1(b1), //input [7:0] b1
        .ce(ce), //input ce
        .clk(clk), //input clk
        .reset(reset) //input reset
    );

//--------Copy end-------------------

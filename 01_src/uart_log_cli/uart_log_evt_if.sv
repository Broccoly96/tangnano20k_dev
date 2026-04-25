`timescale 1ns / 1ps
`ifndef UART_LOG_EVT_IF_SV
`define UART_LOG_EVT_IF_SV
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_evt_if.sv
// Description  : Shared uart_log_cli event-source interface.
//                - producer drives evt_valid, evt_id, and arg0..arg2.
//                - consumer drives evt_ready and enable.
//                - enable selects the currently active log source and is kept
//                  with the event handshake so source wiring stays coherent.
//////////////////////////////////////////////////////////////////////////////////

interface uart_log_evt_if #(
  parameter int unsigned EVT_ID_W = 8,
  parameter int unsigned ARG_W    = 32
);
  logic                evt_valid;
  logic [EVT_ID_W-1:0] evt_id;
  logic                evt_ready;
  logic [ARG_W-1:0]    arg0;
  logic [ARG_W-1:0]    arg1;
  logic [ARG_W-1:0]    arg2;
  logic                enable;

  modport producer (
    output evt_valid,
    output evt_id,
    input  evt_ready,
    output arg0,
    output arg1,
    output arg2,
    input  enable
  );

  modport consumer (
    input  evt_valid,
    input  evt_id,
    output evt_ready,
    input  arg0,
    input  arg1,
    input  arg2,
    output enable
  );
endinterface

`endif

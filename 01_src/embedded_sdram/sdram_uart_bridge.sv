`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bridge.sv
// Description  : Minimal UART-command to embedded SDRAM bridge.
//                - Consumes decoded CLI RX bytes from uart_log_cli.
//                - Supports single-word write and single-word read commands.
//                - Returns command results as UART log events.
//
// Command format:
//   0x57 'W' + ADDR[23:16] + ADDR[15:8] + ADDR[7:0] + DATA[31:24:16:8:0]
//   0x52 'R' + ADDR[23:16] + ADDR[15:8] + ADDR[7:0]
//
// Response events:
//   0x20 : INIT_DONE
//   0x30 : WRITE_ACK   arg0=addr arg1=data arg2=status
//   0x31 : READ_RSP    arg0=addr arg1=data arg2=status
//   0x3E : CMD_ERR     arg0=reason arg1=cmd arg2=detail
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_bridge (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_CLI_RX_VALID,
  input  logic [7:0]  I_CLI_RX_DATA,
  output logic        O_EVT_VALID,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2,
  input  logic        I_EVT_READY,
  output logic        O_INIT_DONE,
  output logic        O_CMD_BUSY,
  output logic        O_sdram_clk,
  output logic        O_sdram_cke,
  output logic        O_sdram_cs_n,
  output logic        O_sdram_cas_n,
  output logic        O_sdram_ras_n,
  output logic        O_sdram_wen_n,
  output logic [3:0]  O_sdram_dqm,
  output logic [10:0] O_sdram_addr,
  output logic [1:0]  O_sdram_ba,
  inout  wire [31:0]  IO_sdram_dq
);

`ifdef SIM
  import tb_log_pkg::*;
`endif

  localparam logic [7:0] CMD_WRITE     = 8'h57;
  localparam logic [7:0] CMD_READ      = 8'h52;

  localparam logic [7:0] EVT_INIT_DONE = 8'h20;
  localparam logic [7:0] EVT_WRITE_ACK = 8'h30;
  localparam logic [7:0] EVT_READ_RSP  = 8'h31;
  localparam logic [7:0] EVT_CMD_ERR   = 8'h3E;

  localparam logic [31:0] ERR_BAD_CMD      = 32'h0000_0001;
  localparam logic [31:0] ERR_BUSY         = 32'h0000_0002;
  localparam logic [31:0] ERR_RD_TIMEOUT   = 32'h0000_0003;
  localparam logic [31:0] ERR_WR_TIMEOUT   = 32'h0000_0004;

  localparam int unsigned EVT_FIFO_DEPTH = 8;
  localparam int unsigned EVT_FIFO_PTR_W = $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W = $clog2(EVT_FIFO_DEPTH + 1);
  localparam int unsigned WR_STREAM_CYCLES = 4;
  localparam int unsigned RESP_TIMEOUT_CYCLES = 128;

  typedef enum logic [2:0] {
    PARSE_IDLE,
    PARSE_ADDR1,
    PARSE_ADDR2,
    PARSE_ADDR3,
    PARSE_DATA3,
    PARSE_DATA2,
    PARSE_DATA1,
    PARSE_DATA0
  } st_parse_e;

  typedef enum logic [2:0] {
    EXEC_WAIT_INIT,
    EXEC_IDLE,
    EXEC_WRITE_REQ,
    EXEC_WRITE_WAIT,
    EXEC_READ_REQ,
    EXEC_READ_WAIT,
    EXEC_RESPOND_ERR,
    EXEC_RESPOND_OK
  } st_exec_e;

  logic        l_sdrc_wr_n;
  logic        l_sdrc_rd_n;
  logic [20:0] l_sdrc_addr;
  logic [7:0]  l_sdrc_data_len;
  logic [3:0]  l_sdrc_dqm;
  logic [31:0] l_sdrc_wr_data;
  logic [31:0] l_sdrc_rd_data;
  logic        l_sdrc_busy_n;
  logic        l_sdrc_rd_valid;
  logic        l_sdrc_wrd_ack;

  st_parse_e st_parse;
  st_exec_e  st_exec;

  logic        r_cmd_is_write;
  logic [20:0] r_parse_addr;
  logic [31:0] r_parse_data;
  logic [7:0]  r_parse_cmd;
  logic        r_cmd_pending_valid;
  logic        r_pending_is_write;
  logic [20:0] r_pending_addr;
  logic [31:0] r_pending_data;

  logic        r_init_logged;
  logic [7:0]  r_exec_cycle_cnt;
  logic [7:0]  r_timeout_cnt;
  logic        r_busy_seen_low;
  logic        r_read_seen_valid;
  logic [31:0] r_wr_stream_data;
  logic [31:0] r_read_data_latched;
  logic [7:0]  r_rsp_evt_id;
  logic [31:0] r_rsp_arg0;
  logic [31:0] r_rsp_arg1;
  logic [31:0] r_rsp_arg2;
  logic        r_sdrc_rd_valid_q;

  logic        l_evt_push_valid;
  logic [7:0]  l_evt_push_id;
  logic [31:0] l_evt_push_arg0;
  logic [31:0] l_evt_push_arg1;
  logic [31:0] l_evt_push_arg2;

  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic                      s_evt_fifo_full;
  logic                      s_evt_fifo_empty;
  logic                      s_evt_push;
  logic                      s_evt_pop;
  logic                      s_rd_valid_pulse;

  assign s_rd_valid_pulse = l_sdrc_rd_valid && !r_sdrc_rd_valid_q;

  assign l_sdrc_addr     = r_pending_addr;
  assign l_sdrc_data_len = 8'd0;
  assign l_sdrc_dqm      = 4'h0;
  assign l_sdrc_wr_data  = r_wr_stream_data;
  assign l_sdrc_wr_n     = (st_exec == EXEC_WRITE_REQ) ? 1'b0 : 1'b1;
  assign l_sdrc_rd_n     = (st_exec == EXEC_READ_REQ)  ? 1'b0 : 1'b1;

  assign O_CMD_BUSY = (st_exec != EXEC_IDLE);

  assign s_evt_fifo_full  = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty = (r_evt_count == 0);
  assign s_evt_push       = l_evt_push_valid && !s_evt_fifo_full;
  assign s_evt_pop        = O_EVT_VALID && I_EVT_READY;

  assign O_EVT_VALID = !s_evt_fifo_empty;
  assign O_EVT_ID    = s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign O_EVT_ARG0  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign O_EVT_ARG1  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign O_EVT_ARG2  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  // Tracks the UART command parser state and assembles one pending SDRAM
  // command at a time from cli RX bytes.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_parse            <= PARSE_IDLE;
      r_cmd_is_write      <= 1'b0;
      r_parse_addr        <= '0;
      r_parse_data        <= '0;
      r_parse_cmd         <= 8'h00;
      r_cmd_pending_valid <= 1'b0;
      r_pending_is_write  <= 1'b0;
      r_pending_addr      <= '0;
      r_pending_data      <= '0;
    end else begin
      if ((st_exec == EXEC_RESPOND_OK) || (st_exec == EXEC_RESPOND_ERR)) begin
        r_cmd_pending_valid <= 1'b0;
      end

      if (I_CLI_RX_VALID) begin
        case (st_parse)
          PARSE_IDLE: begin
            if (I_CLI_RX_DATA == CMD_WRITE) begin
              st_parse       <= PARSE_ADDR1;
              r_cmd_is_write <= 1'b1;
              r_parse_cmd    <= I_CLI_RX_DATA;
              r_parse_addr   <= '0;
              r_parse_data   <= '0;
            end else if (I_CLI_RX_DATA == CMD_READ) begin
              st_parse       <= PARSE_ADDR1;
              r_cmd_is_write <= 1'b0;
              r_parse_cmd    <= I_CLI_RX_DATA;
              r_parse_addr   <= '0;
              r_parse_data   <= '0;
            end
          end

          PARSE_ADDR1: begin
            r_parse_addr[20:16] <= I_CLI_RX_DATA[4:0];
            st_parse            <= PARSE_ADDR2;
          end

          PARSE_ADDR2: begin
            r_parse_addr[15:8] <= I_CLI_RX_DATA;
            st_parse           <= PARSE_ADDR3;
          end

          PARSE_ADDR3: begin
            r_parse_addr[7:0] <= I_CLI_RX_DATA;
            if (r_cmd_is_write) begin
              st_parse <= PARSE_DATA3;
            end else begin
              if (!r_cmd_pending_valid) begin
                r_cmd_pending_valid <= 1'b1;
                r_pending_is_write  <= 1'b0;
                r_pending_addr      <= {r_parse_addr[20:8], I_CLI_RX_DATA};
                r_pending_data      <= 32'h0;
              end
              st_parse <= PARSE_IDLE;
            end
          end

          PARSE_DATA3: begin
            r_parse_data[31:24] <= I_CLI_RX_DATA;
            st_parse            <= PARSE_DATA2;
          end

          PARSE_DATA2: begin
            r_parse_data[23:16] <= I_CLI_RX_DATA;
            st_parse            <= PARSE_DATA1;
          end

          PARSE_DATA1: begin
            r_parse_data[15:8] <= I_CLI_RX_DATA;
            st_parse           <= PARSE_DATA0;
          end

          PARSE_DATA0: begin
            if (!r_cmd_pending_valid) begin
              r_cmd_pending_valid <= 1'b1;
              r_pending_is_write  <= 1'b1;
              r_pending_addr      <= r_parse_addr;
              r_pending_data      <= {r_parse_data[31:8], I_CLI_RX_DATA};
            end
            st_parse <= PARSE_IDLE;
          end

          default: begin
            st_parse <= PARSE_IDLE;
          end
        endcase
      end
    end
  end

  // Owns SDRAM request/response sequencing for one pending command.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_exec           <= EXEC_WAIT_INIT;
      r_exec_cycle_cnt  <= '0;
      r_timeout_cnt     <= '0;
      r_busy_seen_low   <= 1'b0;
      r_read_seen_valid <= 1'b0;
      r_wr_stream_data  <= 32'h0;
      r_read_data_latched <= 32'h0;
      r_rsp_evt_id      <= 8'h00;
      r_rsp_arg0        <= 32'h0;
      r_rsp_arg1        <= 32'h0;
      r_rsp_arg2        <= 32'h0;
      r_sdrc_rd_valid_q <= 1'b0;
      r_init_logged     <= 1'b0;
    end else begin
      r_sdrc_rd_valid_q <= l_sdrc_rd_valid;

      if (!r_init_logged && O_INIT_DONE) begin
        r_init_logged <= 1'b1;
      end

      case (st_exec)
        EXEC_WAIT_INIT: begin
          r_exec_cycle_cnt <= '0;
          r_timeout_cnt    <= '0;
          r_busy_seen_low  <= 1'b0;
          r_read_seen_valid <= 1'b0;
          r_wr_stream_data <= 32'h0;
          if (O_INIT_DONE) begin
            st_exec <= EXEC_IDLE;
          end
        end

        EXEC_IDLE: begin
          r_exec_cycle_cnt <= '0;
          r_timeout_cnt    <= '0;
          r_busy_seen_low  <= 1'b0;
          r_read_seen_valid <= 1'b0;
          r_wr_stream_data <= r_pending_data;
          if (r_cmd_pending_valid) begin
            if (!O_INIT_DONE) begin
              st_exec    <= EXEC_RESPOND_ERR;
              r_rsp_evt_id <= EVT_CMD_ERR;
              r_rsp_arg0 <= ERR_BAD_CMD;
              r_rsp_arg1 <= {24'h0, r_parse_cmd};
              r_rsp_arg2 <= 32'h0000_0000;
            end else if (!l_sdrc_busy_n) begin
              st_exec    <= EXEC_RESPOND_ERR;
              r_rsp_evt_id <= EVT_CMD_ERR;
              r_rsp_arg0 <= ERR_BUSY;
              r_rsp_arg1 <= {24'h0, r_parse_cmd};
              r_rsp_arg2 <= {11'h0, r_pending_addr};
            end else if (r_pending_is_write) begin
              st_exec <= EXEC_WRITE_REQ;
            end else begin
              st_exec <= EXEC_READ_REQ;
            end
          end
        end

        EXEC_WRITE_REQ: begin
          st_exec          <= EXEC_WRITE_WAIT;
          r_exec_cycle_cnt <= '0;
          r_timeout_cnt    <= '0;
          r_busy_seen_low  <= 1'b0;
          r_wr_stream_data <= r_pending_data;
        end

        EXEC_WRITE_WAIT: begin
          if (r_exec_cycle_cnt < WR_STREAM_CYCLES - 1) begin
            r_wr_stream_data <= r_wr_stream_data + 1'b1;
          end
          if (!l_sdrc_busy_n) begin
            r_busy_seen_low <= 1'b1;
          end
          r_exec_cycle_cnt <= r_exec_cycle_cnt + 1'b1;
          if (r_busy_seen_low && l_sdrc_busy_n &&
              (r_exec_cycle_cnt >= WR_STREAM_CYCLES - 1)) begin
            st_exec     <= EXEC_RESPOND_OK;
            r_rsp_evt_id <= EVT_WRITE_ACK;
            r_rsp_arg0  <= {11'h0, r_pending_addr};
            r_rsp_arg1  <= r_pending_data;
            r_rsp_arg2  <= 32'h0000_0000;
          end else if (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1) begin
            st_exec     <= EXEC_RESPOND_ERR;
            r_rsp_evt_id <= EVT_CMD_ERR;
            r_rsp_arg0  <= ERR_WR_TIMEOUT;
            r_rsp_arg1  <= {11'h0, r_pending_addr};
            r_rsp_arg2  <= r_pending_data;
          end else begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end
        end

        EXEC_READ_REQ: begin
          st_exec          <= EXEC_READ_WAIT;
          r_exec_cycle_cnt <= '0;
          r_timeout_cnt    <= '0;
          r_busy_seen_low  <= 1'b0;
          r_read_seen_valid <= 1'b0;
          r_wr_stream_data <= r_pending_data;
        end

        EXEC_READ_WAIT: begin
          if (!l_sdrc_busy_n) begin
            r_busy_seen_low <= 1'b1;
          end
          if (s_rd_valid_pulse) begin
            r_read_seen_valid <= 1'b1;
          end
          r_exec_cycle_cnt <= r_exec_cycle_cnt + 1'b1;
          if (s_rd_valid_pulse) begin
            r_read_data_latched <= l_sdrc_rd_data;
            r_rsp_arg1        <= l_sdrc_rd_data;
          end

          if (r_read_seen_valid && r_busy_seen_low && l_sdrc_busy_n) begin
            st_exec      <= EXEC_RESPOND_OK;
            r_rsp_evt_id <= EVT_READ_RSP;
            r_rsp_arg0   <= {11'h0, r_pending_addr};
            r_rsp_arg1   <= r_read_data_latched;
            r_rsp_arg2   <= 32'h0000_0000;
          end else if (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1) begin
            st_exec     <= EXEC_RESPOND_ERR;
            r_rsp_evt_id <= EVT_CMD_ERR;
            r_rsp_arg0  <= ERR_RD_TIMEOUT;
            r_rsp_arg1  <= {11'h0, r_pending_addr};
            r_rsp_arg2  <= 32'h0000_0000;
          end else begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end
        end

        EXEC_RESPOND_ERR: begin
          st_exec <= EXEC_IDLE;
        end

        EXEC_RESPOND_OK: begin
          st_exec <= EXEC_IDLE;
        end

        default: begin
          st_exec <= EXEC_WAIT_INIT;
        end
      endcase
    end
  end

  // Generates one-cycle UART-log event requests for init, command completion,
  // and parser/transaction errors.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      l_evt_push_valid <= 1'b0;
      l_evt_push_id    <= 8'h00;
      l_evt_push_arg0  <= 32'h0;
      l_evt_push_arg1  <= 32'h0;
      l_evt_push_arg2  <= 32'h0;
    end else begin
      l_evt_push_valid <= 1'b0;

      if (!r_init_logged && O_INIT_DONE) begin
        l_evt_push_valid <= 1'b1;
        l_evt_push_id    <= EVT_INIT_DONE;
        l_evt_push_arg0  <= 32'h0;
        l_evt_push_arg1  <= 32'h0;
        l_evt_push_arg2  <= 32'h0;
      end else if ((st_parse == PARSE_IDLE) && I_CLI_RX_VALID &&
                   (I_CLI_RX_DATA != CMD_WRITE) && (I_CLI_RX_DATA != CMD_READ)) begin
        l_evt_push_valid <= 1'b1;
        l_evt_push_id    <= EVT_CMD_ERR;
        l_evt_push_arg0  <= ERR_BAD_CMD;
        l_evt_push_arg1  <= {24'h0, I_CLI_RX_DATA};
        l_evt_push_arg2  <= 32'h0000_0000;
      end else if ((st_parse == PARSE_ADDR3 || st_parse == PARSE_DATA0) &&
                   I_CLI_RX_VALID && r_cmd_pending_valid) begin
        l_evt_push_valid <= 1'b1;
        l_evt_push_id    <= EVT_CMD_ERR;
        l_evt_push_arg0  <= ERR_BUSY;
        l_evt_push_arg1  <= {24'h0, r_parse_cmd};
        l_evt_push_arg2  <= {11'h0, r_pending_addr};
      end else if ((st_exec == EXEC_RESPOND_OK) || (st_exec == EXEC_RESPOND_ERR)) begin
        l_evt_push_valid <= 1'b1;
        l_evt_push_id    <= r_rsp_evt_id;
        l_evt_push_arg0  <= r_rsp_arg0;
        l_evt_push_arg1  <= r_rsp_arg1;
        l_evt_push_arg2  <= r_rsp_arg2;
      end
    end
  end

  // Preserves response events until uart_log_cli selects and drains this source.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_wr_ptr   <= '0;
      r_evt_rd_ptr   <= '0;
      r_evt_count    <= '0;
      r_evt_fifo_mem <= '{default: 104'h0};
    end else begin
      if (s_evt_push) begin
        r_evt_fifo_mem[r_evt_wr_ptr] <= {
          l_evt_push_id,
          l_evt_push_arg0,
          l_evt_push_arg1,
          l_evt_push_arg2
        };
        if (r_evt_wr_ptr == EVT_FIFO_DEPTH - 1) begin
          r_evt_wr_ptr <= '0;
        end else begin
          r_evt_wr_ptr <= r_evt_wr_ptr + 1'b1;
        end
      end

      if (s_evt_pop) begin
        if (r_evt_rd_ptr == EVT_FIFO_DEPTH - 1) begin
          r_evt_rd_ptr <= '0;
        end else begin
          r_evt_rd_ptr <= r_evt_rd_ptr + 1'b1;
        end
      end

      case ({s_evt_push, s_evt_pop})
        2'b10: r_evt_count <= r_evt_count + 1'b1;
        2'b01: r_evt_count <= r_evt_count - 1'b1;
        default: r_evt_count <= r_evt_count;
      endcase
    end
  end

  embedded_sdram u_embedded_sdram (
    .O_sdram_clk         (O_sdram_clk),
    .O_sdram_cke         (O_sdram_cke),
    .O_sdram_cs_n        (O_sdram_cs_n),
    .O_sdram_cas_n       (O_sdram_cas_n),
    .O_sdram_ras_n       (O_sdram_ras_n),
    .O_sdram_wen_n       (O_sdram_wen_n),
    .O_sdram_dqm         (O_sdram_dqm),
    .O_sdram_addr        (O_sdram_addr),
    .O_sdram_ba          (O_sdram_ba),
    .IO_sdram_dq         (IO_sdram_dq),
    .I_sdrc_rst_n        (I_RST_N),
    .I_sdrc_clk          (I_CLK),
    .I_sdram_clk         (I_CLK),
    .I_sdrc_selfrefresh  (1'b0),
    .I_sdrc_power_down   (1'b0),
    .I_sdrc_wr_n         (l_sdrc_wr_n),
    .I_sdrc_rd_n         (l_sdrc_rd_n),
    .I_sdrc_addr         (l_sdrc_addr),
    .I_sdrc_data_len     (l_sdrc_data_len),
    .I_sdrc_dqm          (l_sdrc_dqm),
    .I_sdrc_data         (l_sdrc_wr_data),
    .O_sdrc_data         (l_sdrc_rd_data),
    .O_sdrc_init_done    (O_INIT_DONE),
    .O_sdrc_busy_n       (l_sdrc_busy_n),
    .O_sdrc_rd_valid     (l_sdrc_rd_valid),
    .O_sdrc_wrd_ack      (l_sdrc_wrd_ack)
  );

`ifdef SIM
  function automatic string parse_name(input st_parse_e state_value);
    case (state_value)
      PARSE_IDLE:  parse_name = "PARSE_IDLE";
      PARSE_ADDR1: parse_name = "PARSE_ADDR1";
      PARSE_ADDR2: parse_name = "PARSE_ADDR2";
      PARSE_ADDR3: parse_name = "PARSE_ADDR3";
      PARSE_DATA3: parse_name = "PARSE_DATA3";
      PARSE_DATA2: parse_name = "PARSE_DATA2";
      PARSE_DATA1: parse_name = "PARSE_DATA1";
      PARSE_DATA0: parse_name = "PARSE_DATA0";
      default:     parse_name = "PARSE_UNKNOWN";
    endcase
  endfunction

  function automatic string exec_name(input st_exec_e state_value);
    case (state_value)
      EXEC_WAIT_INIT:   exec_name = "EXEC_WAIT_INIT";
      EXEC_IDLE:        exec_name = "EXEC_IDLE";
      EXEC_WRITE_REQ:   exec_name = "EXEC_WRITE_REQ";
      EXEC_WRITE_WAIT:  exec_name = "EXEC_WRITE_WAIT";
      EXEC_READ_REQ:    exec_name = "EXEC_READ_REQ";
      EXEC_READ_WAIT:   exec_name = "EXEC_READ_WAIT";
      EXEC_RESPOND_ERR: exec_name = "EXEC_RESPOND_ERR";
      EXEC_RESPOND_OK:  exec_name = "EXEC_RESPOND_OK";
      default:          exec_name = "EXEC_UNKNOWN";
    endcase
  endfunction

  st_parse_e r_parse_dbg_q;
  st_exec_e  r_exec_dbg_q;

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_parse_dbg_q <= PARSE_IDLE;
      r_exec_dbg_q  <= EXEC_WAIT_INIT;
    end else begin
      if (r_parse_dbg_q != st_parse) begin
        tb_log_pkg::log_debug(
          "SDRAM UART",
          $sformatf(
            "parse %s -> %s byte=0x%02h pending=%0b",
            parse_name(r_parse_dbg_q),
            parse_name(st_parse),
            I_CLI_RX_DATA,
            r_cmd_pending_valid
          )
        );
      end

      if (r_exec_dbg_q != st_exec) begin
        tb_log_pkg::log_debug(
          "SDRAM UART",
          $sformatf(
            "exec %s -> %s addr=0x%05h data=0x%08h busy_n=%0b rd_valid=%0b",
            exec_name(r_exec_dbg_q),
            exec_name(st_exec),
            r_pending_addr,
            r_pending_data,
            l_sdrc_busy_n,
            l_sdrc_rd_valid
          )
        );
      end

      if (I_CLI_RX_VALID) begin
        tb_log_pkg::log_trace(
          "SDRAM UART",
          $sformatf("cli byte=0x%02h", I_CLI_RX_DATA)
        );
      end

      if (s_rd_valid_pulse) begin
        tb_log_pkg::log_trace(
          "SDRAM UART",
          $sformatf("read data addr=0x%05h data=0x%08h", r_pending_addr, l_sdrc_rd_data)
        );
      end

      r_parse_dbg_q <= st_parse;
      r_exec_dbg_q  <= st_exec;
    end
  end
`endif

endmodule

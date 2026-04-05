`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bridge_ctrl.sv
// Description  : UART-command to SDRAM user-interface controller.
//                - Parses single-word UART commands.
//                - Expands each command into one 26-word SDRAM line access.
//                - Keeps a simple line shadow so writes avoid single-beat
//                  accesses that upset the vendor SDRAM simulation model.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_bridge_ctrl (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_ENABLE,
  input  logic        I_CLI_RX_VALID,
  input  logic [7:0]  I_CLI_RX_DATA,
  input  logic        I_SDRC_INIT_DONE,
  input  logic        I_SDRC_BUSY_N,
  input  logic        I_SDRC_RD_VALID,
  input  logic [31:0] I_SDRC_RD_DATA,
  output logic        O_SDRC_WR_N,
  output logic        O_SDRC_RD_N,
  output logic [20:0] O_SDRC_ADDR,
  output logic [7:0]  O_SDRC_DATA_LEN,
  output logic [3:0]  O_SDRC_DQM,
  output logic [31:0] O_SDRC_WR_DATA,
  output logic        O_EVT_VALID,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2,
  input  logic        I_EVT_READY,
  output logic        O_CMD_BUSY
);

`ifdef SIM
  import tb_log_pkg::*;
`endif

  localparam logic [7:0] CMD_WRITE = 8'h57;
  localparam logic [7:0] CMD_READ  = 8'h52;

  localparam logic [7:0] EVT_WRITE_ACK = 8'h30;
  localparam logic [7:0] EVT_READ_RSP  = 8'h31;
  localparam logic [7:0] EVT_CMD_ERR   = 8'h3E;

  localparam logic [31:0] ERR_BAD_CMD      = 32'h0000_0001;
  localparam logic [31:0] ERR_BUSY         = 32'h0000_0002;
  localparam logic [31:0] ERR_RD_TIMEOUT   = 32'h0000_0003;
  localparam logic [31:0] ERR_WR_TIMEOUT   = 32'h0000_0004;

  localparam int unsigned BURST_WORDS        = 26;
  localparam int unsigned BURST_LAST_INDEX   = BURST_WORDS - 1;
  localparam int unsigned EVT_FIFO_DEPTH     = 8;
  localparam int unsigned EVT_FIFO_PTR_W     = $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W     = $clog2(EVT_FIFO_DEPTH + 1);
  localparam int unsigned RESP_TIMEOUT_CYCLES = 256;

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
    EXEC_IDLE,
    EXEC_WRITE_REQ,
    EXEC_WRITE_WAIT_BUSY,
    EXEC_READ_REQ,
    EXEC_READ_WAIT_BUSY,
    EXEC_RESPOND_ERR,
    EXEC_RESPOND_OK
  } st_exec_e;

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

  logic [20:0] r_line_base_addr;
  logic [4:0]  r_line_word_index;
  logic [4:0]  r_target_word_index;
  logic [31:0] r_line_shadow [0:BURST_LAST_INDEX];
  logic [31:0] r_rd_line_buf [0:BURST_LAST_INDEX];
  logic        r_line_shadow_valid;

  logic [7:0]  r_timeout_cnt;
  logic        r_busy_seen_low;
  logic [4:0]  r_stream_index;
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

  logic [7:0]  s_col_mod26;
  logic [7:0]  s_col_base;
  logic [20:0] s_line_base_addr;

  function automatic logic [7:0] mod26(input logic [7:0] col_value);
    begin
      mod26 = col_value % BURST_WORDS;
    end
  endfunction

  assign s_col_mod26    = mod26(r_pending_addr[7:0]);
  assign s_col_base     = r_pending_addr[7:0] - s_col_mod26;
  assign s_line_base_addr = {r_pending_addr[20:8], s_col_base};

  assign s_rd_valid_pulse = I_SDRC_RD_VALID && !r_sdrc_rd_valid_q;

  assign O_SDRC_ADDR     = r_line_base_addr;
  assign O_SDRC_DATA_LEN = BURST_LAST_INDEX[7:0];
  assign O_SDRC_DQM      = 4'h0;
  assign O_SDRC_WR_DATA  = r_line_shadow[r_stream_index];
  assign O_SDRC_WR_N     = (st_exec == EXEC_WRITE_REQ) ? 1'b0 : 1'b1;
  assign O_SDRC_RD_N     = (st_exec == EXEC_READ_REQ)  ? 1'b0 : 1'b1;
  assign O_CMD_BUSY      = (st_exec != EXEC_IDLE);

  assign s_evt_fifo_full  = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty = (r_evt_count == 0);
  assign s_evt_push       = l_evt_push_valid && !s_evt_fifo_full;
  assign s_evt_pop        = O_EVT_VALID && I_EVT_READY;

  assign O_EVT_VALID = !s_evt_fifo_empty;
  assign O_EVT_ID    = s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign O_EVT_ARG0  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign O_EVT_ARG1  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign O_EVT_ARG2  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  // Parses UART bytes into one pending single-word command.
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

      if (I_ENABLE && I_CLI_RX_VALID) begin
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

  // Maintains the cached burst line used for host writes.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_line_base_addr   <= '0;
      r_line_word_index  <= '0;
      r_target_word_index <= '0;
      r_line_shadow_valid <= 1'b0;
      for (int word_idx = 0; word_idx < BURST_WORDS; word_idx++) begin
        r_line_shadow[word_idx] <= 32'h0;
        r_rd_line_buf[word_idx] <= 32'h0;
      end
    end else begin
      if (st_exec == EXEC_IDLE && r_cmd_pending_valid) begin
        r_line_base_addr    <= s_line_base_addr;
        r_line_word_index   <= s_col_mod26[4:0];
        r_target_word_index <= s_col_mod26[4:0];

        if (!r_pending_is_write) begin
          for (int word_idx = 0; word_idx < BURST_WORDS; word_idx++) begin
            r_rd_line_buf[word_idx] <= 32'h0;
          end
        end

        if (r_pending_is_write) begin
          if (!r_line_shadow_valid || (r_line_base_addr != s_line_base_addr)) begin
            for (int word_idx = 0; word_idx < BURST_WORDS; word_idx++) begin
              r_line_shadow[word_idx] <= 32'h0;
            end
            r_line_shadow_valid <= 1'b1;
          end
          r_line_shadow[s_col_mod26[4:0]] <= r_pending_data;
        end
      end

      if (s_rd_valid_pulse) begin
        r_rd_line_buf[r_stream_index] <= I_SDRC_RD_DATA;
        r_line_shadow[r_stream_index] <= I_SDRC_RD_DATA;
        r_line_shadow_valid           <= 1'b1;
      end
    end
  end

  // Owns burst issue / wait sequencing against the SDRAM user interface.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_exec           <= EXEC_IDLE;
      r_timeout_cnt     <= '0;
      r_busy_seen_low   <= 1'b0;
      r_stream_index    <= '0;
      r_rsp_evt_id      <= 8'h00;
      r_rsp_arg0        <= 32'h0;
      r_rsp_arg1        <= 32'h0;
      r_rsp_arg2        <= 32'h0;
      r_sdrc_rd_valid_q <= 1'b0;
    end else begin
      r_sdrc_rd_valid_q <= I_SDRC_RD_VALID;

      case (st_exec)
        EXEC_IDLE: begin
          r_timeout_cnt   <= '0;
          r_busy_seen_low <= 1'b0;
          r_stream_index  <= '0;
          if (r_cmd_pending_valid) begin
            if (!I_SDRC_INIT_DONE) begin
              st_exec      <= EXEC_RESPOND_ERR;
              r_rsp_evt_id <= EVT_CMD_ERR;
              r_rsp_arg0   <= ERR_BAD_CMD;
              r_rsp_arg1   <= {24'h0, r_parse_cmd};
              r_rsp_arg2   <= 32'h0;
            end else if (!I_SDRC_BUSY_N) begin
              st_exec      <= EXEC_RESPOND_ERR;
              r_rsp_evt_id <= EVT_CMD_ERR;
              r_rsp_arg0   <= ERR_BUSY;
              r_rsp_arg1   <= {24'h0, r_parse_cmd};
              r_rsp_arg2   <= {11'h0, r_pending_addr};
            end else if (!r_pending_is_write &&
                         r_line_shadow_valid &&
                         (r_line_base_addr == s_line_base_addr)) begin
              st_exec      <= EXEC_RESPOND_OK;
              r_rsp_evt_id <= EVT_READ_RSP;
              r_rsp_arg0   <= {11'h0, r_pending_addr};
              r_rsp_arg1   <= r_line_shadow[s_col_mod26[4:0]];
              r_rsp_arg2   <= 32'h0000_0000;
            end else if (r_pending_is_write) begin
              st_exec <= EXEC_WRITE_REQ;
            end else begin
              st_exec <= EXEC_READ_REQ;
            end
          end
        end

        EXEC_WRITE_REQ: begin
          st_exec        <= EXEC_WRITE_WAIT_BUSY;
          r_timeout_cnt  <= '0;
          r_busy_seen_low <= 1'b0;
          r_stream_index <= '0;
        end

        EXEC_WRITE_WAIT_BUSY: begin
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end

          if (!r_busy_seen_low && (r_stream_index != BURST_LAST_INDEX)) begin
            r_stream_index <= r_stream_index + 1'b1;
          end

          if (r_busy_seen_low && I_SDRC_BUSY_N) begin
            st_exec      <= EXEC_RESPOND_OK;
            r_rsp_evt_id <= EVT_WRITE_ACK;
            r_rsp_arg0   <= {11'h0, r_pending_addr};
            r_rsp_arg1   <= r_pending_data;
            r_rsp_arg2   <= 32'h0;
          end else if (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1) begin
            st_exec      <= EXEC_RESPOND_ERR;
            r_rsp_evt_id <= EVT_CMD_ERR;
            r_rsp_arg0   <= ERR_WR_TIMEOUT;
            r_rsp_arg1   <= {11'h0, r_pending_addr};
            r_rsp_arg2   <= r_pending_data;
          end else begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end
        end

        EXEC_READ_REQ: begin
          st_exec        <= EXEC_READ_WAIT_BUSY;
          r_timeout_cnt  <= '0;
          r_busy_seen_low <= 1'b0;
          r_stream_index <= '0;
        end

        EXEC_READ_WAIT_BUSY: begin
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end

          if (s_rd_valid_pulse && (r_stream_index != BURST_LAST_INDEX)) begin
            r_stream_index <= r_stream_index + 1'b1;
          end

          if (r_busy_seen_low && I_SDRC_BUSY_N) begin
            st_exec      <= EXEC_RESPOND_OK;
            r_rsp_evt_id <= EVT_READ_RSP;
            r_rsp_arg0   <= {11'h0, r_pending_addr};
            r_rsp_arg1   <= r_rd_line_buf[r_target_word_index];
            r_rsp_arg2   <= 32'h0;
          end else if (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1) begin
            st_exec      <= EXEC_RESPOND_ERR;
            r_rsp_evt_id <= EVT_CMD_ERR;
            r_rsp_arg0   <= ERR_RD_TIMEOUT;
            r_rsp_arg1   <= {11'h0, r_pending_addr};
            r_rsp_arg2   <= 32'h0;
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
          st_exec <= EXEC_IDLE;
        end
      endcase
    end
  end

  // Emits one-cycle response or parser error events.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      l_evt_push_valid <= 1'b0;
      l_evt_push_id    <= 8'h00;
      l_evt_push_arg0  <= 32'h0;
      l_evt_push_arg1  <= 32'h0;
      l_evt_push_arg2  <= 32'h0;
    end else begin
      l_evt_push_valid <= 1'b0;

      if (I_ENABLE && (st_parse == PARSE_IDLE) && I_CLI_RX_VALID &&
          (I_CLI_RX_DATA != CMD_WRITE) && (I_CLI_RX_DATA != CMD_READ)) begin
        l_evt_push_valid <= 1'b1;
        l_evt_push_id    <= EVT_CMD_ERR;
        l_evt_push_arg0  <= ERR_BAD_CMD;
        l_evt_push_arg1  <= {24'h0, I_CLI_RX_DATA};
        l_evt_push_arg2  <= 32'h0;
      end else if ((st_parse == PARSE_ADDR3 || st_parse == PARSE_DATA0) &&
                   I_ENABLE && I_CLI_RX_VALID && r_cmd_pending_valid) begin
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

  // Preserves generated events until uart_log_cli drains them.
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

`ifdef SIM
  function automatic string exec_name(input st_exec_e state_value);
    case (state_value)
      EXEC_IDLE:            exec_name = "EXEC_IDLE";
      EXEC_WRITE_REQ:       exec_name = "EXEC_WRITE_REQ";
      EXEC_WRITE_WAIT_BUSY: exec_name = "EXEC_WRITE_WAIT_BUSY";
      EXEC_READ_REQ:        exec_name = "EXEC_READ_REQ";
      EXEC_READ_WAIT_BUSY:  exec_name = "EXEC_READ_WAIT_BUSY";
      EXEC_RESPOND_ERR:     exec_name = "EXEC_RESPOND_ERR";
      EXEC_RESPOND_OK:      exec_name = "EXEC_RESPOND_OK";
      default:              exec_name = "EXEC_UNKNOWN";
    endcase
  endfunction

  st_exec_e r_exec_dbg_q;

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_exec_dbg_q <= EXEC_IDLE;
    end else begin
      if (r_exec_dbg_q != st_exec) begin
        tb_log_pkg::log_debug(
          "SDRAM UART CTRL",
          $sformatf(
            "exec %s -> %s addr=0x%05h base=0x%05h word=%0d busy_n=%0b rd_valid=%0b",
            exec_name(r_exec_dbg_q),
            exec_name(st_exec),
            r_pending_addr,
            r_line_base_addr,
            r_target_word_index,
            I_SDRC_BUSY_N,
            I_SDRC_RD_VALID
          )
        );
      end
      r_exec_dbg_q <= st_exec;
    end
  end
`endif

endmodule

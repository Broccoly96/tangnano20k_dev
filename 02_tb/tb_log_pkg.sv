//------------------------------------------------------------------------------
// tb_log_pkg.sv
//
// Lightweight logging helpers for SystemVerilog testbenches.
// Provides level-gated macros with consistent formatting and optional
// runtime configuration via plusargs:
//   +TB_LOG_LEVEL=<0-5>   : Adjust verbosity (default = 3 / INFO)
//   +TB_TIME_UNIT=<int>   : Override $timeformat unit exponent (default = -9)
//   +TB_TIME_PREC=<int>   : Override $timeformat precision (default = 3)
//   +TB_TIME_WIDTH=<int>  : Override $timeformat minimum field width (default = 12)
//   +TB_TIME_SUFFIX=<str> : Override $timeformat suffix (default = " ns")
//
// Typical usage:
//   import tb_log_pkg::*;
//   initial begin
//     `TB_LOG_INFO("Driver ready");
//     `TB_LOG_DEBUG("addr=0x%0h data=0x%0h", addr, data);
//   end
//------------------------------------------------------------------------------
`ifndef TB_LOG_PKG_SV
`define TB_LOG_PKG_SV

package tb_log_pkg;

  typedef enum int {
    LOG_SILENT = 0,
    LOG_ERROR  = 1,
    LOG_WARN   = 2,
    LOG_INFO   = 3,
    LOG_DEBUG  = 4,
    LOG_TRACE  = 5
  } log_level_e;

  // Default verbosity (can be overridden via plusarg or set_level()).
  log_level_e log_level = LOG_INFO;

  // Utility: convert level enum to printable string.
  function string level_to_string(log_level_e level);
    case (level)
      LOG_SILENT: return "SILNT";
      LOG_ERROR : return "ERROR";
      LOG_WARN  : return "WARN ";
      LOG_INFO  : return "INFO ";
      LOG_DEBUG : return "DEBUG";
      LOG_TRACE : return "TRACE";
      default   : return "LVL?";
    endcase
  endfunction

  // Allow testbench code to adjust verbosity programmatically.
  task automatic set_level(log_level_e level);
    log_level = level;
  endtask

  function log_level_e get_level();
    return log_level;
  endfunction

  //-------------------------------------------------------------------------
  // Configure logging level using plusargs with optional default override.
  // - Applies configure_from_plusargs() once (guarded by config_initialized).
  // - If TB_LOG_LEVEL plusarg is not present, falls back to default_level.
  //-------------------------------------------------------------------------
  task automatic configure_logging(log_level_e default_level = LOG_INFO);
    int lvl;
    // Apply plusargs first (if provided)
    configure_from_plusargs();
    // Respect user plusarg if present; otherwise apply provided default
    if (!$value$plusargs("TB_LOG_LEVEL=%d", lvl)) begin
      set_level(default_level);
    end
  endtask

  //-------------------------------------------------------------------------
  // Helper tasks: emit formatted messages using consistent prefixes.
  // Use $sformatf() at the call site to build the message body.
  //-------------------------------------------------------------------------
  task automatic log_trace(string instance_name, string message);
    if (log_level >= LOG_TRACE) begin
      $display("[%0t][TRACE][%s] %s", $time, instance_name, message);
    end
  endtask

  task automatic log_debug(string instance_name, string message);
    if (log_level >= LOG_DEBUG) begin
      $display("[%0t][DEBUG][%s] %s", $time, instance_name, message);
    end
  endtask

  task automatic log_info(string instance_name, string message);
    if (log_level >= LOG_INFO) begin
      $display("[%0t][INFO ][%s] %s", $time, instance_name, message);
    end
  endtask

  task automatic log_warn(string instance_name, string message);
    if (log_level >= LOG_WARN) begin
      $warning("[%0t][WARN ][%s] %s", $time, instance_name, message);
    end
  endtask

  task automatic log_error(string instance_name, string message);
    if (log_level >= LOG_ERROR) begin
      $error("[%0t][ERROR][%s] %s", $time, instance_name, message);
    end
  endtask

  task automatic log_fatal(int exit_code, string instance_name, string message);
    $fatal(exit_code, "[%0t][FATAL][%s] %s", $time, instance_name, message);
  endtask

  // Helper to apply a custom $timeformat at runtime.
  task automatic set_timeformat(
    int unit_exp     = -9,
    int precision    = 3,
    string suffix    = " ns",
    int min_width    = 12
  );
    $timeformat(unit_exp, precision, suffix, min_width);
  endtask

  // Track whether we have already performed plusarg-based configuration.
  bit config_initialized = 0;

  // Pick up plusargs and apply defaults on first invocation.
  task automatic configure_from_plusargs();
    int lvl;
    int unit_exp;
    int precision;
    int min_width;
    string suffix;

    if (config_initialized) begin
      return;
    end
    config_initialized = 1;

    if ($value$plusargs("TB_LOG_LEVEL=%d", lvl)) begin
      log_level = log_level_e'(lvl);
    end

    // Defaults
    unit_exp  = -9;
    precision = 3;
    min_width = 12;
    suffix    = " ns";

    void'($value$plusargs("TB_TIME_UNIT=%d", unit_exp));
    void'($value$plusargs("TB_TIME_PREC=%d", precision));
    void'($value$plusargs("TB_TIME_WIDTH=%d", min_width));
    void'($value$plusargs("TB_TIME_SUFFIX=%s", suffix));

    set_timeformat(unit_exp, precision, suffix, min_width);
  endtask

endpackage : tb_log_pkg

//------------------------------------------------------------------------------
// Macro helpers
//------------------------------------------------------------------------------

`define TB_LOG_CAN_LOG(level_param) (tb_log_pkg::log_level >= (level_param))
`define TB_LOG_TRACE(MSG) if (`TB_LOG_CAN_LOG(tb_log_pkg::LOG_TRACE)) $display("[%0t][TRACE][%m] %s", $time, (MSG))
`define TB_LOG_DEBUG(MSG) if (`TB_LOG_CAN_LOG(tb_log_pkg::LOG_DEBUG)) $display("[%0t][DEBUG][%m] %s", $time, (MSG))
`define TB_LOG_INFO(MSG)  if (`TB_LOG_CAN_LOG(tb_log_pkg::LOG_INFO )) $display("[%0t][INFO ][%m] %s",  $time, (MSG))
`define TB_LOG_WARN(MSG)  if (`TB_LOG_CAN_LOG(tb_log_pkg::LOG_WARN )) $warning("[%0t][WARN ][%m] %s", $time, (MSG))
`define TB_LOG_ERROR(MSG)                                             $error("[%0t][ERROR][%m] %s", $time, (MSG))
`define TB_LOG_FATAL(EC,MSG)                                          $fatal((EC), "[%0t][FATAL][%m] %s", $time, (MSG))

`endif  // TB_LOG_PKG_SV

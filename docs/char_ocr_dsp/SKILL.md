# Skill: ModelSim SRAM Memory Map Visibility for Character OCR FPGA Project

## Purpose

Use this skill when implementing or verifying the Character OCR FPGA project in simulation. The goal is to make SRAM/SDRAM memory contents easy to inspect during ModelSim/Questa simulation, especially for the OCR accelerator memory map, image buffers, preprocessor output, model weights, activations, and classification scores.

This skill should be used by coding agents before implementing or modifying testbenches, SRAM models, memory-mapped register tests, preprocessor tests, MLP inference tests, or full-system OCR simulations.

## Project Context

The OCR accelerator uses the following key data configuration:

- Input image: 64 x 32, 1bpp
- Input image size: 64 * 32 / 8 = 256 bytes
- Preprocessor output: 32 x 32
- Feature vector: 1024 features
- Feature format: signed int8, values 0 or 1
- Class count: 36
- Default network: 1024 -> 64 -> 36
- Accuracy model: 1024 -> 96 -> 48 -> 36
- Weight format: int8
- Bias format: int32
- Runtime SRAM/SDRAM available: approximately 60 Mbit
- EEPROM: 1024 Kbit / 128 KiB

## Recommended Simulation Visibility Strategy

Do not rely only on ModelSim waveforms for large memory arrays. Large SRAM/SDRAM arrays are difficult to inspect in Wave and can slow down simulation.

Use a combination of:

1. `$readmemh()` for memory initialization.
2. `$writememh()` for raw final memory dumps.
3. `$fwrite()` based human-readable memory map dumps.
4. ASCII-art image dumps for 1bpp image buffers.
5. Labelled score dumps for OCR class outputs.
6. Optional ModelSim Tcl commands for small targeted memory inspection.

## Required Dump Files

For OCR-related tests, generate these files whenever practical:

```text
out/final_sram.mem
out/input_image_64x32_ascii.txt
out/feature_32x32_ascii.txt
out/scores_36.txt
out/result.txt
```

For deeper debug, also generate:

```text
out/model_header.txt
out/weights_l0_dump.txt
out/bias_l0_dump.txt
out/activation_l0_dump.txt
out/activation_l1_dump.txt
out/memory_map_summary.txt
```

## Memory Initialization Pattern

If the SRAM model contains a byte array like this:

```systemverilog
logic [7:0] mem [0:SRAM_SIZE_BYTES-1];
```

Support optional initialization:

```systemverilog
initial begin
  if (INIT_MEM_FILE != "") begin
    $readmemh(INIT_MEM_FILE, mem);
  end
end
```

Use separate files for specific regions when convenient:

```text
input_image.mem
weights.mem
bias.mem
```

For simple SRAM-wide initialization, use one combined hex file.

## Final Raw Memory Dump

At the end of simulation, emit a raw memory image:

```systemverilog
final begin
  $writememh("out/final_sram.mem", mem);
end
```

This is useful for machine comparison, but not ideal for human review. Always pair it with formatted dumps for image, feature, and score regions.

## Formatted Hex Range Dump

Implement a reusable task for address-labelled memory ranges.

```systemverilog
task automatic dump_mem_range_hex(
  input string filename,
  input int unsigned start_addr,
  input int unsigned length
);
  int fd;
  int unsigned addr;
  int unsigned i;
begin
  fd = $fopen(filename, "w");
  if (fd == 0) begin
    $display("ERROR: failed to open %s", filename);
    return;
  end

  for (addr = start_addr; addr < start_addr + length; addr += 16) begin
    $fwrite(fd, "%08x :", addr);
    for (i = 0; i < 16; i++) begin
      if (addr + i < start_addr + length)
        $fwrite(fd, " %02x", mem[addr + i]);
      else
        $fwrite(fd, "   ");
    end
    $fwrite(fd, "\n");
  end

  $fclose(fd);
end
endtask
```

Expected output format:

```text
00000100 : ff 81 81 81 ff 00 00 00 18 24 42 7e 42 42 00 00
00000110 : 00 00 3c 42 42 42 3c 00 00 00 7e 40 7c 40 7e 00
```

## 64x32 Input Image ASCII Dump

For the 64x32 1bpp input image, dump ASCII art. This is much easier to review than hex.

Assume row-major layout:

- 32 rows
- 8 bytes per row
- 64 pixels per row
- MSB-first bit order within each byte

```systemverilog
task automatic dump_image_64x32_ascii(
  input string filename,
  input int unsigned base_addr
);
  int fd;
  int x;
  int y;
  int byte_index;
  int bit_index;
  logic pix;
begin
  fd = $fopen(filename, "w");
  if (fd == 0) begin
    $display("ERROR: failed to open %s", filename);
    return;
  end

  for (y = 0; y < 32; y++) begin
    for (x = 0; x < 64; x++) begin
      byte_index = base_addr + y * 8 + (x >> 3);
      bit_index  = 7 - (x & 7);
      pix = mem[byte_index][bit_index];
      $fwrite(fd, "%s", pix ? "#" : ".");
    end
    $fwrite(fd, "\n");
  end

  $fclose(fd);
end
endtask
```

Expected output style:

```text
................................................................
......................#######...................................
.....................##.....##..................................
.....................##.....##..................................
.....................#########..................................
.....................##.....##..................................
.....................##.....##..................................
................................................................
```

## 32x32 Feature ASCII Dump

For the preprocessor output, dump 32x32 features as ASCII art.

Assume feature format:

- 1024 bytes
- row-major layout
- signed int8 values
- 0 means OFF
- non-zero means ON

```systemverilog
task automatic dump_feature_32x32_ascii(
  input string filename,
  input int unsigned base_addr
);
  int fd;
  int x;
  int y;
  logic [7:0] v;
begin
  fd = $fopen(filename, "w");
  if (fd == 0) begin
    $display("ERROR: failed to open %s", filename);
    return;
  end

  for (y = 0; y < 32; y++) begin
    for (x = 0; x < 32; x++) begin
      v = mem[base_addr + y * 32 + x];
      $fwrite(fd, "%s", (v != 8'd0) ? "#" : ".");
    end
    $fwrite(fd, "\n");
  end

  $fclose(fd);
end
endtask
```

Use this dump to verify the preprocessor behavior, especially the initial horizontal 2:1 OR downsampling:

```systemverilog
out[x,y] = in[2*x,y] | in[2*x+1,y];
```

## 36-Class Score Dump

OCR scores should be dumped with class labels. Do not inspect raw score memory only.

Class mapping:

- Classes 0..9 correspond to `0`..`9`
- Classes 10..35 correspond to `A`..`Z`

Assume each score is signed int32 little-endian in SRAM.

```systemverilog
function automatic byte class_to_ascii(input int cls);
begin
  if (cls < 10)
    class_to_ascii = "0" + cls;
  else
    class_to_ascii = "A" + (cls - 10);
end
endfunction

task automatic dump_scores_36(
  input string filename,
  input int unsigned base_addr
);
  int fd;
  int cls;
  int signed score;
begin
  fd = $fopen(filename, "w");
  if (fd == 0) begin
    $display("ERROR: failed to open %s", filename);
    return;
  end

  $fwrite(fd, "Class Score_dec Score_hex\n");
  for (cls = 0; cls < 36; cls++) begin
    score = {
      mem[base_addr + cls*4 + 3],
      mem[base_addr + cls*4 + 2],
      mem[base_addr + cls*4 + 1],
      mem[base_addr + cls*4 + 0]
    };
    $fwrite(fd, "%s     %0d  0x%08x\n", class_to_ascii(cls), score, score);
  end

  $fclose(fd);
end
endtask
```

## Result Dump

Create a short summary file for automated checks and quick inspection.

Example format:

```text
result_class_id = 10
result_char     = A
result_score    = 12345
runner_status   = PASS
```

The result file should be generated after inference completes.

## Suggested Testbench Output Sequence

At the end of an OCR simulation test, call dump tasks in this order:

```systemverilog
initial begin
  run_test();

  dump_mem_range_hex("out/input_image_hex.txt", INPUT_IMAGE_BASE, 256);
  dump_image_64x32_ascii("out/input_image_64x32_ascii.txt", INPUT_IMAGE_BASE);

  dump_mem_range_hex("out/feature_32x32_hex.txt", FEATURE_BASE, 1024);
  dump_feature_32x32_ascii("out/feature_32x32_ascii.txt", FEATURE_BASE);

  dump_scores_36("out/scores_36.txt", SCORE_BASE);
  dump_mem_range_hex("out/result_regs_hex.txt", REG_BASE, 256);

  $writememh("out/final_sram.mem", mem);
end
```

Adjust base address constants to match `char_ocr_mmap.md` and `char_ocr_pkg.sv`.

## ModelSim Wave Usage Guidance

Do not add the entire SRAM/SDRAM memory array to the Wave window.

Instead, add:

- bus address
- write enable
- write data
- read data
- register control/status signals
- preprocessor start/done
- inference start/done
- layer index
- neuron index
- feature index
- MAC valid/done
- result class

Example Tcl:

```tcl
add wave -radix hex sim:/tb_char_ocr_top/dut/ctrl_reg
add wave -radix hex sim:/tb_char_ocr_top/dut/status_reg
add wave -radix unsigned sim:/tb_char_ocr_top/dut/u_infer/layer_idx
add wave -radix unsigned sim:/tb_char_ocr_top/dut/u_infer/neuron_idx
add wave -radix unsigned sim:/tb_char_ocr_top/dut/u_infer/feature_idx
add wave -radix hex sim:/tb_char_ocr_top/dut/result_class
```

For small targeted memory checks, use `examine`:

```tcl
examine -radix hex sim:/tb_char_ocr_top/u_sram_model/mem(256)
examine -radix hex sim:/tb_char_ocr_top/u_sram_model/mem(257)
```

Use Tcl memory inspection only for small ranges. Use dump files for full image, feature, weight, and score regions.

## Recommended Directory Layout

```text
rtl/
  char_ocr_pkg.sv
  ...

tb/
  tb_char_ocr_top.sv
  tb_mem_dump_pkg.sv
  test_vectors/
    input_image.mem
    weights.mem
    bias.mem

sim/
  run.do
  wave.do

out/
  final_sram.mem
  input_image_64x32_ascii.txt
  feature_32x32_ascii.txt
  scores_36.txt
  result.txt
```

## Agent Implementation Requirements

When an agent implements simulation support for memory visibility, it must:

1. Add reusable dump tasks rather than ad-hoc `$display()` calls.
2. Use file output under `out/`.
3. Create the `out/` directory from the simulation script if needed.
4. Keep raw dumps and human-readable dumps separate.
5. Dump 1bpp images as ASCII art.
6. Dump OCR scores with class labels.
7. Avoid adding huge memory arrays to ModelSim Wave by default.
8. Ensure dump outputs are deterministic and suitable for diff-based review.
9. Document the memory base addresses used by each dump.
10. Add at least one self-checking testbench that verifies a written image can be read back and dumped.

## Recommended First Agent Task

Use this prompt for the first implementation task:

```text
Add ModelSim-friendly memory visibility support for the Character OCR FPGA testbench.

Requirements:
- Create tb/tb_mem_dump_pkg.sv or equivalent reusable dump utilities.
- Support address-labelled hex range dumps.
- Support 64x32 1bpp input image ASCII dumps.
- Support 32x32 int8 feature ASCII dumps.
- Support 36-class signed int32 OCR score dumps with labels 0-9 and A-Z.
- Add final raw SRAM dump using $writememh("out/final_sram.mem", mem).
- Do not add the full SRAM memory array to the default wave.do.
- Update sim/run.do so that the out/ directory is created before simulation.
- Add a small self-checking testbench that writes a 64x32 test pattern, reads it back, runs the dump tasks, and verifies that output files are generated.
```

## Common Pitfalls

Avoid these mistakes:

- Dumping only raw `$writememh()` and expecting humans to inspect it.
- Putting a large SRAM/SDRAM array directly into Wave by default.
- Mixing MSB-first and LSB-first bit order for 1bpp images.
- Forgetting that the 32x32 feature buffer is int8 bytes, not packed bits, unless explicitly configured otherwise.
- Dumping int32 scores with the wrong endian convention.
- Generating non-deterministic dump filenames that are hard to compare.
- Writing dump files into the simulator working directory without a clear `out/` structure.

## Preferred Bit and Byte Conventions

Use these conventions unless the architecture spec says otherwise:

- 1bpp image byte order: row-major
- 1bpp bit order: MSB-first within each byte
- Feature order: row-major, one int8 byte per feature
- Score order: class index order 0..35
- int32 memory layout: little-endian
- ASCII ON pixel: `#`
- ASCII OFF pixel: `.`

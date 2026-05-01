# Character OCR Register and Memory Map Specification

## 1. Target Configuration

```text
Input image         : 64 x 32, 1 bpp
Preprocessor output : 32 x 32
Feature vector      : 1024 features
Feature format      : int8, 0 or 1
Default network     : 1024 -> 64 -> 36
Accuracy model      : 1024 -> 96 -> 48 -> 36
DSP array           : 12 x MULTADDALU18X18
Throughput          : 24 products/cycle
Weight format       : int8
Bias format         : int32
EEPROM              : 1024 Kbit / 128 KiB
Runtime SRAM        : approximately 60 Mbit available
```

## 2. Addressing Assumptions

This document defines a logical memory map. The physical implementation may map these regions into internal SRAM, external SDRAM, or another runtime memory system.

All multi-byte registers are little-endian unless otherwise specified.

## 3. Top-Level Memory Map

|               Address Range |      Size | Name                       | Description                          |
| --------------------------: | --------: | -------------------------- | ------------------------------------ |
| `0x0000_0000 - 0x0000_00FF` |     256 B | Control Registers          | OCR control and status               |
| `0x0000_0100 - 0x0000_01FF` |     256 B | Raw Image Buffer           | `64 x 32 x 1bpp` input image         |
| `0x0000_0200 - 0x0000_027F` |     128 B | Preprocessed Binary Buffer | `32 x 32 x 1bpp` internal image      |
| `0x0000_0400 - 0x0000_07FF` |     1 KiB | Feature Buffer             | `1024 x int8`, values `0` or `1`     |
| `0x0000_1000 - 0x0002_0FFF` |   128 KiB | Model Mirror Region        | EEPROM model image copied to SRAM    |
| `0x0002_1000 - 0x0003_FFFF` |   124 KiB | Runtime Weight Region      | decoded or direct int8 weights       |
| `0x0004_0000 - 0x0004_3FFF` |    16 KiB | Runtime Bias Region        | int32 biases and quant params        |
| `0x0004_4000 - 0x0004_7FFF` |    16 KiB | Activation Buffers         | hidden activation ping-pong buffers  |
| `0x0004_8000 - 0x0004_8FFF` |     4 KiB | Score Buffer               | `36 x int32` logits and debug values |
| `0x0004_9000 - 0x0004_FFFF` |    28 KiB | Trace Buffer               | debug trace / profiling counters     |
|         `0x0005_0000 - ...` | remaining | Reserved                   | test images, datasets, future use    |

The runtime SRAM budget is approximately `60 Mbit`, so this logical map intentionally leaves a large reserved area for debugging and future expansion.

## 4. Control Register Map

Base address: `0x0000_0000`

| Offset | Name               | Access | Description                                |
| -----: | ------------------ | ------ | ------------------------------------------ |
| `0x00` | `CTRL`             | RW     | Main control register                      |
| `0x04` | `STATUS`           | RO/W1C | Main status register                       |
| `0x08` | `IRQ_ENABLE`       | RW     | Optional interrupt enable                  |
| `0x0C` | `IRQ_STATUS`       | RO/W1C | Optional interrupt status                  |
| `0x10` | `MODEL_CTRL`       | RW     | model load and select control              |
| `0x14` | `MODEL_STATUS`     | RO     | model state                                |
| `0x18` | `MODEL_ID`         | RO     | loaded model ID                            |
| `0x1C` | `MODEL_CRC`        | RO     | loaded model CRC                           |
| `0x20` | `PREPROC_CTRL`     | RW     | preprocessing control                      |
| `0x24` | `PREPROC_STATUS`   | RO/W1C | preprocessing status                       |
| `0x28` | `BBOX_X`           | RO     | `{x_max, x_min}` if bbox mode is enabled   |
| `0x2C` | `BBOX_Y`           | RO     | `{y_max, y_min}` if bbox mode is enabled   |
| `0x30` | `NN_CTRL`          | RW     | neural-network inference control           |
| `0x34` | `NN_STATUS`        | RO/W1C | neural-network inference status            |
| `0x38` | `NN_MODEL_SELECT`  | RW     | `0`: default, `1`: accuracy                |
| `0x3C` | `NN_LAYER_COUNT`   | RO     | number of layers in active model           |
| `0x40` | `DSP_CONFIG`       | RW     | DSP compute-array configuration            |
| `0x44` | `DSP_STATUS`       | RO     | DSP compute-array status                   |
| `0x48` | `DSP_CYCLES_TOTAL` | RO     | total inference cycle counter              |
| `0x4C` | `DSP_CYCLES_L0`    | RO     | layer 0 cycle counter                      |
| `0x50` | `DSP_CYCLES_L1`    | RO     | layer 1 cycle counter                      |
| `0x54` | `DSP_CYCLES_L2`    | RO     | layer 2 cycle counter, accuracy model only |
| `0x60` | `RESULT_CLASS`     | RO     | recognized class index                     |
| `0x64` | `RESULT_CHAR`      | RO     | ASCII character result                     |
| `0x68` | `RESULT_SCORE0`    | RO     | best score, int32                          |
| `0x6C` | `RESULT_SCORE1`    | RO     | second-best score, int32                   |
| `0x70` | `RESULT_CONF_GAP`  | RO     | `best - second_best`                       |
| `0x80` | `OLED_CTRL`        | RW     | display control                            |
| `0x84` | `OLED_STATUS`      | RO     | display status                             |
| `0x88` | `OLED_TOGGLE_MS`   | RW     | auto-toggle interval in ms                 |
| `0xF0` | `VERSION`          | RO     | hardware version                           |
| `0xF4` | `BUILD_ID`         | RO     | build identifier                           |

## 5. CTRL Register

Offset: `0x00`

| Bit | Name                     | Description                       |
| --: | ------------------------ | --------------------------------- |
| `0` | `RUN_PREPROC`            | start preprocessing               |
| `1` | `RUN_INFERENCE`          | start neural-network inference    |
| `2` | `RUN_FULL_OCR`           | run preprocessing then inference  |
| `3` | `LOAD_MODEL_FROM_EEPROM` | copy EEPROM model to runtime SRAM |
| `4` | `CLEAR_IMAGE`            | clear raw image buffer            |
| `5` | `CLEAR_RESULT`           | clear result and score buffers    |
| `6` | `OLED_UPDATE`            | force display update              |
| `7` | `SOFT_RESET`             | reset OCR control FSM             |

Bits are self-clearing command bits unless otherwise specified.

## 6. STATUS Register

Offset: `0x04`

|  Bit | Name                 | Description                         |
| ---: | -------------------- | ----------------------------------- |
|  `0` | `MODEL_READY`        | model has been loaded and validated |
|  `1` | `PREPROC_BUSY`       | preprocessing is running            |
|  `2` | `PREPROC_DONE`       | preprocessing complete              |
|  `3` | `NN_BUSY`            | inference is running                |
|  `4` | `NN_DONE`            | inference complete                  |
|  `5` | `OCR_DONE`           | full OCR sequence complete          |
|  `6` | `EMPTY_IMAGE`        | no active pixel detected            |
|  `7` | `ERROR`              | generic error flag                  |
|  `8` | `ERROR_MODEL_CRC`    | model CRC mismatch                  |
|  `9` | `ERROR_MODEL_FORMAT` | unsupported model format            |
| `10` | `ERROR_CMD`          | invalid command                     |

Done and error bits should use write-one-to-clear behavior.

## 7. MODEL_CTRL Register

Offset: `0x10`

| Bit | Name                    | Description                                    |
| --: | ----------------------- | ---------------------------------------------- |
| `0` | `LOAD_EEPROM`           | load model from EEPROM                         |
| `1` | `VALIDATE_ONLY`         | validate model header and CRC only             |
| `2` | `USE_RUNTIME_MODEL`     | use host-written runtime model region          |
| `3` | `PROGRAM_EEPROM`        | optional EEPROM programming command            |
| `8` | `MODEL_SELECT_DEFAULT`  | select default model `1024 -> 64 -> 36`        |
| `9` | `MODEL_SELECT_ACCURACY` | select accuracy model `1024 -> 96 -> 48 -> 36` |

## 8. PREPROC_CTRL Register

Offset: `0x20`

| Bit | Name                    | Description                                         |
| --: | ----------------------- | --------------------------------------------------- |
| `0` | `ENABLE_SIMPLE_HSHRINK` | enable simple `64x32 -> 32x32` horizontal reduction |
| `1` | `ENABLE_BBOX`           | enable bounding-box detection                       |
| `2` | `ENABLE_CENTERING`      | enable centering after bbox                         |
| `3` | `ENABLE_ADV_RESIZE`     | enable advanced bbox-based resize                   |
| `4` | `INVERT_INPUT`          | invert raw image polarity before preprocessing      |

Recommended first revision setting:

```text
ENABLE_SIMPLE_HSHRINK = 1
ENABLE_BBOX           = 0 or debug only
ENABLE_CENTERING      = 0
ENABLE_ADV_RESIZE     = 0
```

## 9. NN_MODEL_SELECT Register

Offset: `0x38`

| Value | Model                                    |
| ----: | ---------------------------------------- |
|   `0` | default model, `1024 -> 64 -> 36`        |
|   `1` | accuracy model, `1024 -> 96 -> 48 -> 36` |

## 10. DSP_CONFIG Register

Offset: `0x40`

| Bit Field | Name                 | Description                                             |
| --------: | -------------------- | ------------------------------------------------------- |
|   `[3:0]` | `NUM_MULTADDALU`     | expected value: `12`                                    |
|   `[7:4]` | `PRODUCTS_PER_CYCLE` | expected encoded value: `24` or implementation-specific |
|     `[8]` | `USE_PIPELINE_REG`   | enable DSP pipeline registers where implemented         |
|     `[9]` | `SIGNED_MODE`        | signed int8 weight/activation mode                      |
|    `[10]` | `ACC_INT32_MODE`     | use int32 architectural accumulator                     |
| `[15:11]` | reserved             | reserved                                                |

## 11. Raw Image Buffer

Base: `0x0000_0100`
Size: `256 bytes`

Format:

```text
row0  : 8 bytes
row1  : 8 bytes
...
row31 : 8 bytes
```

Recommended bit order:

```text
byte_index = y * 8 + (x >> 3)
bit_index  = x[2:0]
pixel      = raw_image[byte_index][bit_index]
```

The bit order must be fixed and mirrored in the host-side tool.

## 12. Preprocessed Binary Buffer

Base: `0x0000_0200`
Size: `128 bytes`

Format:

```text
32 x 32 x 1bpp = 1024 bits = 128 bytes
```

This buffer stores the binary output of the preprocessor.

## 13. Feature Buffer

Base: `0x0000_0400`
Size: `1024 bytes`

Format:

```text
feature[0]     = pixel(0, 0), int8 value 0 or 1
feature[1]     = pixel(1, 0)
...
feature[31]    = pixel(31, 0)
feature[32]    = pixel(0, 1)
...
feature[1023]  = pixel(31, 31)
```

The feature buffer may be generated from the preprocessed binary buffer or generated directly by the preprocessor.

## 14. Model Mirror Region

Base: `0x0000_1000`
Size: `128 KiB`

This region mirrors the EEPROM model image. It may contain:

```text
0x0000 : model header
0x0100 : layer table
0x0200 : quantization table
...    : int8 weights
...    : int32 biases
...    : class labels
...    : CRC/checksum
```

The exact model image format is defined by the model packer and model loader.

## 15. Runtime Weight Region

Base: `0x0002_1000`

This region stores decoded or directly usable int8 weights. If the EEPROM image already stores weights in runtime layout, this region may alias the model mirror region.

Recommended layout for default model:

```text
W0: 64 x 1024 int8
W1: 36 x 64 int8
```

Recommended layout for accuracy model:

```text
W0: 96 x 1024 int8
W1: 48 x 96 int8
W2: 36 x 48 int8
```

Neuron-major layout is recommended for the current DSP group-parallel architecture:

```text
weight[layer][output_neuron][input_index]
```

## 16. Runtime Bias Region

Base: `0x0004_0000`

Bias format: `int32`.

Recommended layout:

```text
B0: output_count_layer0 x int32
B1: output_count_layer1 x int32
B2: output_count_layer2 x int32, accuracy model only
```

## 17. Activation Buffers

Base: `0x0004_4000`

Recommended ping-pong layout:

```text
ACT_A: 2048 bytes
ACT_B: 2048 bytes
```

The default model needs:

```text
input  : 1024 int8 features
hidden : 64 int8 activations
output : 36 int32 logits
```

The accuracy model needs:

```text
input   : 1024 int8 features
hidden0 : 96 int8 activations
hidden1 : 48 int8 activations
output  : 36 int32 logits
```

## 18. Score Buffer

Base: `0x0004_8000`

Format:

```text
score[0]  : int32 logit for class 0
score[1]  : int32 logit for class 1
...
score[35] : int32 logit for class 35
```

## 19. OLED Control

### OLED_CTRL Register

Offset: `0x80`

| Bit | Name              | Description                                      |
| --: | ----------------- | ------------------------------------------------ |
| `0` | `DISPLAY_RAW`     | display raw image                                |
| `1` | `DISPLAY_RESULT`  | display result text                              |
| `2` | `AUTO_TOGGLE`     | alternate raw image and result                   |
| `3` | `FORCE_REFRESH`   | force OLED refresh                               |
| `4` | `DISPLAY_PREPROC` | display preprocessed 32x32 image, scaled to OLED |

Recommended display modes:

```text
0: raw image, 64x32 horizontally expanded to 128x32
1: result text
2: auto-toggle raw/result
3: preprocessed image view for debug
```

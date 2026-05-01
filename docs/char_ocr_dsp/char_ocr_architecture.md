# Character OCR Architecture Specification

## 1. Purpose

This document defines the architecture of a single-character OCR accelerator implemented on a TangNano20K FPGA.

The accelerator receives a `64 x 32`, 1 bpp binary character image from a host PC through UART, preprocesses it into a `32 x 32` feature map, executes a quantized neural-network inference engine on FPGA, and displays the raw input image and recognized character on a `128 x 32` OLED display.

## 2. Finalized Target Configuration

| Item                 |                             Value |
| -------------------- | --------------------------------: |
| Input image          |                  `64 x 32`, 1 bpp |
| Preprocessor output  |                         `32 x 32` |
| Feature vector       |                   `1024` features |
| Feature format       |          `int8`, value `0` or `1` |
| Default network      |                `1024 -> 64 -> 36` |
| Accuracy model       |          `1024 -> 96 -> 48 -> 36` |
| DSP array            |            `12 x MULTADDALU18X18` |
| Effective throughput |               `24 products/cycle` |
| Weight format        |                            `int8` |
| Bias format          |                           `int32` |
| Activation           |      `ReLU + int8 requantization` |
| EEPROM               |             `1024 Kbit / 128 KiB` |
| Runtime SRAM         | approximately `60 Mbit` available |

## 3. Scope

This specification covers:

- System partitioning between host PC and FPGA
- OCR target definition
- Preprocessing architecture
- Neural-network inference architecture
- DSP compute architecture
- EEPROM model storage and boot-time loading
- Runtime SRAM layout assumptions
- OLED display behavior
- Runtime update and debug capability

This specification does not define:

- Host GUI implementation details
- Training script implementation details
- PCB-level electrical design
- Exact OCR dataset format
- Final timing-closure constraints

## 4. System Goals

- Recognize one character at a time.
- Support `36` classes: `0-9` and `A-Z`.
- Use a `64 x 32`, 1 bpp binary image input.
- Normalize the input into a `32 x 32` neural-network feature image.
- Perform inference entirely on FPGA.
- Store trained model parameters in external I2C EEPROM.
- Load model parameters into runtime SRAM at FPGA boot.
- Allow host overwrite of image and model memory for debug and evaluation.
- Display the raw image and OCR result on the OLED.

## 5. OCR Target Definition

### 5.1 Recognition Classes

The recognized classes are:

- Digits: `0` to `9`
- Uppercase letters: `A` to `Z`

Total number of classes: `36`.

Recommended class index mapping:

```text
0  - 9   : '0' - '9'
10 - 35  : 'A' - 'Z'
```

### 5.2 Input Assumptions

The first implementation assumes:

- Single character only.
- Binary foreground/background image.
- Foreground pixel value is `1`.
- Background pixel value is `0`.
- Character is reasonably centered or separable by a simple bounding box.
- No multi-character segmentation in hardware.
- No rotation correction in the first revision.

## 6. System Partitioning

### 6.1 Host PC Responsibilities

The host PC is responsible for:

- Dataset generation and labeling.
- Training the OCR neural network.
- Quantization of weights, biases, activations, and per-layer scaling parameters.
- Packing model data into the EEPROM image format.
- Sending OCR input images through UART.
- Reading OCR results, confidence values, and debug information.
- Optionally overwriting runtime model memory for evaluation.

### 6.2 FPGA Responsibilities

The FPGA is responsible for:

- UART command reception and response.
- Runtime SRAM access control.
- EEPROM model loading at boot.
- Image preprocessing from `64 x 32` to `32 x 32`.
- Quantized neural-network inference.
- Argmax and confidence calculation.
- OLED update and display control.

## 7. Input Image Architecture

### 7.1 Raw Image Format

| Field        |                     Value |
| ------------ | ------------------------: |
| Width        |               `64` pixels |
| Height       |               `32` pixels |
| Pixel format | binary, `1 bit per pixel` |
| Total pixels |                    `2048` |
| Total size   |               `256 bytes` |

Recommended layout:

```text
row0  : 8 bytes, x = 0..63
row1  : 8 bytes
...
row31 : 8 bytes
```

### 7.2 Pixel Convention

- `0`: background
- `1`: foreground / character stroke

The same convention must be used by:

- host-side training preprocessing,
- FPGA preprocessing,
- inference input generation,
- OLED raw image display.

## 8. Preprocessing Architecture

### 8.1 Purpose

The preprocessing unit converts the raw `64 x 32` binary image into a normalized `32 x 32` feature map.

The `32 x 32` size is selected because OCR accuracy can be sensitive to vertical detail. Compared with a `32 x 16` feature map, preserving 32 vertical pixels helps distinguish visually similar characters such as `B/8`, `O/0`, `S/5`, `Z/2`, `I/1`, and `G/6`.

### 8.2 Required Output

| Item           |                    Value |
| -------------- | -----------------------: |
| Output width   |                     `32` |
| Output height  |                     `32` |
| Feature count  |                   `1024` |
| Feature format | `int8`, value `0` or `1` |

### 8.3 First-Revision Preprocessing Mode

The recommended first-revision preprocessing is simple horizontal reduction:

```text
out[y][x] = in[y][2*x] OR in[y][2*x + 1]
```

where:

```text
0 <= x < 32
0 <= y < 32
```

This preserves the original vertical resolution and halves only the horizontal resolution.

### 8.4 Optional Advanced Preprocessing Mode

A later revision may add:

1. Bounding box detection.
2. Character crop extraction.
3. Center alignment.
4. Scale normalization into `32 x 32`.

The first revision should keep the preprocessing deterministic and easy to match in Python.

### 8.5 Empty Image Behavior

If no active pixels are detected in advanced preprocessing mode:

- set `STATUS.EMPTY_IMAGE`,
- skip inference or force a reserved invalid result,
- optionally display `EMPTY` on OLED.

In simple horizontal reduction mode, empty image detection can be implemented as a foreground OR-reduction over the raw input image.

## 9. Neural Network Architecture

### 9.1 Default Network

The default model is:

```text
1024 -> 64 -> 36
```

Layer definition:

| Layer | Input | Output | Activation                 |
| ----- | ----: | -----: | -------------------------- |
| FC0   |  1024 |     64 | ReLU + int8 requantization |
| FC1   |    64 |     36 | none, raw logits           |

Weight count:

```text
1024 x 64 = 65,536
64 x 36   =  2,304
Total     = 67,840 int8 weights
```

Bias count:

```text
64 + 36 = 100 int32 biases
```

Approximate model size:

```text
weights : 67,840 bytes
biases  :    400 bytes
header  : implementation-dependent
```

This model comfortably fits in a `128 KiB` EEPROM.

### 9.2 Accuracy Model

The accuracy model is:

```text
1024 -> 96 -> 48 -> 36
```

Layer definition:

| Layer | Input | Output | Activation                 |
| ----- | ----: | -----: | -------------------------- |
| FC0   |  1024 |     96 | ReLU + int8 requantization |
| FC1   |    96 |     48 | ReLU + int8 requantization |
| FC2   |    48 |     36 | none, raw logits           |

Weight count:

```text
1024 x 96 = 98,304
96 x 48   =  4,608
48 x 36   =  1,728
Total     =104,640 int8 weights
```

Bias count:

```text
96 + 48 + 36 = 180 int32 biases
```

Approximate model size:

```text
weights : 104,640 bytes
biases  :     720 bytes
header  : implementation-dependent
```

This model is expected to fit in `128 KiB` EEPROM if the model header and quantization table are kept compact.

### 9.3 Quantization

Recommended quantization:

| Tensor             | Format                               |
| ------------------ | ------------------------------------ |
| Input feature      | `int8`, value `0` or `1`             |
| Weight             | `int8`                               |
| Bias               | `int32`                              |
| Accumulator        | `int32`                              |
| Hidden activation  | `int8` after ReLU and requantization |
| Output score/logit | `int32`                              |

### 9.4 Activation Function

Hidden layers use:

```text
ReLU(x) = max(0, x)
```

Then the result is requantized to `int8` for the next layer.

The output layer produces raw `int32` logits. Hardware softmax is not required.

### 9.5 Confidence Metric

Recommended confidence metric:

```text
confidence_gap = best_score - second_best_score
```

This avoids implementing expensive exponential or division operations for softmax.

## 10. DSP Inference Engine Architecture

### 10.1 DSP Array

The inference engine uses:

```text
12 x MULTADDALU18X18
```

Each `MULTADDALU18X18` processes two signed 18-bit by 18-bit products and contributes to accumulation. The OCR engine uses sign-extended `int8` activation and `int8` weight values as DSP inputs.

Effective throughput:

```text
12 units x 2 products/unit/cycle = 24 products/cycle
```

### 10.2 Accumulation

Each output neuron computes:

```text
sum = bias[o] + Σ input[i] * weight[o][i]
```

The accumulation result is represented as `int32` in the OCR architecture.

### 10.3 Parallelization Strategy

The recommended strategy is neuron-group parallelism.

For one input index `i`, the same activation value `input[i]` is broadcast to multiple output neurons. A group of up to 24 output-neuron weights can be processed per cycle.

Conceptual operation:

```text
for each output neuron group G:
    clear accumulators for neurons in G
    for i in 0 .. input_size-1:
        read activation[i]
        read weights[G][i]
        compute 24 products/cycle
        accumulate partial sums
    add bias
    apply activation or output logits
```

### 10.4 Cycle Estimates

#### Default Network: `1024 -> 64 -> 36`

MAC count:

```text
1024 x 64 = 65,536
64 x 36   =  2,304
Total     = 67,840 MACs
```

MAC-only cycle estimate:

```text
67,840 / 24 = 2,827 cycles approximately
```

Neuron-group estimate:

```text
FC0: 1024 x ceil(64 / 24) = 1024 x 3 = 3072 cycles
FC1:   64 x ceil(36 / 24) =   64 x 2 =  128 cycles
Total: approximately 3200 cycles plus overhead
```

The neuron-group estimate is more realistic for this architecture.

#### Accuracy Model: `1024 -> 96 -> 48 -> 36`

MAC count:

```text
1024 x 96 = 98,304
96 x 48   =  4,608
48 x 36   =  1,728
Total     =104,640 MACs
```

MAC-only cycle estimate:

```text
104,640 / 24 = 4,360 cycles
```

Neuron-group estimate:

```text
FC0: 1024 x ceil(96 / 24) = 1024 x 4 = 4096 cycles
FC1:   96 x ceil(48 / 24) =   96 x 2 =  192 cycles
FC2:   48 x ceil(36 / 24) =   48 x 2 =   96 cycles
Total: approximately 4384 cycles plus overhead
```

## 11. EEPROM Model Storage

### 11.1 Capacity

External EEPROM capacity:

```text
1024 Kbit = 1,048,576 bits = 131,072 bytes = 128 KiB
```

### 11.2 Model Image Contents

Recommended EEPROM model image:

```text
Model header
Layer configuration table
Quantization parameters
Weights, int8
Biases, int32
Class label table
CRC or checksum
Reserved area
```

### 11.3 Boot Sequence

```text
FPGA reset
  -> EEPROM loader starts
  -> read model header
  -> validate magic/version/CRC
  -> copy model payload to runtime SRAM
  -> set MODEL_READY
  -> OCR engine becomes available
```

## 12. Runtime SRAM Usage

Runtime SRAM available:

```text
approximately 60 Mbit ≈ 7.5 MB
```

The OCR design only requires a small fraction of this capacity. SRAM should hold:

- raw image buffer,
- preprocessed feature buffer,
- model parameter region,
- activation buffers,
- score buffer,
- debug trace area.

The model region should reserve at least `128 KiB` to mirror a full EEPROM model image.

## 13. OLED Display Architecture

### 13.1 Raw Image Display

The raw `64 x 32` image can be displayed on the `128 x 32` OLED by horizontal 2x expansion:

```text
OLED pixel[2*x,   y] = raw_pixel[x, y]
OLED pixel[2*x+1, y] = raw_pixel[x, y]
```

### 13.2 Result Display

The result screen should display:

- recognized character,
- class index,
- best score or confidence gap,
- optional model ID.

### 13.3 Auto-Toggle Display

Recommended auto-toggle mode:

```text
1 second : raw image display
1 second : OCR result display
repeat
```

## 14. Runtime Update Capability

The host PC shall be able to:

- write the raw image buffer,
- read the raw image buffer,
- run preprocessing only,
- run OCR inference,
- read scores and result registers,
- overwrite runtime model memory,
- optionally program EEPROM through FPGA command flow.

## 15. Recommended Development Phases

### Phase 1: Default Model Bring-Up

```text
Preprocessor : 64x32 -> 32x32 simple horizontal reduction
Network      : 1024 -> 64 -> 36
DSP array    : 12 x MULTADDALU18X18
```

### Phase 2: Accuracy Model

```text
Network      : 1024 -> 96 -> 48 -> 36
```

### Phase 3: Advanced Preprocessing

```text
bbox detection + centering + 32x32 normalization
```

### Phase 4: Optional CNN Exploration

After MLP functionality is stable, a small CNN may be considered, but it is not part of the current baseline architecture.

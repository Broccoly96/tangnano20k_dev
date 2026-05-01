# Character OCR DSP Compute Architecture

## 1. Purpose

This document defines the DSP compute architecture for the Character OCR accelerator.

The neural-network inference engine is implemented as a quantized MLP accelerator using Gowin DSP blocks. The baseline compute array uses `12 x MULTADDALU18X18`, providing an effective throughput of `24 products/cycle`.

## 2. Finalized OCR Compute Configuration

```text
Input image         : 64 x 32, 1 bpp
Preprocessor output : 32 x 32
Feature vector      : 1024 features
Feature format      : int8, value 0 or 1
Default network     : 1024 -> 64 -> 36
Accuracy model      : 1024 -> 96 -> 48 -> 36
DSP array           : 12 x MULTADDALU18X18
Throughput          : 24 products/cycle
Weight format       : int8
Bias format         : int32
Activation          : ReLU + int8 requantization
EEPROM              : 1024 Kbit / 128 KiB
Runtime SRAM        : approximately 60 Mbit available
```

## 3. DSP Primitive Usage

The compute engine targets `MULTADDALU18X18`.

Conceptually, each `MULTADDALU18X18` handles two 18-bit by 18-bit multiplication paths and supports accumulation/reload behavior. The OCR design maps two int8 products into one DSP unit after sign extension to the DSP input width.

```text
One MULTADDALU18X18 unit:
  product0 = A0 * B0
  product1 = A1 * B1
  accumulation contribution = product0 + product1
```

OCR mapping:

```text
A0/A1 : sign-extended activation value
B0/B1 : sign-extended weight value
```

For the selected 12-unit array:

```text
12 MULTADDALU18X18 units x 2 products/unit/cycle
= 24 products/cycle
```

## 4. Numeric Format

| Signal            | Format                            | Notes                                  |
| ----------------- | --------------------------------- | -------------------------------------- |
| Input feature     | `int8`                            | value `0` or `1`                       |
| Hidden activation | `int8`                            | output of ReLU + requantization        |
| Weight            | `int8`                            | signed quantized weight                |
| Bias              | `int32`                           | signed bias, per output neuron         |
| Product           | signed internal product           | int8 x int8 sign-extended into DSP     |
| Accumulator       | `int32` architectural accumulator | one accumulator per active output lane |
| Output logit      | `int32`                           | final layer raw score                  |

## 5. Supported Model Profiles

## 5.1 Default Model

```text
1024 -> 64 -> 36
```

Layer list:

| Layer | Input Count | Output Count | Activation                 |
| ----- | ----------: | -----------: | -------------------------- |
| FC0   |        1024 |           64 | ReLU + int8 requantization |
| FC1   |          64 |           36 | none, int32 logits         |

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

## 5.2 Accuracy Model

```text
1024 -> 96 -> 48 -> 36
```

Layer list:

| Layer | Input Count | Output Count | Activation                 |
| ----- | ----------: | -----------: | -------------------------- |
| FC0   |        1024 |           96 | ReLU + int8 requantization |
| FC1   |          96 |           48 | ReLU + int8 requantization |
| FC2   |          48 |           36 | none, int32 logits         |

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

## 6. Compute Parallelization Strategy

The recommended execution strategy is output-neuron group parallelism.

For one input activation value, up to 24 output-neuron weights are processed in parallel.

```text
for each output neuron group G of up to 24 neurons:
    acc[G] = bias[G]

    for i in 0 .. input_count-1:
        a = activation[i]
        w[0..23] = weights[G][i]
        acc[0..23] += a * w[0..23]

    postprocess acc[G]
```

This strategy reduces activation memory bandwidth because `activation[i]` is broadcast to all active lanes.

The main memory bandwidth pressure is therefore the weight fetch bandwidth:

```text
up to 24 int8 weights per cycle
```

The weight memory should be arranged or cached to support this access pattern.

## 7. DSP Lane Mapping

```text
DSP unit 0  : lane 0,  lane 1
DSP unit 1  : lane 2,  lane 3
DSP unit 2  : lane 4,  lane 5
...
DSP unit 11 : lane 22, lane 23
```

For each DSP unit `k`:

```text
lane_a = 2*k
lane_b = 2*k + 1

A0 = sign_extend_18(activation)
B0 = sign_extend_18(weight[lane_a])
A1 = sign_extend_18(activation)
B1 = sign_extend_18(weight[lane_b])
```

The architectural accumulator remains logically separate per lane. If the DSP primitive is used in a mode that returns a combined product sum, external demultiplexed accumulation or a two-phase schedule may be required depending on the exact primitive instantiation constraints. The implementation should choose the primitive mode and wrapper structure so that 24 independent output-neuron partial sums are maintained.

## 8. Layer Execution Sequence

For each layer:

```text
1. Load input_count and output_count.
2. Select input activation buffer.
3. Select output activation or score buffer.
4. For each output group of up to 24 neurons:
   a. Load bias values into 24 accumulators.
   b. For each input index:
      - read one activation
      - read up to 24 weights
      - execute DSP products
      - update accumulators
   c. If hidden layer:
      - apply ReLU
      - requantize to int8
      - write output activation
   d. If output layer:
      - write int32 logits
5. Continue to next layer or argmax.
```

## 9. Cycle Estimates

## 9.1 Default Model: `1024 -> 64 -> 36`

### MAC Count

```text
FC0: 1024 x 64 = 65,536
FC1:   64 x 36 =  2,304
Total          = 67,840 MACs
```

### Theoretical MAC-Only Cycles

```text
67,840 / 24 = 2,827 cycles approximately
```

### Neuron-Group Cycles

```text
FC0: 1024 x ceil(64 / 24)
    = 1024 x 3
    = 3072 cycles

FC1: 64 x ceil(36 / 24)
    = 64 x 2
    = 128 cycles

Total = 3200 cycles plus overhead
```

## 9.2 Accuracy Model: `1024 -> 96 -> 48 -> 36`

### MAC Count

```text
FC0: 1024 x 96 = 98,304
FC1:   96 x 48 =  4,608
FC2:   48 x 36 =  1,728
Total          =104,640 MACs
```

### Theoretical MAC-Only Cycles

```text
104,640 / 24 = 4,360 cycles
```

### Neuron-Group Cycles

```text
FC0: 1024 x ceil(96 / 24)
    = 1024 x 4
    = 4096 cycles

FC1: 96 x ceil(48 / 24)
    = 96 x 2
    = 192 cycles

FC2: 48 x ceil(36 / 24)
    = 48 x 2
    = 96 cycles

Total = 4384 cycles plus overhead
```

## 10. ReLU and Requantization

For hidden layers:

```text
acc32 = bias + sum(input * weight)
relu32 = max(0, acc32)
act8 = clamp_to_int8((relu32 * scale + rounding) >> shift)
```

Recommended quantization parameters per layer:

```text
requant_multiplier : int32 or fixed-point constant
requant_shift      : unsigned shift value
activation_zero    : normally 0 for ReLU path
```

The first revision may simplify this to:

```text
act8 = clamp_to_int8(relu32 >> shift)
```

provided the training/quantization flow matches this hardware behavior.

## 11. Memory Access Pattern

Recommended weight layout:

```text
weight[layer][output_neuron][input_index]
```

For group-parallel execution, the hardware reads weights for multiple output neurons at the same input index:

```text
weight[group_base + 0][i]
weight[group_base + 1][i]
...
weight[group_base + 23][i]
```

If the runtime SRAM cannot provide 24 byte-wide reads per cycle directly, use one of the following:

1. Wider packed weight words.
2. Local weight cache per output group.
3. Multi-cycle fetch followed by DSP burst compute.
4. Reduced active lane count.

## 12. Recommended Bring-Up Strategy

### Step 1: Functional DSP Wrapper Test

- Instantiate one `MULTADDALU18X18` wrapper.
- Verify signed int8 multiplication behavior after sign extension.
- Compare against Python reference.

### Step 2: 12-Unit Array Test

- Instantiate 12 wrappers.
- Drive synthetic activation and 24 weights.
- Verify 24-lane product generation and accumulation.

### Step 3: Default Model

- Run `1024 -> 64 -> 36`.
- Validate logits against Python fixed-point reference.

### Step 4: Accuracy Model

- Run `1024 -> 96 -> 48 -> 36`.
- Validate all intermediate activations and final logits.

### Step 5: Performance Counters

- Enable `DSP_CYCLES_TOTAL`.
- Enable per-layer cycle counters.
- Compare actual cycles against expected group-cycle estimates.

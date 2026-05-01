# Character OCR Accelerator Block Diagram

## 1. Target Configuration

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

## 2. Top-Level Block Diagram

```text
+--------------------------------------------------------------------------------------------------+
|                                      Host PC                                                     |
|--------------------------------------------------------------------------------------------------|
|  Training / Quantization / Model Packing                                                         |
|  Test Image Generation / UART Command Tool / Result Visualization                                |
+---------------------------------------------------+----------------------------------------------+
                                                    |
                                                    | Wi-Fi UART
                                                    v
+---------------------------------------------------------------------------------------------------+
|                                      TangNano20K FPGA                                             |
|---------------------------------------------------------------------------------------------------|
|                                                                                                   |
|  +--------------------+       +----------------------+       +-------------------------------+    |
|  | UART RX/TX         |<----->| Command Decoder      |<----->| Control / Status Registers    |    |
|  | Wi-Fi bridge side  |       | Packet Parser        |       | OCR control and debug         |    |
|  +---------+----------+       +----------+-----------+       +---------------+---------------+    |
|            |                             |                                   |                    |
|            |                             v                                   v                    |
|            |                  +----------------------+        +-----------------------------+     |
|            +----------------->| Runtime SRAM Arbiter |<------>| EEPROM Loader               |     |
|                               | Image / Model / Work |        | Boot-time model copy        |     |
|                               +----------+-----------+        +-------------+---------------+     |
|                                          |                                  |                     |
|                                          |                                  | I2C                 |
|                                          v                                  v                     |
|                               +----------------------+        +-----------------------------+     |
|                               | Runtime SRAM Map     |        | External I2C EEPROM         |     |
|                               | ~60 Mbit available   |        | 1024 Kbit / 128 KiB         |     |
|                               +----------+-----------+        +-----------------------------+     |
|                                          |                                                        |
|               +--------------------------+----------------------------+                           |
|               |                                                       |                           |
|               v                                                       v                           |
|  +---------------------------+                         +------------------------------+           |
|  | Raw Image Buffer          |                         | Model Parameter Buffers      |           |
|  | 64 x 32 x 1 bpp           |                         | int8 weights / int32 bias    |           |
|  | 256 bytes                 |                         | default or accuracy model    |           |
|  +-------------+-------------+                         +---------------+--------------+           |
|                |                                                               |                  |
|                v                                                               |                  |
|  +---------------------------+                                                 |                  |
|  | Preprocessor              |                                                 |                  |
|  | - optional bbox detection |                                                 |                  |
|  | - 64x32 -> 32x32 resize   |                                                 |                  |
|  | - binary to int8 feature  |                                                 |                  |
|  +-------------+-------------+                                                 |                  |
|                |                                                               |                  |
|                v                                                               |                  |
|  +---------------------------+                                                 |                  |
|  | Feature Buffer            |                                                 |                  |
|  | 32 x 32 = 1024 features   |                                                 |                  |
|  | int8, value 0 or 1        |                                                 |                  |
|  +-------------+-------------+                                                 |                  |
|                |                                                               |                  |
|                +-----------------------+---------------------------------------+                  |
|                                        |                                                          |
|                                        v                                                          |
|  +--------------------------------------------------------------------------------------------+   |
|  | Neural Network Inference Engine                                                            |   |
|  |--------------------------------------------------------------------------------------------|   |
|  |  Layer Scheduler                                                                           |   |
|  |    - default model:  1024 -> 64 -> 36                                                      |   |
|  |    - accuracy model: 1024 -> 96 -> 48 -> 36                                                |   |
|  |                                                                                            |   |
|  |  DSP Compute Array                                                                         |   |
|  |    - 12 x MULTADDALU18X18                                                                  |   |
|  |    - each unit computes 2 signed 18x18 products per cycle                                  |   |
|  |    - total throughput: 24 int8 products/cycle after sign extension                         |   |
|  |                                                                                            |   |
|  |  Accumulator / Bias / ReLU / Requantization                                                |   |
|  |    - int32 accumulation                                                                    |   |
|  |    - int32 bias add                                                                        |   |
|  |    - ReLU for hidden layers                                                                |   |
|  |    - int8 requantization for next-layer activation                                         |   |
|  +--------------------------------------+-----------------------------------------------------+   |
|                                         |                                                         |
|                                         v                                                         |
|  +---------------------------+    +---------------------------+     +-------------------------+   |
|  | Score Buffer              |--->| Argmax / Confidence Unit  |---->| Result Registers        |   |
|  | int32 x 36 logits         |    | best / second-best score  |     | class / score / conf    |   |
|  +---------------------------+    +-------------+-------------+     +-----------+-------------+   |
|                                                  |                               |                |
|                                                  v                               v                |
|                                        +-------------------+        +------------------------+    |
|                                        | OLED Display FSM  |<------>| Font / Image Renderer  |    |
|                                        | alternate display |        | raw image / result text|    |
|                                        +---------+---------+        +------------------------+    |
|                                                  |                                                |
|                                                  | I2C                                            |
|                                                  v                                                |
|                                        +-------------------+                                      |
|                                        | 128 x 32 OLED     |                                      |
|                                        +-------------------+                                      |
|                                                                                                   |
+---------------------------------------------------------------------------------------------------+
```

## 3. Runtime Data Path

```text
Host PC
  -> UART
  -> Raw image buffer, 64x32 binary
  -> Preprocessor, 64x32 to 32x32
  -> Feature buffer, 1024 x int8
  -> MLP inference engine
  -> Score buffer, 36 x int32
  -> Argmax / confidence
  -> OLED and UART result readback
```

## 4. Boot-Time Model Path

```text
External I2C EEPROM, 128 KiB
  -> EEPROM loader
  -> Runtime SRAM model region
  -> model header validation
  -> DSP inference engine ready
```

## 5. Display Path

```text
Raw image display mode:
  Raw image buffer, 64x32
    -> horizontal 2x expansion
    -> OLED 128x32

Result display mode:
  Result registers
    -> character label and confidence rendering
    -> OLED 128x32

Auto-toggle mode:
  raw image display <-> result display
```

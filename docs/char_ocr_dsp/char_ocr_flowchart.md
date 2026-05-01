# Character OCR Processing Flowchart

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
Activation          : ReLU + int8 requantization
EEPROM              : 1024 Kbit / 128 KiB
Runtime SRAM        : approximately 60 Mbit available
```

## 2. Boot Flow

```text
+-------------------+
| FPGA reset        |
+---------+---------+
          |
          v
+-------------------+
| Initialize clocks |
| and reset FSMs    |
+---------+---------+
          |
          v
+-----------------------------+
| Initialize UART / I2C / OLED |
+---------+-------------------+
          |
          v
+-----------------------------+
| Start EEPROM model loader   |
+---------+-------------------+
          |
          v
+-----------------------------+
| Read model header           |
+---------+-------------------+
          |
          v
+-----------------------------+
| Validate magic/version      |
+---------+-------------------+
          |
          v
+-----------------------------+
| Copy model image to SRAM    |
| model mirror region         |
+---------+-------------------+
          |
          v
+-----------------------------+
| Validate CRC/checksum       |
+----+-------------------+----+
     |                   |
     | pass              | fail
     v                   v
+----------------+   +-------------------+
| MODEL_READY=1  |   | ERROR_MODEL_CRC=1 |
+--------+-------+   +---------+---------+
         |                     |
         v                     v
+----------------+   +-------------------+
| OCR idle       |   | OCR idle, model   |
| ready          |   | unavailable       |
+----------------+   +-------------------+
```

## 3. Host Image Write Flow

```text
+----------------------+
| Host sends WRITE_IMG |
+----------+-----------+
           |
           v
+-----------------------------+
| UART command decoder checks |
| address and length          |
+----------+------------------+
           |
           v
+-----------------------------+
| Write 256 bytes to raw      |
| image buffer                |
+----------+------------------+
           |
           v
+-----------------------------+
| Optional readback / CRC     |
+----------+------------------+
           |
           v
+-----------------------------+
| Image ready for OCR         |
+-----------------------------+
```

## 4. Full OCR Flow

```text
+----------------------+
| Host sends RUN_OCR   |
+----------+-----------+
           |
           v
+-----------------------------+
| Check MODEL_READY           |
+-----+-------------------+---+
      |                   |
      | ready             | not ready
      v                   v
+-------------------+  +--------------------+
| Start preprocess  |  | Set ERROR_MODEL    |
+---------+---------+  +--------------------+
          |
          v
+-----------------------------+
| Convert 64x32 raw image     |
| to 32x32 feature map        |
+----------+------------------+
           |
           v
+-----------------------------+
| Store 1024 int8 features    |
| values 0 or 1               |
+----------+------------------+
           |
           v
+-----------------------------+
| Run neural network          |
| selected model              |
+----------+------------------+
           |
           v
+-----------------------------+
| Generate 36 int32 logits    |
+----------+------------------+
           |
           v
+-----------------------------+
| Argmax and confidence gap   |
+----------+------------------+
           |
           v
+-----------------------------+
| Update result registers     |
+----------+------------------+
           |
           v
+-----------------------------+
| Update OLED display         |
+----------+------------------+
           |
           v
+-----------------------------+
| Set OCR_DONE                |
+-----------------------------+
```

## 5. Preprocessing Flow

### 5.1 First-Revision Simple Horizontal Reduction

```text
+-----------------------------+
| Read raw image, 64x32       |
+-------------+---------------+
              |
              v
+-----------------------------+
| For y = 0..31               |
|   For x = 0..31             |
+-------------+---------------+
              |
              v
+-----------------------------+
| out[y][x] =                 |
|   in[y][2*x] OR             |
|   in[y][2*x + 1]            |
+-------------+---------------+
              |
              v
+-----------------------------+
| Pack 32x32 binary buffer    |
| and/or generate int8 vector |
+-------------+---------------+
              |
              v
+-----------------------------+
| feature[y*32+x] = 0 or 1    |
+-------------+---------------+
              |
              v
+-----------------------------+
| Set PREPROC_DONE            |
+-----------------------------+
```

### 5.2 Optional Advanced Preprocessing Flow

```text
+-----------------------------+
| Scan raw image              |
+-------------+---------------+
              |
              v
+-----------------------------+
| Detect bounding box         |
| x_min/x_max/y_min/y_max     |
+-------------+---------------+
              |
              v
+-----------------------------+
| Empty image?                |
+-------+---------------------+
        | yes                 | no
        v                     v
+----------------+     +----------------------+
| Set EMPTY_IMAGE|     | Crop character bbox  |
+----------------+     +----------+-----------+
                                  |
                                  v
                         +----------------------+
                         | Resize and center    |
                         | into 32x32           |
                         +----------+-----------+
                                  |
                                  v
                         +----------------------+
                         | Generate 1024 int8   |
                         | feature vector       |
                         +----------------------+
```

## 6. Neural Network Inference Flow

## 6.1 Model Selection

```text
NN_MODEL_SELECT = 0:
  default model
  1024 -> 64 -> 36

NN_MODEL_SELECT = 1:
  accuracy model
  1024 -> 96 -> 48 -> 36
```

## 6.2 Per-Layer Flow

```text
+-----------------------------+
| Select layer L              |
+-------------+---------------+
              |
              v
+-----------------------------+
| Load layer dimensions       |
| input_count, output_count   |
+-------------+---------------+
              |
              v
+-----------------------------+
| For output neuron group G   |
| group width <= 24           |
+-------------+---------------+
              |
              v
+-----------------------------+
| Initialize accumulators     |
| with int32 bias values      |
+-------------+---------------+
              |
              v
+-----------------------------+
| For each input index i      |
+-------------+---------------+
              |
              v
+-----------------------------+
| Broadcast activation[i]     |
| to 12 MULTADDALU units      |
+-------------+---------------+
              |
              v
+-----------------------------+
| Read up to 24 weights       |
| for output group G          |
+-------------+---------------+
              |
              v
+-----------------------------+
| Compute 24 products/cycle   |
| using 12 x MULTADDALU       |
+-------------+---------------+
              |
              v
+-----------------------------+
| Accumulate partial sums     |
+-------------+---------------+
              |
              v
+-----------------------------+
| End of input vector?        |
+-----+-----------------------+
      | no                    | yes
      v                       v
+-------------+        +-------------------------+
| Next input  |        | Apply activation if      |
| index       |        | hidden layer             |
+-------------+        +------------+------------+
                                      |
                                      v
                            +---------------------+
                            | Requantize to int8  |
                            | or store int32 logit|
                            +------------+--------+
                                         |
                                         v
                            +---------------------+
                            | Next neuron group   |
                            +------------+--------+
                                         |
                                         v
                            +---------------------+
                            | Next layer or done  |
                            +---------------------+
```

## 7. DSP Compute Inner Loop

For a group of up to 24 output neurons:

```text
for i in 0 .. input_count-1:
    a = activation[i]

    for lane in 0 .. 23:
        w[lane] = weight[group_base + lane][i]

    // implemented by 12 x MULTADDALU18X18
    product[lane] = a * w[lane]
    acc[lane] += product[lane]
```

The actual hardware maps two lanes into one `MULTADDALU18X18`.

```text
MULTADDALU unit k:
    lane0 = 2*k
    lane1 = 2*k + 1

    acc[lane0] += activation * weight[lane0]
    acc[lane1] += activation * weight[lane1]
```

## 8. Cycle Estimates

### 8.1 Default Model: `1024 -> 64 -> 36`

Neuron-group estimate:

```text
FC0: 1024 x ceil(64 / 24) = 1024 x 3 = 3072 cycles
FC1:   64 x ceil(36 / 24) =   64 x 2 =  128 cycles
Total: approximately 3200 cycles plus overhead
```

MAC-only estimate:

```text
(1024 x 64 + 64 x 36) / 24
= 67,840 / 24
= approximately 2,827 cycles
```

The neuron-group estimate is the preferred hardware estimate.

### 8.2 Accuracy Model: `1024 -> 96 -> 48 -> 36`

Neuron-group estimate:

```text
FC0: 1024 x ceil(96 / 24) = 1024 x 4 = 4096 cycles
FC1:   96 x ceil(48 / 24) =   96 x 2 =  192 cycles
FC2:   48 x ceil(36 / 24) =   48 x 2 =   96 cycles
Total: approximately 4384 cycles plus overhead
```

MAC-only estimate:

```text
(1024 x 96 + 96 x 48 + 48 x 36) / 24
= 104,640 / 24
= 4,360 cycles
```

## 9. Argmax Flow

```text
+-----------------------------+
| Read score[0..35]           |
+-------------+---------------+
              |
              v
+-----------------------------+
| Track best score and index  |
+-------------+---------------+
              |
              v
+-----------------------------+
| Track second-best score     |
+-------------+---------------+
              |
              v
+-----------------------------+
| confidence_gap =            |
| best - second_best          |
+-------------+---------------+
              |
              v
+-----------------------------+
| Convert class index to char |
+-------------+---------------+
              |
              v
+-----------------------------+
| Update result registers     |
+-----------------------------+
```

## 10. OLED Display Flow

```text
+-----------------------------+
| OLED display timer event    |
+-------------+---------------+
              |
              v
+-----------------------------+
| AUTO_TOGGLE enabled?        |
+------+----------------------+
       | yes                  | no
       v                      v
+---------------------+   +----------------------+
| Switch display mode |   | Keep selected mode   |
+----------+----------+   +----------+-----------+
           |                         |
           v                         v
+-----------------------------+
| Mode = raw image?           |
+------+----------------------+
       | yes                  | no
       v                      v
+---------------------+   +----------------------+
| Render 64x32 image  |   | Render result text   |
| as 128x32 by x2     |   | char/conf/model ID   |
+----------+----------+   +----------+-----------+
           |                         |
           v                         v
+-----------------------------+
| Send framebuffer to OLED    |
| through I2C                 |
+-----------------------------+
```

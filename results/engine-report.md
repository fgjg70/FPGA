

### 0.7 T-accel-R5：W 读跨模块流水（W_RD_LAT=2）落根

**目标**：125MHz 全实现差 −0.077ns，worst path 为 `u_eng/wa_r → 根 nn_mem BRAM ADDRARDADDR`
（data 8.98ns、route 95%+：engine 与 BRAM 物理距离远）。把 W 读在 nn_mem 边界打一拍，
长走线从中间切开（engine→中间寄存器 + 寄存器→BRAM 两段）。

**接口/参数**：
- `nn_conv_engine` 新增参数 **`W_RD_LAT`（根目录默认 = 2）**：=2 时 MAC 流水 +1 级
  （`a_pipe1` 中间级、`wby_r` 在 mac_v2 采 `w_rdata`、prod mac_v3、acc mac_v4、**DRN=4**）；
  =1 保留旧 mem 兼容（旧行为）。
- 根 `nn_mem` 由 t-mem 改 W 读输入寄存（`w_re_q/w_addr_q`，W 读 1→2 拍），端口/参数不变。

**周期公式**：**DRN = W_RD_LAT + 2**（`proto/engine/calc_cycles_v3.py`），其余项不变。

**验证**：
| 组合 | 结果 |
|---|---|
| 根引擎(WLAT2) + t-mem `nn_mem_wpipe`（联合） | 47/47 + 4/4 PASS, mismatch=0 |
| 根引擎(WLAT1) + 旧 nn_mem | 47/47 PASS（现网兼容） |

- 周期：47+4 总 191,283 → **192,100（Δ+817）**；**C128 全模型 1,177,320 → 1,191,020 拍（+1.16%）**；
  DRN=4 下逐 case 公式精确（bad=0）。
- 方向性 OOC @8ns（engine+mem RTL 综合）：WNS **+1.531 MET**，W 地址跨模块路径已不在 worst 名单
  （最差变为 `p3_row→blk_base`）；资源数请以 t-mem 的 no-clock DCP 黑盒口径为准。

**根目录文件 sha256**（2026-11-02）：
- `nn_conv_engine.sv` = `0cb981855ffbb7ff0bef7b5e7814db2c31b3e2cd5cdcbf1b394178b2e188374d`
- `sim/tb_nn_engine.sv` = `ce574de04c323d8121ae4cb91bf525b55911f16f735fc0ccc8bca6b85ddbb0b9`
  （LAT2 + 真根 `nn_mem`(wpipe)；根 `nn_mem.sv` sha `0da19bf0…` 由 t-mem 提供）

**根目录联合回归**：`verify --only tb_nn_engine --force` → **PASS 3.6s**（47 case，含 l0 全尺寸 replay）；
proto 侧训练集（vec 47 + vec_v3extra 4）= **47/47 + 4/4 PASS, mismatch=0**（LAT2 + 根 wpipe mem）。
LAT1 兼容模式（`W_RD_LAT=1` + 旧 mem）47/47 PASS。

# archive/ 归档目录说明

| 子目录 | 内容 | 说明 |
|---|---|---|
| `legacy/` | 最初的 Verilog 单周期设计（ALU/Branch/Control/PC/Regfile/imm） | 原根目录 `legacy/`，历史留档 |
| `pds/` | 旧 PGL22G/PDS 实验工程（`impl.tcl`、`top_pgl22g.sv` 等） | 原根目录 `fpga_pds/`，无构建依赖 |

另外，原 `releases/cpu50mhz/`（2026-11-02 的 CPU/NPU 50 MHz 完整源码基线快照，384 文件/9.2MB）已从 `main` 树中删除以缩减仓库体积，其内容完整保留在 commit **`f07836d`** 中：

```powershell
git show f07836d -- releases/cpu50mhz
# 或取回：
git checkout f07836d -- releases/cpu50mhz
```

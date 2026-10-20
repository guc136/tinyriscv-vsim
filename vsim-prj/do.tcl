# =============================================================================
# tinyriscv ModelSim 自动化仿真脚本
# -----------------------------------------------------------------------------
# 功能：
#   1. 自动清理并重建 work 库
#   2. 自动编译 ../rtl/*/*.v (CPU core / perips / soc / debug / utils)
#   3. 自动编译 ../tb/*.v (testbench)
#   4. 自动加载顶层并添加 CPU IO / 总线 / 流水线信号波形
#   5. 自动运行仿真（默认 500us，覆盖 tb 中的超时时间）
#
# 使用方法：
#   批处理模式（无界面，自动跑完退出）：
#       cd vsim-prj
#       vsim -c -do do.tcl
#
#   GUI 模式（打开波形窗口，仿真结束后停留以便查看）：
#       cd vsim-prj
#       vsim -do do.tcl
#   或在已打开的 ModelSim 中：
#       do do.tcl
#
# 注意：
#   tb 中通过 $readmemh("../sim/inst.data", ...) 加载程序，
#   因此必须在 vsim-prj 目录下运行（脚本会检查当前目录）。
#   重新生成 inst.data：python ../sim/sim_new_nowave.py <bin> inst.data
# =============================================================================

# ------------------------------ 可配置参数 -----------------------------------
set RTL_DIR     "../rtl"                 ;# RTL 源码根目录（含 core/perips/soc/debug/utils）
set TB_DIR      "../tb"                  ;# testbench 目录
set TOP_MODULE  "tinyriscv_soc_tb"       ;# 仿真顶层模块
set WORK_LIB    "work"                   ;# 工作库名称
set RUN_TIME    "500 us"                 ;# 仿真运行时间（tb 超时为 500us）
set MEM_FILE    "../sim/inst.data"       ;# 程序镜像文件
set DUT         "/$TOP_MODULE/tinyriscv_soc_top_0"  ;# DUT 层次路径
set CORE        "$DUT/u_tinyriscv"       ;# CPU 核层次路径
# -----------------------------------------------------------------------------

# 注意：ModelSim 中 [info script] 返回的是启动器路径，不能用来定位本脚本，
# 因此不自动 cd。请务必在 vsim-prj 目录下运行本脚本。
if {![file isdirectory $RTL_DIR] || ![file isdirectory $TB_DIR]} {
    echo "\[ERROR\] 未找到 $RTL_DIR 或 $TB_DIR，请先 cd 到 vsim-prj 目录再运行本脚本。"
    echo "\[ERROR\] 当前目录: [pwd]"
    if {[batch_mode]} { quit -f } else { error "wrong working directory" }
}

echo "=============================================================="
echo " tinyriscv ModelSim 自动化仿真"
echo " 工作目录 : [pwd]"
echo " RTL 目录 : [file normalize $RTL_DIR]"
echo " TB  目录 : [file normalize $TB_DIR]"
echo "=============================================================="

# ----------------------------- 1. 清理工作库 ---------------------------------
if {[catch {quit -sim}]} {}
if {[file exists $WORK_LIB]} {
    catch {file delete -force $WORK_LIB}
}
if {[catch {vlib $WORK_LIB} err]} {
    echo "\[ERROR\] 创建库 $WORK_LIB 失败: $err"
    if {[batch_mode]} { quit -f } else { error $err }
}
quietly catch {vmap $WORK_LIB [file join [pwd] $WORK_LIB]}

# ----------------------------- 2. 检查程序镜像 -------------------------------
if {![file exists $MEM_FILE]} {
    echo "\[WARNING\] 未找到程序镜像 $MEM_FILE"
    echo "\[WARNING\] ROM 将全为 0，仿真会一直运行到超时。"
    echo "\[WARNING\] 可先执行: python ../sim/sim_new_nowave.py <xxx.bin> inst.data"
}

# ----------------------------- 3. 编译 RTL -----------------------------------
# 源码中使用 "../core/defines.v" 这类相对路径包含头文件，
# 这里把所有 rtl 子目录都加入搜索路径，保证不同 cwd 下也能找到。
set incdirs [list \
    +incdir+$RTL_DIR/core \
    +incdir+$RTL_DIR/perips \
    +incdir+$RTL_DIR/soc \
    +incdir+$RTL_DIR/debug \
    +incdir+$RTL_DIR/utils \
    +incdir+$TB_DIR \
]

set rtl_files [lsort [glob -nocomplain $RTL_DIR/*/*.v]]
if {[llength $rtl_files] == 0} {
    echo "\[ERROR\] 在 $RTL_DIR/*/*.v 下没有找到任何 RTL 源文件"
    if {[batch_mode]} { quit -f } else { error "no rtl files" }
}

echo "\n---- 编译 RTL ([llength $rtl_files] 个文件) ----"
if {[catch {eval vlog -work $WORK_LIB $incdirs $rtl_files} err]} {
    echo "\[ERROR\] RTL 编译失败: $err"
    if {[batch_mode]} { quit -f } else { error $err }
}

# ----------------------------- 4. 编译 Testbench -----------------------------
set tb_files [lsort [glob -nocomplain $TB_DIR/*.v]]
if {[llength $tb_files] == 0} {
    echo "\[ERROR\] 在 $TB_DIR/*.v 下没有找到任何 testbench 文件"
    if {[batch_mode]} { quit -f } else { error "no tb files" }
}

echo "\n---- 编译 Testbench ([llength $tb_files] 个文件) ----"
if {[catch {eval vlog -work $WORK_LIB $incdirs $tb_files} err]} {
    echo "\[ERROR\] Testbench 编译失败: $err"
    if {[batch_mode]} { quit -f } else { error $err }
}

# ----------------------------- 5. 加载仿真顶层 -------------------------------
# -voptargs="+acc" ：保留所有信号，保证 tb 中的跨层次引用和各层信号可见
echo "\n---- 加载顶层 $TOP_MODULE ----"
if {[catch {vsim -voptargs=+acc -suppress 2685 -suppress 2718 -lib $WORK_LIB $TOP_MODULE} err]} {
    echo "\[ERROR\] vsim 加载失败: $err"
    if {[batch_mode]} { quit -f } else { error $err }
}

# tb 中未连接的输入引脚在 ModelSim 里为高阻(z)，这里给它们默认电平，
# 使 SoC IO 引脚波形有意义（不影响 CPU 正常运行）。
foreach {sig val} {uart_rx_pin 1 spi_miso 1 jtag_TCK 1 jtag_TMS 1 jtag_TDI 1} {
    if {[catch {force -freeze $DUT/$sig $val 0} err]} {
        echo "\[WARNING\] force $sig 失败: $err"
    }
}

# ----------------------------- 6. 添加波形 -----------------------------------
# 波形添加放在 proc 中，个别信号缺失时只告警，不中断批处理流程
proc add_cpu_waves {} {
global TOP_MODULE DUT CORE

# 6.1 时钟 / 复位 / 测试结果
add wave -noupdate -divider {Clock & Reset}
add wave -noupdate -format logic /$TOP_MODULE/clk
add wave -noupdate -format logic /$TOP_MODULE/rst
add wave -noupdate -format logic /$TOP_MODULE/tinyriscv_soc_top_0/over
add wave -noupdate -format logic /$TOP_MODULE/tinyriscv_soc_top_0/succ

add wave -noupdate -divider {Test Result (x3/x26/x27)}
add wave -noupdate -radix hexadecimal /$TOP_MODULE/x3
add wave -noupdate -radix hexadecimal /$TOP_MODULE/x26
add wave -noupdate -radix hexadecimal /$TOP_MODULE/x27

# 6.2 SoC 对外 IO 引脚
add wave -noupdate -divider {SoC IO Pins}
add wave -noupdate -format logic $DUT/uart_debug_pin
add wave -noupdate -format logic $DUT/uart_tx_pin
add wave -noupdate -format logic $DUT/uart_rx_pin
add wave -noupdate -radix binary   $DUT/gpio
add wave -noupdate -format logic $DUT/spi_miso
add wave -noupdate -format logic $DUT/spi_mosi
add wave -noupdate -format logic $DUT/spi_ss
add wave -noupdate -format logic $DUT/spi_clk
add wave -noupdate -format logic $DUT/jtag_TCK
add wave -noupdate -format logic $DUT/jtag_TMS
add wave -noupdate -format logic $DUT/jtag_TDI
add wave -noupdate -format logic $DUT/jtag_TDO
add wave -noupdate -format logic $DUT/halted_ind

# 6.3 CPU 核对外总线接口（CPU 的 IO）
add wave -noupdate -divider {CPU Core IO Bus}
add wave -noupdate -radix hexadecimal $CORE/rib_pc_addr_o
add wave -noupdate -radix hexadecimal $CORE/rib_pc_data_i
add wave -noupdate -format logic        $CORE/rib_ex_req_o
add wave -noupdate -format logic        $CORE/rib_ex_we_o
add wave -noupdate -radix hexadecimal $CORE/rib_ex_addr_o
add wave -noupdate -radix hexadecimal $CORE/rib_ex_data_o
add wave -noupdate -radix hexadecimal $CORE/rib_ex_data_i
add wave -noupdate -radix hexadecimal $CORE/int_i

# 6.4 流水线关键信号
add wave -noupdate -divider {CPU Pipeline}
add wave -noupdate -radix hexadecimal $CORE/pc_pc_o
add wave -noupdate -radix hexadecimal $CORE/if_inst_addr_o
add wave -noupdate -radix hexadecimal $CORE/if_inst_o
add wave -noupdate -radix hexadecimal $CORE/id_inst_addr_o
add wave -noupdate -radix hexadecimal $CORE/id_inst_o
add wave -noupdate -radix hexadecimal $CORE/ie_inst_addr_o
add wave -noupdate -radix hexadecimal $CORE/ie_inst_o
add wave -noupdate -format logic        $CORE/ctrl_hold_flag_o
add wave -noupdate -format logic        $CORE/ctrl_jump_flag_o
add wave -noupdate -radix hexadecimal $CORE/ctrl_jump_addr_o

# 6.5 外设读写（便于观察 UART/GPIO/SPI/Timer 访问）
add wave -noupdate -divider {Peripheral Access}
add wave -noupdate -radix hexadecimal $DUT/u_rib/s0_addr_o
add wave -noupdate -format logic        $DUT/u_rib/s0_we_o
add wave -noupdate -radix hexadecimal $DUT/u_rib/s0_data_o
add wave -noupdate -radix hexadecimal $DUT/u_rib/s0_data_i
add wave -noupdate -radix hexadecimal $DUT/u_rib/s1_addr_o
add wave -noupdate -format logic        $DUT/u_rib/s1_we_o
add wave -noupdate -radix hexadecimal $DUT/u_rib/s2_addr_o
add wave -noupdate -format logic        $DUT/u_rib/s2_we_o
add wave -noupdate -radix hexadecimal $DUT/u_rib/s3_addr_o
add wave -noupdate -format logic        $DUT/u_rib/s3_we_o
add wave -noupdate -radix hexadecimal $DUT/u_rib/s4_addr_o
add wave -noupdate -format logic        $DUT/u_rib/s4_we_o
add wave -noupdate -radix hexadecimal $DUT/u_rib/s5_addr_o
add wave -noupdate -format logic        $DUT/u_rib/s5_we_o
}

if {[catch {add_cpu_waves} err]} {
    echo "\[WARNING\] 添加波形时出现问题: $err"
}

# GUI 下的波形显示设置
if {![batch_mode]} {
    catch {configure wave -signalnamewidth 1}
    catch {configure wave -timelineunits ns}
    catch {configure wave -namecolwidth 260}
}

# ----------------------------- 7. 运行仿真 -----------------------------------
echo "\n---- 开始仿真 (run $RUN_TIME) ----"
if {[catch {run $RUN_TIME} err]} {
    echo "\[ERROR\] 仿真运行出错: $err"
    if {[batch_mode]} { quit -f } else { error $err }
}
echo "---- 仿真结束 ----"

# GUI 模式下自动缩放波形；批处理模式直接退出
if {[batch_mode]} {
    echo "---- 批处理模式，退出 ModelSim ----"
    quit -f
} else {
    catch {wave zoom full}
}

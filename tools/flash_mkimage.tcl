# tools/flash_mkimage.tcl -- build bootable QSPI images from a bitstream.
#
# The vendor guide (正点原子 达芬奇Pro FPGA开发指南 V2.2, ch.5.3.13 程序固化) says
# the bitstream must first carry the SPI boot primitives, and that EITHER an
# .mcs OR a .bin image may be programmed. This script produces both.
#
# ENV:
#   IMG_BIT   input bitstream      (default fpga/cpu_a100t.bit)
#   IMG_IFACE SPIx1 | SPIx4        (default SPIx1)
#   IMG_SIZE  flash size in MB     (default 16)
#   IMG_TAG   output basename tag  (default derived from iface)
set root "D:/USER/Desktop/FPGA/FPGA"
set IMG_BIT   "$root/fpga/cpu_a100t.bit"
set IMG_IFACE "SPIx1"
set IMG_SIZE  "16"
set IMG_TAG   ""
foreach ev {IMG_BIT IMG_IFACE IMG_SIZE IMG_TAG} {
  if {[info exists ::env($ev)] && $::env($ev) ne ""} { set $ev $::env($ev) }
}
if {$IMG_TAG eq ""} { set IMG_TAG [string tolower $IMG_IFACE] }
set out "$root/fpga"
puts "MKIMAGE: bit=$IMG_BIT iface=$IMG_IFACE size=$IMG_SIZE tag=$IMG_TAG"
puts "MKIMAGE: bit exists = [file exists $IMG_BIT]"
write_cfgmem -force -format MCS -interface $IMG_IFACE -size $IMG_SIZE \
  -loadbit "up 0x0 $IMG_BIT" -file "$out/cpu_a100t_$IMG_TAG.mcs"
write_cfgmem -force -format BIN -interface $IMG_IFACE -size $IMG_SIZE \
  -loadbit "up 0x0 $IMG_BIT" -file "$out/cpu_a100t_$IMG_TAG.bin"
foreach f [list "$out/cpu_a100t_$IMG_TAG.mcs" "$out/cpu_a100t_$IMG_TAG.bin"] {
  puts "MKIMAGE_OUT $f size=[expr {[file exists $f]?[file size $f]:-1}]"
}
puts "MKIMAGE_OK"

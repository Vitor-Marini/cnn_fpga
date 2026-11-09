# Monitor da FPGA pelo cabo USB-Blaster (In-System Sources and Probes de rtl/jtag_debug.vhd).
# Uso:  quartus_stp -t tools/jtag_monitor.tcl            (status a cada 0,5 s + imagem a cada quadro novo)
#       quartus_stp -t tools/jtag_monitor.tcl once       (um status + a ultima imagem, e sai)
# Sai com Ctrl-C.

set once [expr {[llength $argv] > 0 && [lindex $argv 0] eq "once"}]
set hw  [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -hardware_name $hw -device_name $dev

proc probe {} {
    # 80 bits em hex (20 digitos): [79:64] inferencias [63:48] bytes [47:32] ruins [31:16] ok [15:12] HEX0 [11:8] CNN [7:0] pixel
    set h [read_probe_data -instance_index 0 -value_in_hex]
    set h "[string repeat 0 [expr {20 - [string length $h]}]]$h"
    return [list [scan [string range $h 0 3] %x] [scan [string range $h 4 7] %x] [scan [string range $h 8 11] %x] \
                 [scan [string range $h 12 15] %x] [scan [string index $h 16] %x] [scan [string index $h 17] %x] \
                 [scan [string range $h 18 19] %x]]
}

proc image {} {
    set shade " .:-=+*#%@"
    set rows {}
    for {set y 0} {$y < 28} {incr y} {
        set line ""
        for {set x 0} {$x < 28} {incr x} {
            write_source_data -instance_index 0 -value [format %03X [expr {$y * 28 + $x}]] -value_in_hex
            set v [lindex [probe] 6]
            append line [string index $shade [expr {min(9, $v * 9 / 127)}]]
        }
        lappend rows "|$line|"
    }
    return [join $rows "\n"]
}

set last_done -1
set last_img 0
while {1} {
    lassign [probe] n_done n_bytes n_bad n_ok shown digit
    puts [format "bytes %5d | quadros ok %5d | checksum errado %5d | inferencias %5d | CNN %d | HEX0 %d" \
          $n_bytes $n_ok $n_bad $n_done $digit $shown]
    # imagem quando chega inferencia nova (no maximo a cada 3 s, ler 784 pixels leva ~1-2 s)
    if {$once || ($n_done != $last_done && [clock seconds] - $last_img >= 3)} {
        puts "ultima imagem entregue a CNN (CNN disse $digit):"
        puts [image]
        set last_img [clock seconds]
    }
    set last_done $n_done
    if {$once} break
    after 500
}
end_insystem_source_probe

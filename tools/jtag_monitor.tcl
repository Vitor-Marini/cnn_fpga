# Monitor da FPGA pelo cabo USB-Blaster (In-System Sources and Probes de rtl/jtag_debug.vhd).
# Uso:  quartus_stp -t tools/jtag_monitor.tcl            (status a cada 0,5 s + raio-x da CNN a cada quadro novo)
#       quartus_stp -t tools/jtag_monitor.tcl once       (um status + um raio-x, e sai)
# O raio-x congela a FPGA por ~3 s e le, do mesmo quadro: a imagem 28x28, os 8 mapas 13x13 e as 10 pontuacoes.
# Ele e salvo em painel_cnn.pgm (entrada | 8 mapas | pontuacoes): abra com  eog painel_cnn.pgm  (recarrega sozinho)
# e os numeros crus em ultimo_quadro.txt. Sai com Ctrl-C.

set once [expr {[llength $argv] > 0 && [lindex $argv 0] eq "once"}]
set hw  [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -hardware_name $hw -device_name $dev

# source: bit 12 congela, bit 11 escolhe mapas (1) ou imagem (0), bits 10..0 endereco
proc src {freeze maps addr} {
    write_source_data -instance_index 0 -value [format %04X [expr {($freeze << 12) | ($maps << 11) | $addr}]] -value_in_hex
}

# probe (112 bits, 28 hex): [111:80] pontuacao  [79:64] inferencias  [63:48] bytes  [47:32] ruins
#                           [31:16] ok  [15:12] HEX0  [11:8] CNN  [7:0] pixel/valor do mapa
proc probe {} {
    set h [read_probe_data -instance_index 0 -value_in_hex]
    set h "[string repeat 0 [expr {28 - [string length $h]}]]$h"
    set sc [scan [string range $h 0 7] %x]
    if {$sc >= 0x80000000} { set sc [expr {$sc - 0x100000000}] }
    return [list $sc [scan [string range $h 8 11] %x] [scan [string range $h 12 15] %x] [scan [string range $h 16 19] %x] \
                 [scan [string range $h 20 23] %x] [scan [string index $h 24] %x] [scan [string index $h 25] %x] \
                 [scan [string range $h 26 27] %x]]
}

proc snapshot {} {
    src 1 0 0
    after 50                                  ;# deixa terminar uma inferencia que ja tinha comecado (~4 ms)
    set img {}
    for {set a 0} {$a < 784} {incr a} { src 1 0 $a; lappend img [lindex [probe] 7] }
    set maps {}
    for {set a 0} {$a < 1352} {incr a} { src 1 1 $a; lappend maps [lindex [probe] 7] }
    set scores {}
    for {set d 0} {$d < 10} {incr d} { src 1 0 $d; lappend scores [lindex [probe] 0] }
    set digit [lindex [probe] 6]
    src 0 0 0
    return [list $img $maps $scores $digit]
}

proc ascii {img} {
    set shade " .:-=+*#%@"
    set out {}
    for {set y 0} {$y < 28} {incr y} {
        set line ""
        foreach v [lrange $img [expr {$y * 28}] [expr {$y * 28 + 27}]] { append line [string index $shade [expr {min(9, $v * 9 / 127)}]] }
        lappend out "|$line|"
    }
    return [join $out "\n"]
}

proc bars {scores digit} {
    set m 1
    foreach s $scores { set m [expr {max($m, abs($s))}] }
    set out {}
    for {set d 0} {$d < 10} {incr d} {
        set s [lindex $scores $d]
        set n [expr {round(abs($s) * 20.0 / $m)}]
        set neg [expr {$s < 0 ? "[string repeat " " [expr {20 - $n}]][string repeat - $n]" : [string repeat " " 20]}]
        set pos [expr {$s > 0 ? [string repeat # $n] : ""}]
        lappend out [format "  %d %s|%-20s %8d%s" $d $neg $pos $s [expr {$d == $digit ? "  <- maior pontuacao" : ""}]]
    }
    return [join $out "\n"]
}

# painel 1130x300 em tons de cinza: entrada (28x28, 10x) | 8 mapas (13x13, 10x) | barras das pontuacoes
proc panel {img maps scores digit} {
    set W 1130; set H 300
    set row [lrepeat $W 40]
    set cv [lrepeat $H $row]
    proc blit {cvName x0 y0 vals n k} {
        upvar $cvName cv
        for {set y 0} {$y < $n} {incr y} {
            set line {}
            foreach v [lrange $vals [expr {$y * $n}] [expr {$y * $n + $n - 1}]] { lappend line {*}[lrepeat $k [expr {$v * 2}]] }
            for {set r 0} {$r < $k} {incr r} {
                set yy [expr {$y0 + $y * $k + $r}]
                lset cv $yy [lreplace [lindex $cv $yy] $x0 [expr {$x0 + [llength $line] - 1}] {*}$line]
            }
        }
    }
    blit cv 10 10 $img 28 10
    for {set k 0} {$k < 8} {incr k} {
        blit cv [expr {310 + ($k % 4) * 140}] [expr {10 + ($k / 4) * 140}] [lrange $maps [expr {$k * 169}] [expr {$k * 169 + 168}]] 13 10
    }
    set m 1
    foreach s $scores { set m [expr {max($m, abs($s))}] }
    for {set d 0} {$d < 10} {incr d} {
        set s [lindex $scores $d]
        set len [expr {int(abs($s) * 110.0 / $m)}]
        set x0 [expr {$s >= 0 ? 1000 : 1000 - $len}]
        set c [expr {$d == $digit ? 255 : 140}]
        for {set y [expr {14 + $d * 28}]} {$y < [expr {34 + $d * 28}]} {incr y} {
            if {$len > 0} { lset cv $y [lreplace [lindex $cv $y] $x0 [expr {$x0 + $len - 1}] {*}[lrepeat $len $c]] }
            lset cv $y 1000 90
        }
    }
    set f [open painel_cnn.pgm.tmp wb]
    puts -nonewline $f "P5\n$W $H\n255\n"
    foreach r $cv { puts -nonewline $f [binary format c* $r] }
    close $f
    file rename -force painel_cnn.pgm.tmp painel_cnn.pgm
}

set last_done -1
set last_img 0
while {1} {
    lassign [probe] score n_done n_bytes n_bad n_ok shown digit
    puts [format "bytes %5d | quadros ok %5d | checksum errado %5d | inferencias %5d | CNN %d | HEX0 %d" \
          $n_bytes $n_ok $n_bad $n_done $digit $shown]
    if {$once || ($n_done != $last_done && [clock seconds] - $last_img >= 3)} {
        lassign [snapshot] img maps scores digit
        puts "\nentrada da CNN (28x28):"
        puts [ascii $img]
        puts "\npontuacao de cada digito (camada densa):"
        puts [bars $scores $digit]
        puts "a CNN responde $digit  |  imagem completa: painel_cnn.pgm\n"
        panel $img $maps $scores $digit
        set f [open ultimo_quadro.txt w]
        puts $f "imagem $img"; puts $f "mapas $maps"; puts $f "pontuacoes $scores"; puts $f "digito $digit"
        close $f
        set last_img [clock seconds]
        lassign [probe] score n_done
    }
    set last_done $n_done
    if {$once} break
    after 500
}
end_insystem_source_probe

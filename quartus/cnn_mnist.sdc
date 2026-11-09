create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_clock_uncertainty
# entradas assincronas (passam por sincronizadores de 2 FF) e saidas estaticas (LEDs/7seg)
set_false_path -from [get_ports {KEY[*] SW[*] GPIO[*]}]
set_false_path -to [get_ports {HEX0[*] HEX1[*] LEDR[*]}]

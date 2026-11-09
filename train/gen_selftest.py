#!/usr/bin/env python3
"""Gera as 16 imagens do autoteste (SW3..SW0) a partir dos pesos que estao no hardware:
  ../rtl/selftest_pkg.vhd     imagens + rotulo + predicao esperada (constantes VHDL)
  ../docs/selftest_sw.png     tabela visual SW -> imagem -> o que deve aparecer em HEX0/HEX1
SW 0..9 = um exemplo acertado de cada digito; SW 10..14 = outros acertos; SW 15 = um erro real da rede.
"""
import os, re
import numpy as np
from train_quant import HERE, load, to7, int_forward


def load_q(path):
    src = open(path).read()
    arr = lambda n: np.array([int(v) for v in re.search(
        n + r" : int_array\(.*?\) := \((.*?)\);", src, re.S).group(1).replace("\n", " ").split(",")])
    nf = int(re.search(r"NF\s+: natural := (\d+)", src).group(1))
    sh = int(re.search(r"ACT_SHIFT : natural := (\d+)", src).group(1))
    return (arr("CONV_W").reshape(nf, 9).T, arr("CONV_B"), sh, arr("FC_W").reshape(10, -1).T, arr("FC_B"))


if __name__ == "__main__":
    q = load_q(os.path.join(HERE, "..", "rtl", "weights_pkg.vhd"))
    X, Y = to7(load("t10k-images-idx3-ubyte.gz", 1)), load("t10k-labels-idx1-ubyte.gz", 0)
    P = int_forward(q, X[:2000]).argmax(1)
    ok = np.flatnonzero(P == Y[:2000])
    pick = [int(ok[Y[ok] == d][0]) for d in range(10)]
    pick += [int(i) for i in ok if i not in pick][:5]
    pick.append(int(np.flatnonzero(P != Y[:2000])[0]))
    assert len(pick) == 16

    lines = ["-- GERADO por train/gen_selftest.py -- nao editar a mao",
             "package selftest_pkg is",
             "  type nat_array is array (natural range <>) of natural;",
             "  constant SELF_IMG : nat_array(0 to 16 * 784 - 1) := ("]
    flat = np.concatenate([X[i].reshape(-1) for i in pick])
    lines.append(",\n".join("    " + ", ".join(map(str, flat[j:j + 28])) for j in range(0, len(flat), 28)))
    lines += ["  );",
              "  constant SELF_LABEL : nat_array(0 to 15) := (" + ", ".join(str(Y[i]) for i in pick) + ");",
              "  constant SELF_PRED  : nat_array(0 to 15) := (" + ", ".join(str(P[i]) for i in pick) + ");",
              "end package;"]
    open(os.path.join(HERE, "..", "rtl", "selftest_pkg.vhd"), "w").write("\n".join(lines) + "\n")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axs = plt.subplots(4, 4, figsize=(9, 10.5))
    for s, (ax, i) in enumerate(zip(axs.flat, pick)):
        ax.imshow(X[i], cmap="gray", vmin=0, vmax=127)
        ax.set_xticks([]); ax.set_yticks([])
        sw = "".join("↑" if (s >> b) & 1 else "↓" for b in (3, 2, 1, 0))
        wrong = P[i] != Y[i]
        ax.set_title(f"SW3..0 = {s:04b}  {sw}\nHEX0 (CNN) = {P[i]}   HEX1 = {Y[i]}" + ("  (erro)" if wrong else ""),
                     fontsize=9.5, color="#c0392b" if wrong else "black")
    fig.suptitle("Autoteste: posicione SW3..SW0, aperte KEY1 e compare HEX0 com o esperado\n"
                 "↑ = chave para cima (1), ↓ = para baixo (0)", fontsize=11)
    fig.tight_layout()
    os.makedirs(os.path.join(HERE, "..", "docs"), exist_ok=True)
    fig.savefig(os.path.join(HERE, "..", "docs", "selftest_sw.png"), dpi=110)
    for s, i in enumerate(pick):
        print(f"SW={s:2d} idx_teste={i:4d} rotulo={Y[i]} pred={P[i]}")

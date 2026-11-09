#!/usr/bin/env python3
"""Treina a CNN MNIST (numpy puro), quantiza para int8 e gera:
  ../rtl/weights_pkg.vhd   pesos/biases como constantes VHDL (sintese + simulacao)
  ../sim/test_vectors.txt  imagens de teste + predicao do modelo inteiro (golden)

Rede: conv3x3x8 (valid) -> maxpool2 -> ReLU -> >>SH, clamp 0..127 -> dense 1352->10 -> argmax
O modelo inteiro abaixo (int_forward) e bit-exato com rtl/cnn_core.vhd.
"""
import gzip, os, urllib.request
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
URL = "https://storage.googleapis.com/cvdf-datasets/mnist/"
NF, EPOCHS, BATCH, LR = 8, 3, 64, 1e-3
rng = np.random.default_rng(0)


def load(name, img):
    path = os.path.join(HERE, "data", name)
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        urllib.request.urlretrieve(URL + name, path)
    with gzip.open(path) as f:
        d = np.frombuffer(f.read(), np.uint8, offset=16 if img else 8)
    return d.reshape(-1, 28, 28) if img else d


def patches(x):  # (N,28,28) -> (N,26,26,9), k = ky*3+kx
    return np.stack([x[:, ky:ky + 26, kx:kx + 26] for ky in range(3) for kx in range(3)], -1)


def pool(c):  # (N,26,26,F) -> (N,F,13,13): maxpool 2x2, ordem de flatten = f*169+py*13+px
    return c.reshape(-1, 13, 2, 13, 2, NF).max((2, 4)).transpose(0, 3, 1, 2)


def train(xtr, ytr):
    W1 = rng.normal(0, np.sqrt(2 / 9), (9, NF)); b1 = np.zeros(NF)
    W2 = rng.normal(0, np.sqrt(1 / 1352), (1352, 10)); b2 = np.zeros(10)
    params = [W1, b1, W2, b2]
    m = [np.zeros_like(p) for p in params]; v = [np.zeros_like(p) for p in params]
    t = 0
    for ep in range(EPOCHS):
        perm = rng.permutation(len(xtr))
        for i in range(0, len(xtr), BATCH):
            xb, yb = xtr[perm[i:i + BATCH]], ytr[perm[i:i + BATCH]]
            n = len(xb)
            P = patches(xb)
            C = P @ W1 + b1                                   # (n,26,26,F)
            Pm = pool(C)                                      # (n,F,13,13)
            A = np.maximum(Pm, 0).reshape(n, -1)
            Z = A @ W2 + b2
            Z -= Z.max(1, keepdims=True)
            S = np.exp(Z); S /= S.sum(1, keepdims=True)
            S[np.arange(n), yb] -= 1; dZ = S / n
            gW2, gb2 = A.T @ dZ, dZ.sum(0)
            dPm = (dZ @ W2.T).reshape(Pm.shape) * (Pm > 0)
            # unpool: gradiente para a(s) posicao(oes) do maximo
            dPm = dPm.transpose(0, 2, 3, 1)[:, :, None, :, None, :]
            Pm6 = Pm.transpose(0, 2, 3, 1)[:, :, None, :, None, :]
            dC = (C.reshape(n, 13, 2, 13, 2, NF) == Pm6) * dPm
            dC = dC.reshape(n, 26, 26, NF)
            gW1 = P.reshape(-1, 9).T @ dC.reshape(-1, NF); gb1 = dC.sum((0, 1, 2))
            t += 1
            for k, g in enumerate([gW1, gb1, gW2, gb2]):  # Adam
                m[k] = 0.9 * m[k] + 0.1 * g; v[k] = 0.999 * v[k] + 0.001 * g * g
                params[k] -= LR * (m[k] / (1 - 0.9 ** t)) / (np.sqrt(v[k] / (1 - 0.999 ** t)) + 1e-8)
        print(f"epoch {ep + 1}: float acc teste = {float_acc(params):.4f}")
    return params


def float_forward(params, x):
    W1, b1, W2, b2 = params
    out = []
    for i in range(0, len(x), 1000):
        A = np.maximum(pool(patches(x[i:i + 1000]) @ W1 + b1), 0).reshape(-1, 1352)
        out.append(A @ W2 + b2)
    return np.concatenate(out)


def float_acc(params):
    return (float_forward(params, XTE / 255.0).argmax(1) == YTE).mean()


def int_forward(q, xq):
    """Modelo inteiro de referencia. xq: (N,28,28) int 0..127."""
    w1, b1, sh, w2, b2 = q
    out = []
    for i in range(0, len(xq), 1000):
        P = patches(xq[i:i + 1000].astype(np.int64))
        acc = pool(P @ w1 + b1)                              # int64, max antes do ReLU
        a = np.minimum(np.maximum(acc, 0) >> sh, 127).reshape(-1, 1352)
        out.append(a @ w2 + b2)
    return np.concatenate(out)


def quantize(params, xcal, ycal):
    W1, b1, W2, b2 = params
    s1 = np.abs(W1).max() / 127; s2 = np.abs(W2).max() / 127
    w1 = np.round(W1 / s1).astype(np.int64); w2 = np.round(W2 / s2).astype(np.int64)
    b1q = np.round(b1 / (s1 / 127)).astype(np.int64)
    best = None
    for sh in range(0, 16):  # escolhe o shift de requantizacao pela acuracia na calibracao
        sa = (2 ** sh) * s1 / 127
        q = (w1, b1q, sh, w2, np.round(b2 / (sa * s2)).astype(np.int64))
        acc = (int_forward(q, xcal).argmax(1) == ycal).mean()
        if best is None or acc > best[0]:
            best = (acc, q)
    return best[1]


def to7(x):  # pixel 0..255 -> 0..127 (o mesmo que a ESP32 envia)
    return (x.astype(np.int64) >> 1)


def vhdl_array(name, typ, vals, per_line=16):
    lines = [", ".join(str(int(v)) for v in vals[i:i + per_line]) for i in range(0, len(vals), per_line)]
    return f"  constant {name} : {typ} := (\n    " + ",\n    ".join(lines) + "\n  );\n"


def write_pkg(q, path):
    w1, b1, sh, w2, b2 = q
    assert np.abs(w1).max() <= 127 and np.abs(w2).max() <= 127
    assert np.abs(b1).max() < 2 ** 31 and np.abs(b2).max() < 2 ** 31
    # conv: indice f*9+k ; fc: indice o*1352+i
    s = ["-- GERADO por train/train_quant.py -- nao editar a mao",
         "library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;",
         "package weights_pkg is",
         "  type int_array is array (natural range <>) of integer;",
         f"  constant NF   : natural := {NF};",
         f"  constant ACT_SHIFT : natural := {sh};",
         vhdl_array("CONV_W", f"int_array(0 to {NF * 9 - 1})", w1.T.reshape(-1)),
         vhdl_array("CONV_B", f"int_array(0 to {NF - 1})", b1),
         vhdl_array("FC_W", f"int_array(0 to {10 * 1352 - 1})", w2.T.reshape(-1), 32),
         vhdl_array("FC_B", "int_array(0 to 9)", b2),
         "end package;"]
    with open(path, "w") as f:
        f.write("\n".join(s) + "\n")


if __name__ == "__main__":
    XTR, YTR = load("train-images-idx3-ubyte.gz", 1), load("train-labels-idx1-ubyte.gz", 0)
    XTE, YTE = load("t10k-images-idx3-ubyte.gz", 1), load("t10k-labels-idx1-ubyte.gz", 0)
    params = train(XTR / 255.0, YTR)
    q = quantize(params, to7(XTR[:5000]), YTR[:5000])
    pred = int_forward(q, to7(XTE)).argmax(1)  # argmax: primeiro maximo vence (igual ao RTL)
    print(f"ACT_SHIFT = {q[2]} | acuracia INT8 (bit-exata com RTL) no teste: {(pred == YTE).mean():.4f}")
    write_pkg(q, os.path.join(HERE, "..", "rtl", "weights_pkg.vhd"))
    with open(os.path.join(HERE, "..", "sim", "test_vectors.txt"), "w") as f:
        for i in range(20):  # 784 pixels 0..127 + predicao golden
            f.write(" ".join(map(str, to7(XTE[i]).reshape(-1))) + f" {pred[i]}\n")
    print("gerados rtl/weights_pkg.vhd e sim/test_vectors.txt")

#Requires -Version 7
<#
.SYNOPSIS
    Gera build/icon.png (512x512, fundo transparente) a partir do simbolo da Bizapp.

.DESCRIPTION
    Usa symbol-white-transparent.png como mascara: o quadrado recebe o gradiente da marca
    (#8034AE -> #CB61E8), o "b" (furo da mascara) fica branco e o lado de fora fica
    transparente, preservando o antialias das bordas. O electron-builder converte o PNG
    no .ico do app e do instalador.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing.Common, System.Drawing.Primitives, System.Collections -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;

public static class IconeBizapp {
    static Color Gradiente(int x, int y, int w, int h) {
        // Escuro embaixo a esquerda, claro em cima a direita (como no simbolo oficial)
        double t = ((double)x / (w - 1) + (double)(h - 1 - y) / (h - 1)) / 2.0;
        return Color.FromArgb(
            (int)Math.Round(0x80 + (0xCB - 0x80) * t),
            (int)Math.Round(0x34 + (0x61 - 0x34) * t),
            (int)Math.Round(0xAE + (0xE8 - 0xAE) * t));
    }

    public static Bitmap Gerar(Bitmap mascara) {
        int w = mascara.Width, h = mascara.Height;
        var alfa = new byte[w, h];
        for (int x = 0; x < w; x++) for (int y = 0; y < h; y++) alfa[x, y] = mascara.GetPixel(x, y).A;

        // Lado de fora: pixels translucidos alcancaveis a partir da borda
        // (o quadrado da mascara tem alfa 254, nao 255, por isso o limite e 250)
        var fora = new bool[w, h];
        var fila = new Queue<(int, int)>();
        for (int x = 0; x < w; x++) { fila.Enqueue((x, 0)); fila.Enqueue((x, h - 1)); }
        for (int y = 0; y < h; y++) { fila.Enqueue((0, y)); fila.Enqueue((w - 1, y)); }
        while (fila.Count > 0) {
            var (x, y) = fila.Dequeue();
            if (x < 0 || y < 0 || x >= w || y >= h || fora[x, y] || alfa[x, y] >= 250) continue;
            fora[x, y] = true;
            fila.Enqueue((x + 1, y)); fila.Enqueue((x - 1, y)); fila.Enqueue((x, y + 1)); fila.Enqueue((x, y - 1));
        }

        var saida = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        for (int x = 0; x < w; x++) for (int y = 0; y < h; y++) {
            var g = Gradiente(x, y, w, h);
            double a = Math.Min(1.0, alfa[x, y] / 254.0);
            if (fora[x, y]) {
                saida.SetPixel(x, y, Color.FromArgb(alfa[x, y], g));
            } else {
                // Dentro do quadrado: mistura gradiente com o branco do "b"
                saida.SetPixel(x, y, Color.FromArgb(255,
                    (int)Math.Round(g.R * a + 255 * (1 - a)),
                    (int)Math.Round(g.G * a + 255 * (1 - a)),
                    (int)Math.Round(g.B * a + 255 * (1 - a))));
            }
        }
        return saida;
    }
}
'@

$raiz = Split-Path -Parent $PSScriptRoot
$mascara = [System.Drawing.Bitmap]::FromFile((Join-Path $raiz 'src\renderer\public\logo\symbol-white-transparent.png'))
$simbolo = [IconeBizapp]::Gerar($mascara)
$mascara.Dispose()

# Centraliza num quadrado 512x512 transparente, com pequena margem
$lado = 512; $margem = 16
$escala = [Math]::Min(($lado - 2 * $margem) / $simbolo.Width, ($lado - 2 * $margem) / $simbolo.Height)
$larg = [int]($simbolo.Width * $escala); $alt = [int]($simbolo.Height * $escala)
$icone = New-Object System.Drawing.Bitmap $lado, $lado, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gfx = [System.Drawing.Graphics]::FromImage($icone)
$gfx.Clear([System.Drawing.Color]::Transparent)
$gfx.InterpolationMode = 'HighQualityBicubic'
$gfx.PixelOffsetMode = 'HighQuality'
$gfx.DrawImage($simbolo, [int](($lado - $larg) / 2), [int](($lado - $alt) / 2), $larg, $alt)
$gfx.Dispose(); $simbolo.Dispose()

$destino = Join-Path $raiz 'build\icon.png'
$icone.Save($destino, [System.Drawing.Imaging.ImageFormat]::Png)
$icone.Dispose()
Write-Output "Icone gerado: $destino"

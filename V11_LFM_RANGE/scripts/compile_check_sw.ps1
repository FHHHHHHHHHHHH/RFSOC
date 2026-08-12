$ErrorActionPreference = "Stop"
$V11Root = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $V11Root
$Compiler = "E:/Xilinx/Vitis/2020.2/gnu/aarch64/nt/aarch64-none/bin/aarch64-none-elf-gcc.exe"
$BspInclude = Join-Path $RepoRoot "sw/ws/RFSOC/export/RFSOC/sw/RFSOC/standalone_domain/bspinclude/include"
$Output = Join-Path $V11Root "output/main_compile_check.o"

if (-not (Test-Path $Compiler)) { throw "Missing compiler: $Compiler" }
if (-not (Test-Path $BspInclude)) {
    throw "The verified V10 BSP include directory is unavailable: $BspInclude"
}

$Arguments = @(
    "-Wall", "-Wextra", "-Werror", "-O2", "-c", "-D__BAREMETAL__",
    "-I$BspInclude", "-I$(Join-Path $V11Root 'sw/src')",
    "-o", $Output, (Join-Path $V11Root "sw/src/main.c")
)
& $Compiler $Arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "PASS: V11 main.c compiled with -Wall -Wextra -Werror"

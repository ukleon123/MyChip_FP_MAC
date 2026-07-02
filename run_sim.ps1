<#
  hdl/testbench 의 테스트벤치를 모듈 단위로 iverilog 컴파일 + vvp 실행한다.
  결과물: simulation/vvp/tb_<Module>.vvp, simulation/vcd/tb_<Module>.vcd

  사용 예:
    .\run_sim.ps1                  # 사용 가능한 모듈 목록 출력
    .\run_sim.ps1 -Module TOP
    .\run_sim.ps1 -Module ACC_R
    .\run_sim.ps1 -Module all       # 등록된 모든 모듈을 순차 실행
#>

param(
    [string]$Module
)

$ErrorActionPreference = "Stop"

$RootDir = $PSScriptRoot
$SrcDir = Join-Path $RootDir "hdl\src"
$TbDir = Join-Path $RootDir "hdl\testbench"
$SimDir = Join-Path $RootDir "simulation"
$VvpDir = Join-Path $SimDir "vvp"
$VcdDir = Join-Path $SimDir "vcd"

# 모듈별 테스트벤치 <-> 필요한 소스 파일 매핑
# (Testbench 는 $dumpfile 이름과 동일한 basename 을 가져야 함)
$ModuleMap = [ordered]@{
    "TOP"                = @{ Testbench = "tb_TOP.v";                Sources = @("TOP.v","CONTROL.v","FPU.v","ACC.v","ACC_R.v","ACC_adder.v","IR.v","SPI_slave.v","W_I_RF.v") }
    "TOP_random"         = @{ Testbench = "tb_TOP_random.v";         Sources = @("TOP.v","CONTROL.v","FPU.v","ACC.v","ACC_R.v","ACC_adder.v","IR.v","SPI_slave.v","W_I_RF.v") }
    "ACC_R"              = @{ Testbench = "tb_ACC_R.v";               Sources = @("ACC_R.v") }
    "ACC_adder"          = @{ Testbench = "tb_ACC_adder.v";           Sources = @("ACC_adder.v") }
    "ACC_adder_overflow" = @{ Testbench = "tb_ACC_adder_overflow.v";  Sources = @("ACC_adder.v") }
    "mant_mult_lut"      = @{ Testbench = "tb_mant_mult_lut.v";       Sources = @() }
}

function Show-AvailableModules {
    Write-Host "사용 가능한 모듈:"
    foreach ($name in $ModuleMap.Keys) {
        Write-Host "  - $name  ($($ModuleMap[$name].Testbench))"
    }
    Write-Host ""
    Write-Host "사용법: .\run_sim.ps1 -Module <이름>  또는  .\run_sim.ps1 -Module all"
}

function Invoke-ModuleTestbench {
    param([string]$Name)

    if (-not $ModuleMap.Contains($Name)) {
        Write-Warning "알 수 없는 모듈: $Name"
        Show-AvailableModules
        return
    }

    $Entry = $ModuleMap[$Name]
    $TbFile = Join-Path $TbDir $Entry.Testbench
    $TbBase = [System.IO.Path]::GetFileNameWithoutExtension($Entry.Testbench)

    $VvpPath = Join-Path $VvpDir "$TbBase.vvp"
    $VcdPath = Join-Path $VcdDir "$TbBase.vcd"

    $SourceFiles = @($TbFile) + ($Entry.Sources | ForEach-Object { Join-Path $SrcDir $_ })

    Write-Host ""
    Write-Host "==== [$Name] $($Entry.Testbench) ===="
    Write-Host "Compiling with iverilog..."
    & iverilog -g2012 -o $VvpPath @SourceFiles
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[$Name] iverilog compilation failed with exit code $LASTEXITCODE"
        return
    }

    Write-Host "Running vvp simulation..."
    Push-Location $VcdDir
    try {
        & vvp $VvpPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[$Name] vvp simulation failed with exit code $LASTEXITCODE"
            return
        }
    }
    finally {
        Pop-Location
    }

    if (Test-Path $VcdPath) {
        Write-Host "Waveform generated: $VcdPath"
    } else {
        Write-Warning "[$Name] VCD 파일이 생성되지 않았습니다 (테스트벤치에 `$dumpfile/`$dumpvars 없음)"
    }
    Write-Host "VVP output: $VvpPath"
}

foreach ($dir in @($VvpDir, $VcdDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

if ([string]::IsNullOrWhiteSpace($Module)) {
    Show-AvailableModules
    exit 0
}

if ($Module -eq "all") {
    foreach ($name in $ModuleMap.Keys) {
        Invoke-ModuleTestbench -Name $name
    }
} else {
    Invoke-ModuleTestbench -Name $Module
}

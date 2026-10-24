# YAK-TAG tag: program one beacon and give it its number.
#   .\flash_tag.ps1 12        → the tag becomes YT-H00012
# Needs: nRF Command Line Tools (nrfjprog) and the nRF52840-DK connected by
# USB, its "Debug out" cable on the beacon's SWD pads (SWDIO, SWCLK, VDD, GND).
# Build first:  west build -b nrf52dk/nrf52832  (a nRF52810 beacon: nrf52dk/nrf52810)
param([Parameter(Mandatory = $true)][ValidateRange(1, 99999)][int]$Number)

$hex = Join-Path $PSScriptRoot 'build\zephyr\zephyr.hex'
if (-not (Test-Path $hex)) { Write-Error "Build first (west build): $hex not found"; exit 1 }

nrfjprog --program $hex --chiperase --verify          # also clears the old number
if ($LASTEXITCODE -ne 0) { exit 1 }
nrfjprog --memwr 0x10001080 --val $Number              # UICR CUSTOMER[0] = the tag's number
if ($LASTEXITCODE -ne 0) { exit 1 }
nrfjprog --reset
Write-Output ("Done: YT-H{0:D5}. Write this number on the tag and link it on the horse's page." -f $Number)

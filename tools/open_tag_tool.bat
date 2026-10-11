@echo off
rem YAK-TAG tag tool: double-click to open a command window in this folder.
cd /d "%~dp0"
title YAK-TAG tag tool
python -c "import smartcard" >NUL 2>&1
if errorlevel 1 (
  echo  The NFC library is missing. Install it once with:
  echo      python -m pip install pyscard
  echo.
)
echo  YAK-TAG tag tool. Put ONE tag on the reader, then type for example:
echo      python nfc_tag.py status
echo      python nfc_tag.py rewrite YT-008005
echo      python nfc_tag.py protect
echo.
cmd /k

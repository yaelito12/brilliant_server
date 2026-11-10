@echo off
rem Doble clic para arrancar el servidor de Brilliant.
rem Corre desde esta carpeta para que encuentre .env y data\.
cd /d "%~dp0"
title Servidor Brilliant

set EXE=build\cli\windows_x64\bundle\bin\server.exe

rem Recompila si no existe el .exe o si algun .dart es mas nuevo que el .exe.
set COMPILAR=0
if not exist "%EXE%" set COMPILAR=1
if exist "%EXE%" (
  powershell -NoProfile -Command "$exe=(Get-Item '%EXE%').LastWriteTime; if (Get-ChildItem bin,lib -Recurse -Filter *.dart | Where-Object { $_.LastWriteTime -gt $exe }) { exit 1 }"
  if errorlevel 1 set COMPILAR=1
)
if "%COMPILAR%"=="1" (
  echo Compilando el servidor, espera un momento...
  call dart pub get
  call dart build cli -t bin/server.dart
)

if not exist ".env" (
  echo Falta el archivo .env. Copia .env.example como .env y pon tu JWT_SECRET
  echo ^(lo generas con: dart run bin/gen_secret.dart^).
  pause
  exit /b 1
)

echo Cierra esta ventana para apagar el servidor.
"%EXE%"
pause

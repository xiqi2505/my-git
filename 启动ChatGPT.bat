@echo off
chcp 65001 >nul
title ChatGPT 一键修复启动

rem ============================================================
rem  双击本文件即可：
rem    1. 检测并自动拉起 Clash Verge
rem    2. 验证代理隧道能否到达 OpenAI
rem    3. 自动打开系统代理（可选，见下方开关）
rem    4. 清理卡死的 ChatGPT 进程
rem    5. 启动 ChatGPT 并确认窗口真的弹出来
rem
rem  想「自动打开系统代理」，把下面这行的 rem 去掉：
rem      set "PROXY_ARG=-EnableSystemProxy"
rem
rem  想「打开后保持不还原」，再加上：
rem      set "PROXY_ARG=-EnableSystemProxy -KeepSystemProxy"
rem ============================================================

set "PROXY_ARG="

set "SCRIPT=%~dp0启动ChatGPT.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo   [错误] 找不到脚本：%SCRIPT%
    echo   请确认「启动ChatGPT.ps1」与本文件放在同一个目录下。
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %PROXY_ARG%

if errorlevel 1 (
    echo.
    echo   脚本异常退出。
    pause
)
exit /b 0

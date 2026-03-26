; launcher_windows.asm
; x86 Windows Assembly Launcher for Mount-GDrive.ps1
; Compiles to a ~2KB silent GUI executable that calls WinExec
;
; nasm -f win32 launcher_windows.asm
; i686-w64-mingw32-ld -m i386pe -s -e _start -subsystem windows launcher_windows.obj -o RcloneMount-Windows.exe -lkernel32

extern _WinExec@8
extern _ExitProcess@4

global _start

section .data
    command db 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "Mount-GDrive.ps1"', 0

section .text
_start:
    ; WinExec(command, SW_HIDE=0)
    push 0                  ; uCmdShow = SW_HIDE
    push command            ; lpCmdLine
    call _WinExec@8         ; Call WinExec

    ; ExitProcess(0)
    push 0                  ; uExitCode
    call _ExitProcess@4     ; Exit safely

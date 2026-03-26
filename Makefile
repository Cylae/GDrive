# Makefile for Assembly Rclone Mount Launchers

all: RcloneMount-Linux RcloneMount-Windows.exe

RcloneMount-Linux: launcher_linux.asm
	nasm -f elf64 launcher_linux.asm -o launcher_linux.o
	ld -s -o RcloneMount-Linux launcher_linux.o
	rm -f launcher_linux.o

RcloneMount-Windows.exe: launcher_windows.asm
	nasm -f win32 launcher_windows.asm -o launcher_windows.obj
	i686-w64-mingw32-ld -m i386pe -s -e _start --subsystem windows launcher_windows.obj -o RcloneMount-Windows.exe -lkernel32
	rm -f launcher_windows.obj

clean:
	rm -f RcloneMount-Linux RcloneMount-Windows.exe launcher_linux.o launcher_windows.obj

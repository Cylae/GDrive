; launcher_linux.asm
; x86_64 Linux Assembly Launcher for mount-gdrive.sh
; Compiles to a ~1KB executable that calls execve()
;
; nasm -f elf64 launcher_linux.asm
; ld -s -o RcloneMount-Linux launcher_linux.o

global _start

section .data
    shell_path db '/bin/bash', 0
    script_arg db './mount-gdrive.sh', 0

section .text
_start:
    ; Setup execve("/bin/bash", ["/bin/bash", "./mount-gdrive.sh", NULL], NULL)

    ; 1. Stack setup for arguments array (argv)
    ; In order to execute Bash correctly, we must pass the existing environment variables (envp)
    ; rather than NULL, otherwise tools like `rclone` and bash itself won't know $HOME or $PATH.
    ; At entry point `_start`, the stack looks like:
    ;   rsp       => argc
    ;   rsp+8     => argv[0]
    ;   ...       => argv[argc-1]
    ;   rsp+8+... => NULL
    ;   rsp+8*x   => envp[0]

    ; Find envp pointer dynamically
    mov rcx, [rsp]       ; rcx = argc
    lea rdx, [rsp + 8 + rcx*8 + 8] ; rdx = address of envp array

    ; The user expects to be able to pass args to RcloneMount-Linux like "-a status"
    ; So we need to reconstruct argv to be:
    ; ["/bin/bash", "./mount-gdrive.sh", original_argv[1], original_argv[2], ..., NULL]

    ; Dynamically build argv on stack (backwards)
    xor rax, rax
    push rax             ; NULL terminator

    ; Push original_argv[argc-1] down to original_argv[1]
    mov rcx, [rsp + 8]   ; rcx = argc (stack pointer shifted by pushing rax)
    lea r8, [rsp + 24]   ; r8 = &original_argv[1]

.push_args:
    cmp rcx, 1
    jle .push_script

    mov rax, [r8 + rcx*8 - 16] ; get original_argv[rcx-1]
    push rax
    dec rcx
    jmp .push_args

.push_script:
    mov rax, script_arg
    push rax

    mov rax, shell_path
    push rax

    mov rsi, rsp         ; argv = rsp (rsi)

    ; 2. Syscall execve
    mov rdi, shell_path  ; filename = "/bin/sh" (rdi)
    mov rax, 59          ; syscall number for execve (59)
    syscall

    ; 3. Syscall exit (if execve fails)
    mov rdi, rax         ; exit code = execve return value
    mov rax, 60          ; syscall number for exit (60)
    syscall

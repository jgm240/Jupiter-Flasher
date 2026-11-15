# SPDX-License-Identifier: GPL-3.0-or-later
# Jupiter Flasher MBR loader – original code, GPL-free. Relocates to 0x0600, finds the active partition,
# loads its first sector to 0x7C00 (LBA, INT 13h ext) and jumps to it with DL = drive, DS:SI = entry.
# Only the 440 code bytes are written; the disk signature and partition table are kept.
.code16
.intel_syntax noprefix
.set RELOC, 0x0600
.set A_drive,    RELOC + (drive - _start)
.set A_nopart,   RELOC + (msg_nopart - _start)
.set A_read,     RELOC + (msg_read - _start)
.set A_sig,      RELOC + (msg_sig - _start)
.text
.globl _start
_start:
    cli
    xor ax, ax
    mov ss, ax
    mov sp, 0x7C00
    mov ds, ax
    mov es, ax
    sti
    cld
    mov si, 0x7C00
    mov di, RELOC
    mov cx, 256
    rep movsw
    .byte 0xEA                      # jmp far 0000:(RELOC + cont)
    .word RELOC + (cont - _start)
    .word 0
cont:
    mov [A_drive], dl
    mov bx, RELOC + 0x1BE           # partition table
    mov cx, 4
find:
    cmp byte ptr [bx], 0x80
    je found
    add bx, 16
    loop find
    mov si, offset A_nopart
    jmp fail
found:
    xor edx, edx
    push edx                        # LBA high
    push dword ptr [bx + 8]         # LBA low = partition start
    push ax                         # segment 0   (ax = 0)
    push 0x7C00                     # offset
    push 1                          # sector count
    push 0x10                       # DAP size
    mov si, sp
    mov dl, [A_drive]
    mov ah, 0x42
    int 0x13
    mov si, offset A_read
    jc fail
    add sp, 16
    cmp word ptr [0x7DFE], 0xAA55
    mov si, offset A_sig
    jne fail
    mov si, bx                      # DS:SI -> partition entry
    mov dl, [A_drive]
    .byte 0xEA                      # jmp far 0000:7C00
    .word 0x7C00
    .word 0
fail:
    lodsb
    test al, al
    jz hang
    mov ah, 0x0E
    mov bx, 7
    int 0x10
    jmp fail
hang:
    jmp hang
drive:      .byte 0
msg_nopart: .asciz "Jupiter: no active partition"
msg_read:   .asciz "Jupiter: disk read error"
msg_sig:    .asciz "Jupiter: missing boot signature"

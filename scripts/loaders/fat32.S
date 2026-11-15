# SPDX-License-Identifier: GPL-3.0-or-later
# Jupiter Flasher FAT32 boot sector – original code. Loads a file named in the 11-byte field at offset 0x1F0
# ("NTLDR      " or "BOOTMGR    ") from the root directory to 2000:0000 and jumps to it with DL = boot drive.
# The BPB (bytes 0x0B..0x59) is supplied by the volume; the BPB's hidden-sectors field must equal the
# partition's start LBA. Uses INT 13h extensions only.
.code16
.intel_syntax noprefix
.set ORG, 0x7C00
.set DATA_START_V, 0x8000
.set FAT_START_V,  0x8004
.set CUR_V,        0x8008
.set A_fname, ORG + (fname - _start)
.set A_nf,    ORG + (msg_nf - _start)
.set A_disk,  ORG + (msg_disk - _start)
.set DESTSEG_V,    0x800C
.text
.globl _start
_start:
    .byte 0xEB, 0x58, 0x90          # jmp short 0x5A ; nop
    .ascii "WINFLASH"               # OEM name
    .org 0x5A
code:
    cli
    xor ax, ax
    mov ss, ax
    mov sp, 0x7B00
    mov ds, ax
    mov es, ax
    sti
    cld
    mov bp, 0x7C00
    mov [bp + 0x40], dl             # remember BIOS drive number
    movzx eax, word ptr [bp + 0x0E] # reserved sectors
    add eax, [bp + 0x1C]            # + hidden sectors = FAT start (absolute LBA)
    mov [FAT_START_V], eax
    movzx ecx, byte ptr [bp + 0x10] # number of FATs
    imul ecx, [bp + 0x24]           # * sectors per FAT
    add eax, ecx
    mov [DATA_START_V], eax         # first data sector (cluster 2)
    mov eax, [bp + 0x2C]            # root directory cluster
dir_next:
    mov [CUR_V], eax
    mov bx, 0x1000
    mov es, bx
    xor bx, bx
    call read_clus                  # directory cluster -> 1000:0000
    movzx cx, byte ptr [bp + 0x0D]
    shl cx, 4                       # directory entries per cluster = spc * 16
    xor di, di
scan:
    cmp byte ptr es:[di], 0
    je notfound
    push cx
    push di
    mov si, offset A_fname
    mov cx, 11
    repe cmpsb
    pop di
    pop cx
    je found
    add di, 32
    loop scan
    mov eax, [CUR_V]
    call next_clus
    jnc dir_next
notfound:
    mov si, offset A_nf
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
found:
    movzx eax, word ptr es:[di + 0x14]
    shl eax, 16
    mov ax, es:[di + 0x1A]          # first cluster of the file
    mov word ptr [DESTSEG_V], 0x2000
load:
    mov [CUR_V], eax
    mov bx, [DESTSEG_V]
    mov es, bx
    xor bx, bx
    call read_clus
    movzx cx, byte ptr [bp + 0x0D]
    shl cx, 5                       # paragraphs per cluster = spc * 32
    add [DESTSEG_V], cx
    mov eax, [CUR_V]
    call next_clus
    jnc load
    mov dl, [bp + 0x40]
    .byte 0xEA                      # jmp far 2000:0000
    .word 0
    .word 0x2000

# read_clus: EAX = cluster, ES:BX = destination (reads one whole cluster)
read_clus:
    sub eax, 2
    movzx ecx, byte ptr [bp + 0x0D]
    mul ecx
    add eax, [DATA_START_V]
    movzx ecx, byte ptr [bp + 0x0D]
# read_lba: EAX = LBA, CX = sector count, ES:BX = destination. Preserves all registers.
read_lba:
    pushad
    xor edx, edx
    push edx                        # LBA high
    push eax                        # LBA low
    push es
    push bx
    push cx
    push 0x10
    mov si, sp
    mov dl, [bp + 0x40]
    mov ah, 0x42
    int 0x13
    jc disk_err
    add sp, 16
    popad
    ret
disk_err:
    mov si, offset A_disk
    jmp fail

# next_clus: EAX = cluster -> EAX = next cluster; CF = 1 at end of chain
next_clus:
    push es
    mov ebx, eax
    shr ebx, 7                      # FAT sector = cluster / 128
    add ebx, [FAT_START_V]
    and eax, 0x7F
    shl eax, 2                      # byte offset inside that sector
    push eax
    mov eax, ebx
    xor cx, cx
    mov es, cx
    mov bx, 0x7E00
    mov cx, 1
    call read_lba
    pop eax
    mov di, ax
    mov eax, [di + 0x7E00]
    and eax, 0x0FFFFFFF
    cmp eax, 0x0FFFFFF8
    cmc                             # CF = 1 when eax >= 0x0FFFFFF8
    pop es
    ret

msg_nf:   .asciz "Jupiter: boot file not found"
msg_disk: .asciz "Jupiter: disk read error"
    .org 0x1F0
fname:    .ascii "NTLDR      "
    .org 0x1FE
    .word 0xAA55

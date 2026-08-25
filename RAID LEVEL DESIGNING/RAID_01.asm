# =========================================
# RAID 0+1
# input.txt: "10 20 30 40"  (plain numbers)
# MIPS stripes even->disk0, odd->disk1
# then mirrors: disk2=disk0, disk3=disk1
# output.txt:
#   DISK0:10 20
#   DISK1:30 40
#   DISK2:10 20
#   DISK3:30 40
# =========================================

.data
    input_file:  .asciiz "input.txt"
    output_file: .asciiz "output.txt"
    newline:     .asciiz "\n"
    disk0_lbl:   .asciiz "DISK0:"
    disk1_lbl:   .asciiz "DISK1:"
    disk2_lbl:   .asciiz "DISK2:"
    disk3_lbl:   .asciiz "DISK3:"
    space:       .asciiz " "

    .align 2
    buf:    .space 256
    .align 2
    numbuf: .space 16
    .align 2
    d0:     .space 40
    .align 2
    d1:     .space 40
    .align 2
    d2:     .space 40
    .align 2
    d3:     .space 40

.text
.globl main

main:
    # read input.txt
    li   $v0, 13
    la   $a0, input_file
    li   $a1, 0
    li   $a2, 0
    syscall
    move $s0, $v0

    li   $v0, 14
    move $a0, $s0
    la   $a1, buf
    li   $a2, 255
    syscall
    move $s1, $v0

    li   $v0, 16
    move $a0, $s0
    syscall

    la   $t0, buf
    add  $t0, $t0, $s1
    sb   $zero, 0($t0)

    la   $s5, buf         # cursor in saved reg
    li   $s2, 0           # disk0 count
    li   $s3, 0           # disk1 count
    li   $s4, 0           # stripe index

read_loop:
    jal  read_int         # v0=value, v1=1 means end
    bnez $v1, stripe_done

    andi $t0, $s4, 1
    bnez $t0, to_d1

    # -> disk0
    sll  $t1, $s2, 2
    la   $t2, d0
    add  $t2, $t2, $t1
    sw   $v0, 0($t2)
    addi $s2, $s2, 1
    j    next_v

to_d1:
    # -> disk1
    sll  $t1, $s3, 2
    la   $t2, d1
    add  $t2, $t2, $t1
    sw   $v0, 0($t2)
    addi $s3, $s3, 1

next_v:
    addi $s4, $s4, 1
    j    read_loop

stripe_done:
    # mirror disk0 -> disk2
    li   $t4, 0
mir0:
    bge  $t4, $s2, mir1
    sll  $t0, $t4, 2
    la   $t1, d0
    add  $t1, $t1, $t0
    lw   $t2, 0($t1)
    la   $t1, d2
    add  $t1, $t1, $t0
    sw   $t2, 0($t1)
    addi $t4, $t4, 1
    j    mir0

mir1:
    li   $t4, 0
mir1_lp:
    bge  $t4, $s3, write_out
    sll  $t0, $t4, 2
    la   $t1, d1
    add  $t1, $t1, $t0
    lw   $t2, 0($t1)
    la   $t1, d3
    add  $t1, $t1, $t0
    sw   $t2, 0($t1)
    addi $t4, $t4, 1
    j    mir1_lp

write_out:
    li   $v0, 13
    la   $a0, output_file
    li   $a1, 1
    li   $a2, 0
    syscall
    move $s0, $v0         # output fd

    # --- DISK0 ---
    li   $v0, 15
    move $a0, $s0
    la   $a1, disk0_lbl
    li   $a2, 6
    syscall
    li   $s4, 0
wd0:
    bge  $s4, $s2, wd0_nl
    sll  $t0, $s4, 2
    la   $t1, d0
    add  $t1, $t1, $t0
    lw   $t1, 0($t1)
    jal  write_int
    li   $v0, 15
    move $a0, $s0
    la   $a1, space
    li   $a2, 1
    syscall
    addi $s4, $s4, 1
    j    wd0
wd0_nl:
    li   $v0, 15
    move $a0, $s0
    la   $a1, newline
    li   $a2, 1
    syscall

    # --- DISK1 ---
    li   $v0, 15
    move $a0, $s0
    la   $a1, disk1_lbl
    li   $a2, 6
    syscall
    li   $s4, 0
wd1:
    bge  $s4, $s3, wd1_nl
    sll  $t0, $s4, 2
    la   $t1, d1
    add  $t1, $t1, $t0
    lw   $t1, 0($t1)
    jal  write_int
    li   $v0, 15
    move $a0, $s0
    la   $a1, space
    li   $a2, 1
    syscall
    addi $s4, $s4, 1
    j    wd1
wd1_nl:
    li   $v0, 15
    move $a0, $s0
    la   $a1, newline
    li   $a2, 1
    syscall

    # --- DISK2 (mirror of disk0) ---
    li   $v0, 15
    move $a0, $s0
    la   $a1, disk2_lbl
    li   $a2, 6
    syscall
    li   $s4, 0
wd2:
    bge  $s4, $s2, wd2_nl
    sll  $t0, $s4, 2
    la   $t1, d2
    add  $t1, $t1, $t0
    lw   $t1, 0($t1)
    jal  write_int
    li   $v0, 15
    move $a0, $s0
    la   $a1, space
    li   $a2, 1
    syscall
    addi $s4, $s4, 1
    j    wd2
wd2_nl:
    li   $v0, 15
    move $a0, $s0
    la   $a1, newline
    li   $a2, 1
    syscall

    # --- DISK3 (mirror of disk1) ---
    li   $v0, 15
    move $a0, $s0
    la   $a1, disk3_lbl
    li   $a2, 6
    syscall
    li   $s4, 0
wd3:
    bge  $s4, $s3, wd3_nl
    sll  $t0, $s4, 2
    la   $t1, d3
    add  $t1, $t1, $t0
    lw   $t1, 0($t1)
    jal  write_int
    li   $v0, 15
    move $a0, $s0
    la   $a1, space
    li   $a2, 1
    syscall
    addi $s4, $s4, 1
    j    wd3
wd3_nl:
    li   $v0, 15
    move $a0, $s0
    la   $a1, newline
    li   $a2, 1
    syscall

    li   $v0, 16
    move $a0, $s0
    syscall
    li   $v0, 10
    syscall

# =============================================
# read_int: reads next int from buf via $s5
# returns: $v0=value  $v1=0(ok) or 1(end)
# only touches $t0 $t1
# =============================================
read_int:
ri_skip:
    lb   $t0, 0($s5)
    beqz $t0, ri_end
    li   $t1, 32
    beq  $t0, $t1, ri_adv
    li   $t1, 10
    beq  $t0, $t1, ri_adv
    li   $t1, 13
    beq  $t0, $t1, ri_adv
    li   $t1, 44
    beq  $t0, $t1, ri_adv   # skip commas
    j    ri_digits
ri_adv:
    addi $s5, $s5, 1
    j    ri_skip
ri_digits:
    li   $v0, 0
    li   $v1, 0
ri_loop:
    lb   $t0, 0($s5)
    li   $t1, 48
    blt  $t0, $t1, ri_done
    li   $t1, 57
    bgt  $t0, $t1, ri_done
    addi $t0, $t0, -48
    mul  $v0, $v0, 10
    add  $v0, $v0, $t0
    addi $s5, $s5, 1
    j    ri_loop
ri_done:
    jr   $ra
ri_end:
    li   $v0, 0
    li   $v1, 1
    jr   $ra

# =============================================
# write_int: converts $t1 to decimal, writes to fd $s0
# touches $t0 $t1 $t2 $t3 $t4 only
# =============================================
write_int:
    la   $t2, numbuf
    li   $t3, 0
    beqz $t1, wi_zero
wi_loop:
    beqz $t1, wi_rev
    li   $t0, 10
    div  $t1, $t0
    mfhi $t4
    addi $t4, $t4, 48
    sb   $t4, 0($t2)
    addi $t2, $t2, 1
    addi $t3, $t3, 1
    mflo $t1
    j    wi_loop
wi_rev:
    la   $t2, numbuf
    la   $t4, numbuf
    add  $t4, $t4, $t3
    addi $t4, $t4, -1
wi_rev_lp:
    bge  $t2, $t4, wi_write
    lb   $t0, 0($t2)
    lb   $t1, 0($t4)
    sb   $t1, 0($t2)
    sb   $t0, 0($t4)
    addi $t2, $t2, 1
    addi $t4, $t4, -1
    j    wi_rev_lp
wi_write:
    li   $v0, 15
    move $a0, $s0
    la   $a1, numbuf
    move $a2, $t3
    syscall
    jr   $ra
wi_zero:
    li   $t0, 48
    la   $t2, numbuf
    sb   $t0, 0($t2)
    li   $v0, 15
    move $a0, $s0
    la   $a1, numbuf
    li   $a2, 1
    syscall
    jr   $ra
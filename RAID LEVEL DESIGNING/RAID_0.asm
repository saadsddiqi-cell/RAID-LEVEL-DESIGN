# =========================================
# RAID 0
# input.txt:  plain space-separated integers
#             e.g. "10 20 30 40"
# MIPS stripes: even index -> disk0, odd -> disk1
# output.txt:
#   DISK0:10 20
#   DISK1:30 40
# =========================================

.data
    input_file:  .asciiz "input.txt"
    output_file: .asciiz "output.txt"
    newline:     .asciiz "\n"
    disk0_lbl:   .asciiz "DISK0:"
    disk1_lbl:   .asciiz "DISK1:"
    space:       .asciiz " "

    .align 2
    buf:    .space 256    # input read buffer
    .align 2
    numbuf: .space 16     # int-to-string buffer
    .align 2
    d0:     .space 40     # disk0 values (up to 10 ints)
    .align 2
    d1:     .space 40     # disk1 values

.text
.globl main

main:
    # open input.txt (read)
    li   $v0, 13
    la   $a0, input_file
    li   $a1, 0
    li   $a2, 0
    syscall
    move $s0, $v0         # s0 = fd

    # read
    li   $v0, 14
    move $a0, $s0
    la   $a1, buf
    li   $a2, 255
    syscall
    move $s1, $v0         # s1 = bytes read

    # close
    li   $v0, 16
    move $a0, $s0
    syscall

    # null-terminate
    la   $t0, buf
    add  $t0, $t0, $s1
    sb   $zero, 0($t0)

    # s5 = cursor (saved reg, safe across jal)
    la   $s5, buf

    # s2 = disk0 count, s3 = disk1 count
    li   $s2, 0
    li   $s3, 0
    # s4 = total index (0,1,2,... used to stripe)
    li   $s4, 0

    la   $t8, d0          # base of disk0
    la   $t9, d1          # base of disk1

read_loop:
    jal  read_int         # result in $v0, $v1=0 if ok, $v1=1 if end
    bnez $v1, read_done

    # stripe: even index -> disk0, odd -> disk1
    andi $t0, $s4, 1
    bnez $t0, go_disk1

    # disk0
    sll  $t1, $s2, 2
    add  $t1, $t8, $t1
    sw   $v0, 0($t1)
    addi $s2, $s2, 1
    j    next_val

go_disk1:
    sll  $t1, $s3, 2
    add  $t1, $t9, $t1
    sw   $v0, 0($t1)
    addi $s3, $s3, 1

next_val:
    addi $s4, $s4, 1
    j    read_loop

read_done:
    # open output.txt (write, flag=1)
    li   $v0, 13
    la   $a0, output_file
    li   $a1, 1
    li   $a2, 0
    syscall
    move $s0, $v0         # s0 = output fd

    # write "DISK0:"
    li   $v0, 15
    move $a0, $s0
    la   $a1, disk0_lbl
    li   $a2, 6
    syscall

    # write disk0 values
    li   $s4, 0           # loop counter
wloop0:
    bge  $s4, $s2, wdone0
    sll  $t0, $s4, 2
    add  $t0, $t8, $t0
    lw   $t1, 0($t0)      # value
    jal  write_int
    li   $v0, 15
    move $a0, $s0
    la   $a1, space
    li   $a2, 1
    syscall
    addi $s4, $s4, 1
    j    wloop0

wdone0:
    li   $v0, 15
    move $a0, $s0
    la   $a1, newline
    li   $a2, 1
    syscall

    # write "DISK1:"
    li   $v0, 15
    move $a0, $s0
    la   $a1, disk1_lbl
    li   $a2, 6
    syscall

    li   $s4, 0
wloop1:
    bge  $s4, $s3, wdone1
    sll  $t0, $s4, 2
    add  $t0, $t9, $t0
    lw   $t1, 0($t0)
    jal  write_int
    li   $v0, 15
    move $a0, $s0
    la   $a1, space
    li   $a2, 1
    syscall
    addi $s4, $s4, 1
    j    wloop1

wdone1:
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
# read_int: reads next integer from buf via $s5
# returns: $v0 = value, $v1 = 0 (ok) or 1 (end)
# only touches $t0, $t1
# =============================================
read_int:
ri_skip:
    lb   $t0, 0($s5)
    beqz $t0, ri_end      # null terminator = done
    li   $t1, 32
    beq  $t0, $t1, ri_adv # space
    li   $t1, 10
    beq  $t0, $t1, ri_adv # newline
    li   $t1, 13
    beq  $t0, $t1, ri_adv # CR
    li   $t1, 44
    beq  $t0, $t1, ri_adv # comma (skip commas too, just in case)
    j    ri_digits
ri_adv:
    addi $s5, $s5, 1
    j    ri_skip
ri_digits:
    li   $v0, 0
    li   $v1, 0           # success flag
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
# write_int: writes $t1 as decimal to output fd $s0
# only touches $t0,$t1,$t2,$t3,$t4
# =============================================
write_int:
    la   $t2, numbuf
    li   $t3, 0           # digit count
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
    addi $t4, $t2, 0
    add  $t4, $t4, $t3
    addi $t4, $t4, -1
wi_rev_loop:
    bge  $t2, $t4, wi_write
    lb   $t0, 0($t2)
    lb   $t1, 0($t4)
    sb   $t1, 0($t2)
    sb   $t0, 0($t4)
    addi $t2, $t2, 1
    addi $t4, $t4, -1
    j    wi_rev_loop
wi_write:
    li   $v0, 15
    move $a0, $s0
    la   $a1, numbuf
    move $a2, $t3
    syscall
    jr   $ra
wi_zero:
    li   $t0, 48
    sb   $t0, 0($t2)
    li   $v0, 15
    move $a0, $s0
    la   $a1, numbuf
    li   $a2, 1
    syscall
    jr   $ra
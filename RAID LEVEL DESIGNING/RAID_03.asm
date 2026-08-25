# =========================================
# RAID 3
# 3 data disks + 1 dedicated parity disk
#
# input.txt:  plain space/comma-separated integers
#             e.g. "10 20 30 40 50 60"
#
# Striping (round-robin across 3 data disks):
#   index % 3 == 0  -> disk0
#   index % 3 == 1  -> disk1
#   index % 3 == 2  -> disk2
#
# After every complete stripe of 3 values,
# MIPS XORs them and stores result in disk3 (parity).
# If the last stripe is incomplete (1 or 2 values),
# MIPS still XORs the available values (missing
# positions treated as 0) and writes parity.
#
# output.txt:
#   DISK0:10 40
#   DISK1:20 50
#   DISK2:30 60
#   DISK3:10^20^30  40^50^60   (parity per stripe)
#
# Format: one label per line, values space-separated.
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
    buf:    .space 512       # input read buffer (bigger for safety)
    .align 2
    numbuf: .space 16        # int-to-string scratch
    .align 2
    d0:     .space 80        # disk0 data  (up to 20 ints * 4 bytes)
    .align 2
    d1:     .space 80        # disk1 data
    .align 2
    d2:     .space 80        # disk2 data
    .align 2
    d3:     .space 80        # disk3 parity (one parity per stripe)

.text
.globl main

main:
    # ?? open input.txt (read, flag=0) ??????????????????
    li   $v0, 13
    la   $a0, input_file
    li   $a1, 0
    li   $a2, 0
    syscall
    move $s0, $v0            # s0 = input fd

    # ?? read entire file into buf ???????????????????????
    li   $v0, 14
    move $a0, $s0
    la   $a1, buf
    li   $a2, 511
    syscall
    move $s1, $v0            # s1 = bytes read

    # ?? close input ????????????????????????????????????
    li   $v0, 16
    move $a0, $s0
    syscall

    # ?? null-terminate buf ?????????????????????????????
    la   $t0, buf
    add  $t0, $t0, $s1
    sb   $zero, 0($t0)

    # ?? initialise registers ???????????????????????????
    la   $s5, buf            # s5 = read cursor (saved across jal)
    li   $s2, 0              # s2 = disk0 count
    li   $s3, 0              # s3 = disk1 count
    li   $s6, 0              # s6 = disk2 count
    li   $s7, 0              # s7 = parity (disk3) count
    li   $s4, 0              # s4 = global stripe-position index (0,1,2,0,1,2, )

    # ?? per-stripe accumulators (temp registers) ???????
    # We keep a running stripe buffer in memory:
    # stripe_buf: 3 words for current stripe values
    .data
    stripe_buf: .space 12    # 3 * 4 bytes
    stripe_cnt: .word 0      # how many values collected in current stripe
    .text

    la   $t8, stripe_buf
    li   $t0, 0
    sw   $t0, 0($t8)
    sw   $t0, 4($t8)
    sw   $t0, 8($t8)

    li   $t0, 0
    la   $t1, stripe_cnt
    sw   $t0, 0($t1)

# ?? MAIN READ LOOP ?????????????????????????????????????
read_loop:
    jal  read_int            # v0 = value, v1 = 1 means end-of-input
    bnez $v1, read_done

    # ?? which data disk does this value go to? ?????????
    # s4 holds the round-robin position (0,1,2 repeating)
    # We use repeated subtraction to get s4 % 3
    move $t3, $s4
mod3_loop:
    li   $t0, 3
    blt  $t3, $t0, mod3_done
    sub  $t3, $t3, $t0
    j    mod3_loop
mod3_done:
    # t3 = s4 % 3

    beq  $t3, $zero, to_d0
    li   $t0, 1
    beq  $t3, $t0, to_d1
    j    to_d2

to_d0:
    sll  $t1, $s2, 2
    la   $t2, d0
    add  $t2, $t2, $t1
    sw   $v0, 0($t2)
    addi $s2, $s2, 1
    j    store_stripe

to_d1:
    sll  $t1, $s3, 2
    la   $t2, d1
    add  $t2, $t2, $t1
    sw   $v0, 0($t2)
    addi $s3, $s3, 1
    j    store_stripe

to_d2:
    sll  $t1, $s6, 2
    la   $t2, d2
    add  $t2, $t2, $t1
    sw   $v0, 0($t2)
    addi $s6, $s6, 1

store_stripe:
    # ?? save value into stripe_buf[stripe_cnt] ?????????
    la   $t1, stripe_cnt
    lw   $t2, 0($t1)
    sll  $t3, $t2, 2
    la   $t4, stripe_buf
    add  $t4, $t4, $t3
    sw   $v0, 0($t4)
    addi $t2, $t2, 1
    sw   $t2, 0($t1)

    # ?? if stripe_cnt == 3, compute parity ?????????????
    li   $t0, 3
    bne  $t2, $t0, next_val

    # compute XOR of stripe_buf[0..2]
    la   $t4, stripe_buf
    lw   $t0, 0($t4)
    lw   $t1, 4($t4)
    lw   $t2, 8($t4)
    xor  $t0, $t0, $t1
    xor  $t0, $t0, $t2          # t0 = parity

    # store into d3[s7]
    sll  $t1, $s7, 2
    la   $t2, d3
    add  $t2, $t2, $t1
    sw   $t0, 0($t2)
    addi $s7, $s7, 1

    # reset stripe_buf and stripe_cnt
    la   $t1, stripe_cnt
    sw   $zero, 0($t1)
    la   $t4, stripe_buf
    sw   $zero, 0($t4)
    sw   $zero, 4($t4)
    sw   $zero, 8($t4)

next_val:
    addi $s4, $s4, 1
    j    read_loop

# ?? END OF INPUT ???????????????????????????????????????
# Handle any incomplete final stripe (1 or 2 values)
read_done:
    la   $t1, stripe_cnt
    lw   $t2, 0($t1)
    beqz $t2, write_out      # no leftover values

    # XOR whatever is in stripe_buf (zeros fill missing slots)
    la   $t4, stripe_buf
    lw   $t0, 0($t4)
    lw   $t1, 4($t4)
    lw   $t3, 8($t4)
    xor  $t0, $t0, $t1
    xor  $t0, $t0, $t3

    sll  $t1, $s7, 2
    la   $t2, d3
    add  $t2, $t2, $t1
    sw   $t0, 0($t2)
    addi $s7, $s7, 1

# ?? WRITE output.txt ???????????????????????????????????
write_out:
    li   $v0, 13
    la   $a0, output_file
    li   $a1, 1              # write flag
    li   $a2, 0
    syscall
    move $s0, $v0            # s0 = output fd

    # ?? DISK0 ??????????????????????????????????????????
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

    # ?? DISK1 ??????????????????????????????????????????
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

    # ?? DISK2 ??????????????????????????????????????????
    li   $v0, 15
    move $a0, $s0
    la   $a1, disk2_lbl
    li   $a2, 6
    syscall

    li   $s4, 0
wd2:
    bge  $s4, $s6, wd2_nl
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

    # ?? DISK3 (parity) ?????????????????????????????????
    li   $v0, 15
    move $a0, $s0
    la   $a1, disk3_lbl
    li   $a2, 6
    syscall

    li   $s4, 0
wd3:
    bge  $s4, $s7, wd3_nl
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

    # ?? close output & exit ????????????????????????????
    li   $v0, 16
    move $a0, $s0
    syscall
    li   $v0, 10
    syscall


# =============================================
# read_int
# Reads next integer token from buf via $s5.
# Skips spaces, newlines, CR, commas.
# Returns: $v0 = value
#          $v1 = 0 (ok) | 1 (end of input)
# Touches only $t0, $t1  (safe across caller's $t2-$t9 use)
# =============================================
read_int:
ri_skip:
    lb   $t0, 0($s5)
    beqz $t0, ri_end         # null terminator
    li   $t1, 32
    beq  $t0, $t1, ri_adv   # space
    li   $t1, 10
    beq  $t0, $t1, ri_adv   # newline
    li   $t1, 13
    beq  $t0, $t1, ri_adv   # CR
    li   $t1, 44
    beq  $t0, $t1, ri_adv   # comma
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
# write_int
# Writes $t1 as decimal string to fd $s0.
# Touches only $t0,$t1,$t2,$t3,$t4
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
# RAID Level Design

A simulation of **RAID levels 0, 0+1, 3 and 5** implemented in **MIPS assembly**, with a **Python (Tkinter) GUI** that visualises disks, striping, mirroring, parity, failure and rebuild. Built as a Computer Organization and Architecture (COA) lab project.

## RAID Levels Implemented

| Level | File | Behaviour |
|-------|------|-----------|
| RAID 0 | `RAID_0.asm` | Striping: even-index values to disk 0, odd-index to disk 1 |
| RAID 0+1 | `RAID_01.asm` | Striping plus mirroring |
| RAID 3 | `RAID_03.asm` | Byte-level striping with a dedicated parity disk |
| RAID 5 | `RAID_05.asm` | Block-level striping with distributed parity |

## How It Works

1. Input integers are read from `input.txt` (space-separated), e.g. `10 20 30 40 50 60 80 90 100 120`.
2. The MIPS program distributes data across the virtual disks and writes the layout to `output.txt`, e.g.:
   ```
   DISK0:10 20
   DISK1:30 40
   ```
3. The GUI launches the MIPS program through the **MARS** simulator, parses the output, and draws each disk's blocks, colour coded:
   - Blue: data, Grey: mirror, Amber / Violet: RAID 3 / RAID 5 parity
   - Red: failed disk, Green: rebuilt data

## Tech Stack

MIPS Assembly (MARS 4.5), Python 3, Tkinter

## Project Structure

```
RAID LEVEL DESIGNING/
├── RAID_0.asm
├── RAID_01.asm
├── RAID_03.asm
├── RAID_05.asm
├── RAID(0+1)_gui (1).py   # GUI front end
├── input.txt              # Sample input
└── output.txt             # Generated output
```

## Getting Started

### Prerequisites
- Python 3.8+ (Tkinter is included)
- Java (to run MARS)
- [MARS MIPS simulator](https://courses.missouristate.edu/kenvollmar/mars/) `Mars45.jar`

### Run

```bash
git clone https://github.com/saadsddiqi-cell/RAID-LEVEL-DESIGN.git
cd "RAID-LEVEL-DESIGN/RAID LEVEL DESIGNING"
```

1. Edit `MARS_JAR` at the top of the GUI script. It currently points to a local Windows path and must be changed to where your `Mars45.jar` lives.
2. Run:
   ```bash
   python "RAID(0+1)_gui (1).py"
   ```

Or run a single level headless:
```bash
java -jar Mars45.jar RAID_0.asm
```

## Limitations

- Capped at 12 blocks (`MAX_BLOCKS`); disk buffers hold about 10 integers
- Hard-coded MARS path
- Filename `RAID(0+1)_gui (1).py` contains spaces and brackets; consider renaming to `raid_gui.py`

## Contributors

This project was developed collaboratively by:

- [Muhammad Saad Siddiqui](https://github.com/saadsddiqi-cell)
- [Syed Muhammad Zain Hassan](https://github.com/zainhassan5763-git)

Developed as part of academic project work
at Sir Syed University of Engineering & Technology.
